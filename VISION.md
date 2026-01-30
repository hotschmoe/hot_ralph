# ralph Vision

## The Problem

Modern AI-assisted development works best with focused, atomic tasks. But the tooling gap is real:

1. **Task management is disconnected** from the development loop
2. **Claude interactions** require manual prompt construction and context gathering
3. **Bash glue scripts** are fragile, have poor error handling, and fail silently
4. **No state persistence** - crash mid-task and you lose context

The original `hot_ralph` bash script demonstrated the workflow but suffered from:
- Silent failures (`set -e` doesn't catch everything)
- Code injection risks (eval + jq pattern)
- External dependency chaos (jq, claude, br all must be configured)
- No crash recovery

## The Solution

ralph is a single static Zig binary that:
- Integrates directly with Beads for task queue management
- Spawns Claude with proper subprocess handling
- Parses JSON natively (no jq dependency)
- Handles errors explicitly at every step
- Persists state for crash recovery
- Cross-compiles for any platform

## Phased Approach

### Phase 1: CLI Replacement (Current)

Direct port of bash functionality with Zig reliability:
- Same workflow, same user experience
- Proper error handling throughout
- Native JSON parsing for Beads output
- Streaming Claude output with capture
- Checkpoint/resume on crash

**Success criteria**: Can run the full development loop without bash, with better error messages and crash recovery.

### Phase 2: Terminal User Interface

Visual interface showing:
- Task dependency graph
- Current task with live Claude output
- Queue of upcoming tasks
- Git sync status
- Timing and metrics

Architecture: Immediate-mode TUI (Ratatui-style) with constraint-based layout.

**Success criteria**: Same functionality as Phase 1, but with real-time visibility into the development loop state.

### Phase 3: Advanced Features (Future)

- **Concurrent git operations**: Push in background while next task runs
- **Task dependency DAG**: Model explicit dependencies, not just priority
- **Embedded metrics**: SQLite for timing, success rates, retry analysis
- **Semantic search**: Find similar past tasks and their solutions

### Phase 4: Terminal Emulator (Long-term)

The TUI work builds toward a Vulkan-accelerated terminal emulator. Shared infrastructure:

```
termlib/           # Shared between TUI and emulator
  cell.zig         # Cell, Style, Buffer
  input.zig        # Event model (Key, Mouse)
  ansi/parse.zig   # Streaming ANSI parser
  wcwidth.zig      # Character width tables
```

The emulator adds full VT100/xterm state machine, PTY handling, and GPU rendering.

## Design Principles

### 1. Error Handling is Non-Negotiable

Every failure path is explicit. No `catch unreachable` without justification. Errors propagate with context.

```zig
const task = beads.getNextReady() catch |err| switch (err) {
    error.NotInitialized => return fatal("Run 'br init' first"),
    error.NoReadyTasks => break :main_loop,
    else => |e| return e,
};
```

### 2. Single Binary, No Dependencies

The Zig binary is self-contained. External tools (claude, br, git) are validated at startup with clear error messages.

### 3. Explicit Over Implicit

All state is visible. All side effects are logged. Configuration is minimal but documented.

### 4. Crash Recovery by Default

Any long-running operation checkpoints its state. Resume is always possible.

### 5. Streaming Without Blocking

Claude output streams to terminal AND captures to file simultaneously. No buffering entire responses.

## Non-Goals

- **Plugin system**: Complexity for edge cases. Just modify the code.
- **Multiple AI backends**: Claude-specific. Others can fork.
- **Web interface**: Terminal is the interface.
- **Beads reimplementation**: Use br CLI. Don't duplicate logic.

## Success Metrics

1. **Reliability**: Zero silent failures. Every error is reported.
2. **Recoverability**: Can resume from any interruption point.
3. **Visibility**: User always knows what ralph is doing and why.
4. **Speed**: Startup < 100ms. No runtime overhead vs bash.

## The End State

A developer runs `ralph` in any project with Beads tasks. They see their task queue, watch Claude work through each item, and the codebase evolves atomically with full audit trail. If their laptop crashes, they run `ralph` again and it picks up exactly where it left off.

No bash. No jq. No mystery failures. Just focused, atomic development.
