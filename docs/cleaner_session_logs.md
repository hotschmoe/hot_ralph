# Session Log Cleaning Strategies

Claude Code emits verbose JSONL streaming logs. This document details Zig-native approaches to compact them for storage and LLM introspection.

## Problem Analysis

A typical 5-minute session produces 200-1000KB of logs. The bloat sources:

| Source | % of Bloat | Example |
|--------|------------|---------|
| Token-by-token streaming deltas | ~60% | `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":" the"}}}` |
| Repeated metadata | ~25% | `session_id`, `uuid`, `parent_tool_use_id` on every line |
| Protocol events | ~10% | `message_start`, `message_stop`, `content_block_start/stop` |
| Content duplication | ~5% | Final `assistant` message duplicates all streamed deltas |

**Target consumers**: 99% LLMs, 1% humans. Optimize for token efficiency, not readability.

---

## Approach 1: Structural JSONL Cleaning (Zig-native)

Parse raw JSONL, drop redundant events, emit compact JSONL.

### Implementation

```zig
const std = @import("std");

const EventType = enum {
    system_init,
    assistant,
    user,
    tool_result,
    skip, // stream_event, etc.
};

const CompactEvent = union(EventType) {
    system_init: struct {
        model: []const u8,
        cwd: []const u8,
        agents: []const []const u8,
    },
    assistant: struct {
        text: ?[]const u8,
        tool_calls: ?[]const ToolCall,
    },
    user: struct {
        text: []const u8,
    },
    tool_result: struct {
        results: []const Result,
    },
    skip: void,
};

pub fn compactLine(allocator: Allocator, line: []const u8) !?CompactEvent {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    
    const root = parsed.value.object;
    const event_type = root.get("type").?.string;
    
    // Drop all streaming events - they're redundant
    if (std.mem.eql(u8, event_type, "stream_event")) return null;
    
    // Extract meaningful events...
    // (full implementation in src/log_cleaner.zig)
}
```

### Output Format

```jsonl
{"t":"init","m":"claude-opus-4-5","cwd":"/home/user/proj","agents":["Bash","Plan"]}
{"t":"a","text":"Checking git status..."}
{"t":"a","tool":[{"n":"Bash","cmd":"git status"}]}
{"t":"r","c":"On branch main\n..."}
```

### Characteristics

- **Compression**: ~30x (structural only)
- **Complexity**: Low - just JSON parsing and filtering
- **LLM tokens**: Moderate - JSON syntax overhead remains
- **Tooling**: Standard `std.json`, no dependencies

---

## Approach 2: JSONL → TOON Conversion

Clean structurally, then convert to TOON for additional token savings.

### Dependency Setup

```bash
zig fetch --save git+https://github.com/hotschmoe/toon_zig.git
```

```zig
// build.zig
const toon_dep = b.dependency("toon_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("toon", toon_dep.module("toon_zig"));
```

### Implementation

```zig
const toon = @import("toon");

pub fn compactToToon(allocator: Allocator, raw_jsonl: []const u8) ![]const u8 {
    // Step 1: Structural cleaning (as above)
    var cleaned_events = std.ArrayList(CompactEvent).init(allocator);
    var lines = std.mem.splitScalar(u8, raw_jsonl, '\n');
    while (lines.next()) |line| {
        if (compactLine(allocator, line)) |event| {
            try cleaned_events.append(event);
        }
    }
    
    // Step 2: Serialize to JSON, then encode to TOON
    const json_str = try serializeEvents(allocator, cleaned_events.items);
    defer allocator.free(json_str);
    
    return try toon.jsonToToon(allocator, json_str);
}
```

### Output Format

```toon
events[4]:
  - t: init
    m: claude-opus-4-5
    cwd: /home/user/proj
    agents[2]: Bash,Plan
  - t: a
    text: Checking git status...
  - t: a
    tool[1]:
      - n: Bash
        cmd: git status
  - t: r
    c: "On branch main\n..."
```

### Characteristics

- **Compression**: ~35-40x (structural + syntactic)
- **Complexity**: Medium - adds toon_zig dependency
- **LLM tokens**: Good - 40-60% fewer tokens than JSON
- **Tooling**: Full TOON ecosystem, round-trips to JSON

---

## Approach 3: Direct TOON Emission

Skip intermediate JSON entirely. Parse raw JSONL, emit TOON directly via string building.

### Implementation

```zig
pub fn emitToonDirect(writer: anytype, events: []const CompactEvent) !void {
    try writer.print("events[{d}]:\n", .{events.len});
    
    for (events) |event| {
        switch (event) {
            .system_init => |init| {
                try writer.writeAll("  - t: init\n");
                try writer.print("    m: {s}\n", .{init.model});
                try writer.print("    cwd: {s}\n", .{init.cwd});
                if (init.agents.len > 0) {
                    try writer.print("    agents[{d}]: ", .{init.agents.len});
                    for (init.agents, 0..) |agent, i| {
                        if (i > 0) try writer.writeByte(',');
                        try writer.writeAll(agent);
                    }
                    try writer.writeByte('\n');
                }
            },
            .assistant => |asst| {
                try writer.writeAll("  - t: a\n");
                if (asst.text) |text| {
                    try writer.print("    text: {s}\n", .{escapeToon(text)});
                }
                // ... tool_calls
            },
            // ...
        }
    }
}

fn escapeToon(s: []const u8) []const u8 {
    // Quote if contains newlines, leading whitespace, or special chars
    // Return as-is for simple strings
}
```

### Characteristics

- **Compression**: ~35-40x (same as Approach 2)
- **Complexity**: Medium - manual TOON string formatting
- **LLM tokens**: Good - same as Approach 2
- **Tooling**: No dependency, but must maintain TOON spec compliance manually

---

## Approach 4: Hybrid - Tiered Storage

Keep full fidelity for recent logs, progressively compact older ones.

### Architecture

```
.hot_ralph/
├── current.jsonl          # Raw, last 1 hour (for debugging)
├── recent.toon            # Cleaned TOON, last 24 hours
├── archive/
│   ├── 2026-02-01.toon.zst  # Compressed TOON, older
│   └── ...
└── index.toon             # Summary index for all sessions
```

### Implementation

```zig
const Tier = enum { raw, cleaned, archived };

pub fn rotateLogs(allocator: Allocator, hot_ralph_dir: []const u8) !void {
    const now = std.time.timestamp();
    
    // 1. Compact anything older than 1 hour from current.jsonl → recent.toon
    // 2. Archive anything older than 24 hours from recent.toon → archive/
    // 3. Update index.toon with session summaries
}

pub fn queryLogs(allocator: Allocator, query: []const u8) ![]const Session {
    // Search index.toon first, then drill into specific files
}
```

### Index Format (TOON)

```toon
sessions[127]:
  - id: e2e73c56-9b36
    ts: 2026-02-01T07:17:49Z
    model: claude-opus-4-5
    cwd: /home/hotschmoe/zithril
    tools_used[3]: Bash,Read,Edit
    summary: Layout solver refactoring and action union implementation
    file: archive/2026-02-01.toon.zst
    offset: 4821
```

### Characteristics

- **Compression**: Variable (raw → 40x+ for archives)
- **Complexity**: High - multiple tiers, rotation logic
- **LLM tokens**: Optimized for query patterns
- **Tooling**: Good for long-term introspection

---

## Approach 5: Semantic Deduplication

Beyond structural cleaning, detect and collapse semantically redundant content.

### Patterns to Deduplicate

1. **Repeated tool calls**: Same command run multiple times → keep first + count
2. **Similar assistant text**: "Let me check..." variations → normalize
3. **Large tool outputs**: Truncate or hash, store separately
4. **Failed attempts**: Collapse error→retry→error→retry into summary

### Implementation Sketch

```zig
const SemanticEvent = struct {
    base: CompactEvent,
    occurrences: u32 = 1,
    hash: u64, // For dedup detection
};

pub fn semanticDedup(events: []CompactEvent) []SemanticEvent {
    var seen = std.AutoHashMap(u64, usize).init(allocator);
    var result = std.ArrayList(SemanticEvent).init(allocator);
    
    for (events) |event| {
        const hash = hashEvent(event);
        if (seen.get(hash)) |idx| {
            result.items[idx].occurrences += 1;
        } else {
            try seen.put(hash, result.items.len);
            try result.append(.{ .base = event, .hash = hash });
        }
    }
    return result.items;
}
```

### Output Example

```toon
events[3]:
  - t: a
    tool.n: Bash
    tool.cmd: zig build
    occurrences: 7
    last_result: "error: expected expression"
  - t: a
    text: "[7 build attempts with incremental fixes]"
  - t: a
    tool.n: Bash
    tool.cmd: zig build
    result: "Build successful"
```

### Characteristics

- **Compression**: 50-100x on repetitive sessions
- **Complexity**: High - pattern detection, heuristics
- **LLM tokens**: Excellent for iterative debug sessions
- **Tooling**: Requires tuning for your workflow patterns

---

## Approach 6: Binary + TOON Manifest

For maximum compression with LLM-friendly access layer.

### Architecture

```
session.bin     # Compact binary: varint lengths, interned strings, zstd blocks
session.toon    # TOON manifest with offsets into .bin for random access
```

### Binary Format

```
Header:
  magic: "CLSN"
  version: 1
  string_table_offset: u32
  event_count: u32

String Table:
  [length: varint, bytes: [u8]...]...

Events:
  [type: u8, payload_len: varint, payload: [u8]...]...
```

### Characteristics

- **Compression**: 100x+ with zstd
- **Complexity**: Very high - custom format, tooling needed
- **LLM tokens**: Requires manifest extraction, not directly consumable
- **Tooling**: Must build query/extract tools

---

## Recommendation

For your use case (LLM-primary consumers, Zig ecosystem, zithril integration):

### Primary: Approach 2 (JSONL → TOON) with elements of Approach 4

```
┌─────────────────────────────────────────────────────────┐
│  Raw JSONL Stream                                       │
│  (from Claude Code)                                     │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│  Structural Cleaner (Zig)                               │
│  - Drop stream_event deltas                             │
│  - Drop protocol noise (message_start/stop, etc.)       │
│  - Merge content blocks into single assistant messages  │
│  - Truncate large tool outputs (>500 chars)             │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│  toon_zig Encoder                                       │
│  - jsonToToon() for final output                        │
│  - Key folding enabled (input.command → input.command)  │
│  - Tabular arrays for uniform tool_calls                │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│  .hot_ralph/session.toon                                │
│  ~35-40x compression, LLM-optimized tokens              │
└─────────────────────────────────────────────────────────┘
```

### Why This Combination

1. **Token efficiency**: TOON's 40-60% reduction over JSON directly benefits LLM context windows
2. **Zig-native**: toon_zig parses back to `Value` trees - integrate with zithril tooling
3. **Round-trip safe**: Can always `toonToJson()` if you need JSON compatibility
4. **Maintainable**: TOON spec is stable, toon_zig is conformant
5. **Progressive enhancement**: Add semantic dedup (Approach 5) later without format changes

### Implementation Recommendation

Create a `log_cleaner` module in zithril or as a separate tool:

```zig
// src/log_cleaner.zig
const std = @import("std");
const toon = @import("toon");

pub const CleanerOptions = struct {
    max_tool_output: usize = 500,
    truncate_text: usize = 1000,
    include_timing: bool = false,
};

pub fn cleanSession(
    allocator: std.mem.Allocator,
    raw_jsonl: []const u8,
    options: CleanerOptions,
) ![]const u8 {
    // 1. Parse and filter JSONL
    // 2. Build intermediate JSON structure  
    // 3. Encode to TOON via toon.jsonToToon()
    // Return TOON string
}

pub fn cleanSessionFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    options: CleanerOptions,
) !void {
    const raw = try std.fs.cwd().readFileAlloc(allocator, input_path, 10 * 1024 * 1024);
    defer allocator.free(raw);
    
    const cleaned = try cleanSession(allocator, raw, options);
    defer allocator.free(cleaned);
    
    try std.fs.cwd().writeFile(output_path, cleaned);
}
```

### CLI Integration

```bash
# As part of your existing tooling
zithril log-clean .hot_ralph/raw.jsonl -o .hot_ralph/session.toon

# Or standalone
tzu-clean session.jsonl --format toon > session.toon
```

### Future Enhancements (when needed)

1. **Add semantic dedup** for repetitive build/test cycles
2. **Add tiered storage** if logs grow beyond reasonable size
3. **Add TOON index** for cross-session search
4. **Consider zstd compression** for archives (`.toon.zst`)

---

## Size Comparison (Real Data)

From your uploaded logs:

| Stage | 073246_plan_simplify.md |
|-------|-------------------------|
| Raw JSONL | 244 KB |
| Structural clean (JSONL) | 11 KB (22x) |
| Structural clean (TOON) | 8 KB (30x) |
| + Semantic dedup (est.) | 4-5 KB (50x) |
| + zstd (est.) | 1-2 KB (150x) |

For LLM consumption, the **8 KB TOON** is the sweet spot: massive reduction, directly parseable, no decompression step.

---

## Summary Table

| Approach | Compression | Complexity | LLM Tokens | Dependency |
|----------|-------------|------------|------------|------------|
| 1. Structural JSONL | 30x | Low | Moderate | None |
| 2. JSONL → TOON | 35-40x | Medium | Good | toon_zig |
| 3. Direct TOON | 35-40x | Medium | Good | None |
| 4. Tiered Hybrid | Variable | High | Good | toon_zig |
| 5. Semantic Dedup | 50-100x | High | Excellent | None |
| 6. Binary + Manifest | 100x+ | Very High | Requires extraction | Custom |

**Recommendation**: Start with **Approach 2**, add **Approach 5** patterns as you identify repetitive workflows.
