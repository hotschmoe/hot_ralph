# Hot Ralph Zig Port & Terminal Library Reference

A comprehensive guide for porting the hot_ralph development loop to Zig and building shared infrastructure for both TUI applications and a future Vulkan-accelerated terminal emulator.

---

## Table of Contents

1. [Original Hot Ralph Script](#original-hot-ralph-script)
2. [Why Port to Zig](#why-port-to-zig)
3. [Feature Additions](#feature-additions)
4. [TUI Architecture](#tui-architecture)
5. [Shared Module Design](#shared-module-design)
6. [Rust References for Porting](#rust-references-for-porting)
7. [Implementation Roadmap](#implementation-roadmap)

---

## Original Hot Ralph Script

The current implementation is a bash script integrating with the Beads task tracking system for atomic development loops with Claude.

```bash
#!/bin/bash
# hot_ralph - Beads-integrated development loop
# Requires: .beads directory with ready tasks already created
# Uses beads (br) for atomic task tracking
set -e

AUTO_MODE=false
PROJECT_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto|-a) AUTO_MODE=true ;;
        *) PROJECT_DIR="$1" ;;
    esac
    shift
done

JQ_STREAM='select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty'

log() { echo "[$(date '+%H:%M:%S')] $*"; }

die() { echo "ERROR: $*" >&2; exit 1; }

require_file() {
    [[ -f "$PROJECT_DIR/$1" ]] || die "Missing $1"
}

require_command() {
    command -v "$1" &>/dev/null || die "$1 is required${2:+ - $2}"
}

check_requirements() {
    require_file SPEC.md
    require_file VISION.md
    require_file TESTING.md
    require_command jq
    require_command claude
    require_command br "https://github.com/Dicklesworthstone/beads_rust"

    [[ -d "$PROJECT_DIR/.beads" ]] || die ".beads directory not found - run: br init"
    mkdir -p "$PROJECT_DIR/.hot_ralph"
}

run_claude() {
    local label="${2:-claude}"
    local outfile="$PROJECT_DIR/.hot_ralph/$(date '+%Y%m%d_%H%M%S')_${label}.md"
    log "Output: $outfile"

    claude --print --verbose --output-format stream-json --dangerously-skip-permissions "$1" \
        | jq --unbuffered -rj "$JQ_STREAM" \
        | tee "$outfile"
    echo
}

prompt_user() {
    if [[ "$AUTO_MODE" == true ]]; then
        echo "${2:-y}"
        return
    fi
    read -p "$1" -n 1 -r
    echo
    echo "$REPLY"
}

beads_ready_count() {
    br ready --json 2>/dev/null | jq 'length // 0'
}

beads_get_next() {
    br ready --json 2>/dev/null | jq 'sort_by(.priority, .created_at) | .[0] // empty'
}

beads_claim() {
    br update "$1" --status in_progress --json &>/dev/null
    log "Claimed task: $1"
}

beads_complete() {
    br close "$1" --reason "${2:-Completed}" --json &>/dev/null
    log "Completed task: $1"
}

beads_sync() {
    br sync &>/dev/null
    log "Beads synced"
}

commit_beads() {
    beads_sync
    git diff --quiet .beads/ 2>/dev/null || {
        git add .beads/
        git commit -m "$1" --no-verify 2>/dev/null || true
    }
}

commit_all() {
    git diff --quiet 2>/dev/null && [[ -z $(git status --porcelain 2>/dev/null) ]] && return
    git add -A
    git commit -m "$1" --no-verify 2>/dev/null || true
}

graceful_exit() {
    echo
    log "Interrupted - syncing beads..."
    beads_sync
    exit 0
}

countdown_window() {
    local seconds="${1:-5}"
    trap graceful_exit SIGINT
    echo
    for ((i=seconds; i>0; i--)); do
        printf "\r[Ctrl+C to stop] Next task in %d... " "$i"
        sleep 1
    done
    printf "\r%-40s\r" " "
    trap - SIGINT
}

cd "$PROJECT_DIR"
check_requirements

[[ $(beads_ready_count) -gt 0 ]] || die "No ready tasks - run: br create \"Task\" --type task --description \"...\""

log "Starting hot_ralph (beads mode)"
log "Project: $PROJECT_DIR"
[[ "$AUTO_MODE" == true ]] && log "AUTO MODE ENABLED"

while true; do
    # Window for user to Ctrl+C between tasks
    countdown_window 5

    task_json=$(beads_get_next)

    if [[ -z "$task_json" || "$task_json" == "null" ]]; then
        echo
        echo "==============================================================="
        echo "  ALL TASKS COMPLETE!"
        echo "==============================================================="
        commit_beads "beads: final sync"
        git push 2>/dev/null || true
        run_claude "All beads tasks are complete.
Review @VISION.md - does the codebase embody the vision?
Summarize what was built and identify any remaining gaps." "final_review"
        exit 0
    fi

    # Extract all task fields in one jq call
    eval "$(echo "$task_json" | jq -r '@sh "task_id=\(.id) task_title=\(.title) task_desc=\(.description // "No description") task_priority=\(.priority) task_tags=\(.tags // [] | join(", "))"')"
    ready_count=$(beads_ready_count)

    echo
    echo "---------------------------------------------------------------"
    echo "  TASK: $task_title"
    echo "  ID: $task_id | Priority: $task_priority | Ready: $ready_count"
    [[ -n "$task_tags" ]] && echo "  Tags: $task_tags"
    echo "---------------------------------------------------------------"
    echo "$task_desc"
    echo "---------------------------------------------------------------"

    case "$(prompt_user "Execute? [Y/n/s(kip)/v(iew all)/q] " "y")" in
        [Qq]) log "Exiting - syncing beads..."; beads_sync; exit 0 ;;
        [Ss]) log "Skipping task (marking complete)"; beads_complete "$task_id" "Skipped by user"; continue ;;
        [Vv]) log "Ready tasks:"; br ready; continue ;;
        [Nn]) log "Skipping task (remains in queue)"; continue ;;
    esac

    beads_claim "$task_id"
    log "Executing task..."

    safe_task_id="${task_id//[^[:alnum:]]/_}"

    run_claude "You are implementing a single atomic task.

## Task
**$task_title**

$task_desc

## Context Files
- @SPEC.md - Project specification
- @VISION.md - Project vision
- @TESTING.md - Testing requirements

## Instructions
1. Implement ONLY what this task specifies - no more, no less
2. Run any validation criteria specified in the description
3. If validation passes, commit with message based on task title
4. Report success or failure clearly

This is an ATOMIC task. Stay focused." "task_${safe_task_id}"

    echo
    case "$(prompt_user "Task successful? [Y/n/r(etry)] " "y")" in
        [Nn])
            log "Task not complete - keeping in progress"
            ;;
        [Rr])
            log "Retrying task..."
            br update "$task_id" --status open --json &>/dev/null
            continue
            ;;
        *)
            log "Running code simplifier..."
            run_claude "Review the code changes made for task: $task_title

Use the code-simplifier:code-simplifier agent approach:
1. Find recently modified files (check git status and git diff)
2. Simplify and refine code for clarity, consistency, and maintainability
3. Preserve all functionality - no behavior changes
4. Run tests to verify nothing broke
5. If tests pass, commit any simplification changes

Focus on the code that was just modified. Keep changes minimal and safe." "simplify_${safe_task_id}"

            git diff --quiet 2>/dev/null || {
                log "Committing simplification changes..."
                commit_all "refactor: simplify code from $task_id"
            }
            beads_complete "$task_id" "Completed successfully"
            commit_beads "beads: complete $task_id"
            ;;
    esac

    (( RANDOM % 5 == 0 )) && {
        log "Pushing to remote..."
        git push 2>/dev/null || log "Push failed (will retry later)"
    }
done
```

### Problems with the Bash Version

1. **Silent failures**: `set -e` doesn't catch all failure modes (jq returning null, git commands failing mid-operation)
2. **Code injection risk**: The `eval "$(echo "$task_json" | jq -r ...)"` pattern is vulnerable to malicious task titles escaping and running arbitrary commands
3. **External dependencies**: Requires jq, claude, br to all be installed and in PATH
4. **No proper state management**: Crash mid-task and state is unclear
5. **Limited error recovery**: No good way to handle partial failures

---

## Why Port to Zig

### 1. Proper Error Handling

Zig's error unions force handling of every failure path:

```zig
const task = beads.getNextReady() catch |err| switch (err) {
    error.NoBead => break :main_loop, // clean exit
    error.CorruptedState => return recoverBeadsState(),
    else => |e| return e,
};
```

### 2. Eliminate Shell Quoting Nightmares

Native JSON parsing instead of eval + jq:

```zig
const Task = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    priority: i32,
    tags: []const []const u8,
};
const task = try std.json.parseFromSlice(Task, allocator, json_bytes, .{});
```

### 3. Single Static Binary

No runtime dependencies. Bundle everything. Cross-compile for different machines.

### 4. Better Subprocess Management

`std.process.Child` is cleaner than bash backgrounding. Stream Claude's output while also capturing it:

```zig
var claude = std.process.Child.init(&.{ "claude", "--print", ... }, allocator);
claude.stdout_behavior = .Pipe;
// Stream to terminal AND capture to file simultaneously
```

---

## Feature Additions

### 1. Concurrent Git Operations

Push in background while next task runs:

```zig
const push_frame = async gitPush();
// ... do next task ...
await push_frame catch |err| log.warn("push failed: {}", .{err});
```

### 2. Task Dependency DAG

Model dependencies explicitly instead of relying on priority sorting:

```zig
const TaskGraph = struct {
    tasks: std.AutoHashMap(TaskId, Task),
    deps: std.AutoHashMap(TaskId, []const TaskId),
    
    fn getReady(self: *@This()) []Task {
        // Return tasks with all deps satisfied
    }
};
```

### 3. Embedded SQLite for Metrics

Track timing, success rates, retry counts. Potential for semantic search over past task descriptions:

```zig
const history = try db.query(
    "SELECT title, solution FROM completed_tasks ORDER BY embedding <-> ? LIMIT 3",
    .{current_task.embedding}
);
```

### 4. Structured Prompt Templates

Comptime-validated prompt construction:

```zig
const TaskPrompt = struct {
    task: Task,
    context_files: []const []const u8,
    
    pub fn format(self: @This(), writer: anytype) !void {
        try writer.print(
            \\## Task
            \\**{s}**
            \\
            \\{s}
            , .{ self.task.title, self.task.description orelse "No description" }
        );
    }
};
```

### 5. TUI with State Visualization

Replace countdown/prompt loop with proper terminal UI showing:
- Current task tree with dependencies
- Running task with live output
- Queue of upcoming tasks
- Git sync status

### 6. Checkpoint/Resume

If killed mid-task, resume exactly where you were. Serialize state to `.hot_ralph/state.zig.zon`.

### 7. Claude Streaming Parser

Parse streaming JSON directly instead of piping through jq. Handle tool use, thinking blocks, etc. Detect when Claude is about to make a commit and interject.

---

## TUI Architecture

### What Rich Gives You vs What TUI Requires

| Layer | Rich Gives You | TUI Requires |
|-------|---------------|--------------|
| Output | Styled spans, tables, panels | ✓ covered |
| Screen | Basic print | Alternate buffer, raw mode |
| Input | Nothing | Key/mouse events, event loop |
| Layout | None | Constraint solver, flex |
| Widgets | Static render | Stateful, focusable, interactive |
| Render | Full repaint | Diffing (only redraw changes) |

### Ratatui vs Bubbletea Comparison

#### Ratatui (Recommended)

- Immediate mode - describe UI each frame, library diffs and renders
- Constraint-based layout (`Constraint::Percentage(50)`, `Min`, `Max`, `Ratio`)
- Widget is just a trait: `fn render(self, area: Rect, buf: *Buffer)`
- Rust ownership maps cleanly to Zig - no hidden allocations
- Backend abstraction (crossterm/termion) - write a Zig termios backend

```zig
// Ratatui's model translates naturally:
const Widget = struct {
    pub fn render(self: *const @This(), area: Rect, buf: *Buffer) void {
        // Draw into buffer cells
    }
};

// Layout is just constraint solving:
const chunks = Layout.default()
    .direction(.horizontal)
    .constraints(&.{ .percentage(30), .min(10), .fill(1) })
    .split(frame.area);

// Immediate mode loop:
while (running) {
    terminal.draw(|frame| {
        renderTaskList(frame, chunks[0], &tasks);
        renderCurrentTask(frame, chunks[1], current);
        renderLog(frame, chunks[2], &log_buffer);
    });
    
    if (try event.poll(timeout)) |ev| {
        // handle input
    }
}
```

#### Bubbletea

- Elm architecture: `Model`, `Update(msg) -> (Model, Cmd)`, `View() -> string`
- Message passing for everything
- More opinionated, harder to escape the pattern
- Go's interfaces are looser - more work figuring out actual contracts
- Lipgloss (styling lib) overlaps with existing Rich port

**Verdict**: Ratatui fits better. Elm architecture adds indirection not needed for hot_ralph's relatively simple state.

### Minimal TUI Port Strategy

Core pieces needed (don't need all of ratatui):

1. **Terminal backend** (~500 lines)
   - Raw mode, alternate screen, cursor hide
   - ANSI parsing for input (arrow keys, etc.)
   - Resize signal handling

2. **Buffer + Cell** (~300 lines)
   - 2D grid of styled cells
   - Diff against previous frame

3. **Rect + Layout** (~400 lines)
   - Constraint solver (ratatui's is simple, not full Cassowary)
   - Split areas recursively

4. **Core widgets** (as needed)
   - Block (borders, titles)
   - List (scrollable, selectable)
   - Paragraph (Rich text fits here)
   - Gauge (progress)

**Skip**: charts, canvas, sparklines, calendar

### Alternative: Just the Backend

Port only crossterm's event/terminal handling and build own widget layer on top of Rich port. Crossterm is ~2k lines of actual logic (rest is Windows compat).

```zig
const Terminal = struct {
    buf: Buffer,
    prev_buf: Buffer,
    
    pub fn draw(self: *@This(), f: fn(*Frame) void) !void {
        f(&.{ .buf = &self.buf, .area = self.size() });
        try self.flush(); // diff and write only changes
        std.mem.swap(Buffer, &self.buf, &self.prev_buf);
        self.buf.clear();
    }
};
```

---

## Shared Module Design

### System Architecture Comparison

```
Terminal Emulator:
  [Raw Input] → [Input Parser] → [Events] → [PTY write]
  [PTY read] → [ANSI Parser] → [State Machine] → [Cell Grid] → [Vulkan]

TUI App (runs IN a terminal):
  [stdin] → [Input Parser] → [Events] → [App] → [Cell Grid] → [ANSI Gen] → [stdout]
```

### Shared Modules

#### 1. `cell` - The Core Primitive

```zig
pub const Style = packed struct {
    fg: Color,
    bg: Color,
    attrs: Attributes,
    
    pub const Attributes = packed struct(u8) {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        blink: bool = false,
        reverse: bool = false,
        strikethrough: bool = false,
        _pad: u2 = 0,
    };
};

pub const Cell = struct {
    char: u21, // codepoint
    width: u2, // 0, 1, or 2 (wcwidth)
    style: Style,
};

pub const Buffer = struct {
    cells: []Cell,
    width: u16,
    height: u16,
    
    pub fn diff(self: *const @This(), other: *const @This()) DiffIterator { ... }
};
```

Both systems need this identical representation.

#### 2. `input` - Event Model

```zig
pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    resize: struct { w: u16, h: u16 },
    paste: []const u8,
    focus: bool,
};

pub const Key = struct {
    code: Code,
    mods: Modifiers,
    
    pub const Code = union(enum) {
        char: u21,
        f: u4,
        up, down, left, right,
        home, end, page_up, page_down,
        insert, delete, backspace, enter, tab, escape,
    };
    
    pub const Modifiers = packed struct(u4) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,
    };
};
```

#### 3. `ansi.parse` - Escape Sequence Parser

```zig
// Streaming parser - feed bytes, get actions
pub const Parser = struct {
    state: State,
    params: BoundedArray(u16, 16),
    intermediates: BoundedArray(u8, 4),
    
    pub fn feed(self: *@This(), byte: u8) ?Action {
        // State machine: ground, escape, csi_entry, csi_param, osc_string, etc.
    }
    
    pub const Action = union(enum) {
        print: u21,
        execute: u8, // C0 control
        csi: CSI,
        osc: OSC,
        esc: Escape,
    };
};
```

- **Terminal emulator**: parses PTY output → updates screen state
- **TUI input parser**: parses stdin → extracts key/mouse events (CSI sequences encode arrow keys, mouse, etc.)

### Divergence Points

| Layer | Terminal Emulator | TUI Library |
|-------|-------------------|-------------|
| ANSI direction | Parse (consume) | Generate (produce) |
| State machine | Full VT100/xterm (cursor, scroll regions, charset, modes) | None - app manages own state |
| Buffer purpose | Single screen state | Double buffer for diffing |
| Rendering | Glyph atlas, Vulkan pipeline | Printf escape codes |

### Emulator-Only Pieces

```zig
// Terminal state - NOT needed by TUI
pub const Terminal = struct {
    screen: Buffer,
    alt_screen: Buffer,
    cursor: Cursor,
    scroll_region: struct { top: u16, bottom: u16 },
    modes: Modes, // DECAWM, DECCKM, DECSCNM, bracketed paste, etc.
    tabs: std.DynamicBitSet,
    charsets: [4]Charset,
    saved_cursor: ?Cursor,
    
    // This is the complex part - handling all the sequences
    pub fn execute(self: *@This(), action: ansi.Action) void {
        switch (action) {
            .csi => |csi| self.handleCSI(csi),
            .print => |cp| self.putChar(cp),
            // ... hundreds of cases
        }
    }
};
```

### Suggested Module Structure

```
src/
├── termlib/           # SHARED - extract as separate package
│   ├── cell.zig       # Cell, Style, Buffer
│   ├── input.zig      # Event, Key, Mouse
│   ├── ansi/
│   │   ├── parse.zig  # Streaming parser
│   │   └── seq.zig    # Sequence constants + builders
│   └── wcwidth.zig    # Character width tables
│
├── tui/               # TUI library (hot_ralph uses this)
│   ├── terminal.zig   # Raw mode, alternate screen (termios)
│   ├── input.zig      # stdin → Event (uses ansi.parse)
│   ├── render.zig     # Buffer diff → stdout (uses ansi.seq)
│   ├── layout.zig     # Constraint solver
│   └── widgets/
│
└── emulator/          # Terminal emulator
    ├── terminal.zig   # Full VT state machine
    ├── pty.zig        # PTY master handling
    ├── font.zig       # FreeType + glyph atlas
    └── render/        # Vulkan pipeline
```

The `termlib` package is ~1500-2000 lines and both projects import it.

---

## Rust References for Porting

### ANSI Parser

**`vte`** - The gold standard, used by Alacritty
```
https://github.com/alacritty/vte
```

Based on Paul Williams' state machine (https://vt100.net/emu/dec_ansi_parser). The state table is generated/declarative:

```rust
// vte/src/table.rs - literally a 2D table
static STATE_CHANGE: [[u8; 256]; 16] = [...]
```

~800 lines of actual logic. Same state machine for PTY output or stdin escape sequences.

### Cell + Buffer

**`ratatui`** - `src/buffer.rs` and `src/style.rs`
```
https://github.com/ratatui/ratatui
```

Clean, minimal Cell:

```rust
// ratatui/src/buffer/cell.rs
pub struct Cell {
    symbol: CompactString,  // you'd use u21 + width
    fg: Color,
    bg: Color,
    modifier: Modifier,
}
```

Buffer diffing in `Buffer::diff()` - simple and correct.

### Input Parsing

**`crossterm`** - `src/event/source/` and `src/event/read.rs`
```
https://github.com/crossterm-rs/crossterm
```

Handles parsing stdin into structured events:
- `src/event/sys/unix/parse.rs` - CSI sequence → Key/Mouse
- `src/terminal/sys/unix.rs` - termios raw mode setup

### Full Terminal State Machine

**`alacritty_terminal`** - `src/term/mod.rs` and `src/ansi.rs`
```
https://github.com/alacritty/alacritty/tree/master/alacritty_terminal
```

Full VT100/xterm implementation (not needed for TUI, needed for emulator):

```rust
// alacritty_terminal/src/term/mod.rs
impl Handler for Term {
    fn input(&mut self, c: char) { ... }
    fn goto(&mut self, line: Line, col: Column) { ... }
    fn set_scrolling_region(&mut self, top: usize, bottom: Option<usize>) { ... }
    // ~100 more handlers
}
```

### wcwidth

**`unicode-width`** - tiny, just lookup tables
```
https://github.com/unicode-rs/unicode-width
```

Or grab tables from Alacritty's fork which stays more current.

---

## Implementation Roadmap

### Port Order

| Order | Component | Source | Lines | Purpose |
|-------|-----------|--------|-------|---------|
| 1 | vte (parser) | alacritty/vte | ~800 | Shared foundation |
| 2 | crossterm (input) | crossterm-rs/crossterm | ~500 | TUI needs this first |
| 3 | ratatui (buffer/diff) | ratatui/ratatui | ~600 | Then rendering |
| 4 | alacritty_terminal | alacritty/alacritty | ~5000 | Emulator later |

### Phase 1: termlib Foundation

Start with shared `termlib` package:

```zig
// State machine core
const State = enum(u4) { ground, escape, escape_intermediate, csi_entry, csi_param, ... };

fn advance(state: State, byte: u8) struct { new_state: State, action: ?Action } {
    // Table lookup + action emission
}
```

The table itself is ~300 lines of constants. Rest is Action handling.

### Phase 2: TUI for hot_ralph

Build on termlib:
- Terminal backend (raw mode, alternate screen)
- Input event parsing
- Buffer diffing renderer
- Layout constraint solver
- Basic widgets

### Phase 3: Vulkan Terminal Emulator

Later, add:
- Full VT state machine
- PTY handling
- FreeType glyph atlas
- Vulkan rendering pipeline

---

## Quick Reference: Key Files to Study

| Purpose | Rust Crate | Key Files |
|---------|------------|-----------|
| ANSI state machine | vte | `src/lib.rs`, `src/table.rs` |
| Cell/Buffer types | ratatui | `src/buffer/cell.rs`, `src/buffer.rs` |
| Style types | ratatui | `src/style.rs` |
| Buffer diffing | ratatui | `src/buffer.rs` → `Buffer::diff()` |
| Input parsing | crossterm | `src/event/sys/unix/parse.rs` |
| Raw mode setup | crossterm | `src/terminal/sys/unix.rs` |
| Layout constraints | ratatui | `src/layout.rs` |
| VT100 handlers | alacritty_terminal | `src/term/mod.rs`, `src/ansi.rs` |
| Character width | unicode-width | `src/tables.rs` |

---

## Notes

- Start with `termlib` + `tui` for hot_ralph
- When building emulator, `termlib` is ready - focus on VT state machine and Vulkan
- Rich port likely already has chunks of `cell.zig` (Style, spans)
- The ANSI parser state machine is well-defined enough to generate from spec if preferred
