# ralph Technical Specification

## Overview

ralph is a CLI tool that orchestrates atomic development tasks by integrating Claude AI with the Beads task tracking system. It replaces a bash script with a robust Zig implementation featuring proper error handling, native JSON parsing, and reliable subprocess management.

## Phase 1: CLI Tool

### Core Responsibilities

1. **Task Queue Management**: Interface with Beads (`br` CLI) to fetch, claim, and complete tasks
2. **Claude Integration**: Spawn Claude with structured prompts, stream output, capture responses
3. **Git Operations**: Commit changes atomically, sync Beads state, push periodically
4. **User Interaction**: Prompt for confirmations, handle Ctrl+C gracefully, support auto-mode

### Module Structure

```
src/
├── main.zig           # Entry point, argument parsing
├── root.zig           # Library exports
├── config.zig         # Configuration and requirements checking
├── beads.zig          # Beads CLI wrapper (br commands)
├── claude.zig         # Claude subprocess management
├── git.zig            # Git operations
├── prompt.zig         # Structured prompt templates
├── ui.zig             # User prompts and output formatting
└── state.zig          # Checkpoint/resume state management
```

### Data Types

```zig
pub const Task = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    priority: i32,
    tags: []const []const u8,
    status: Status,

    pub const Status = enum { open, in_progress, closed, deferred };
};

pub const Config = struct {
    project_dir: []const u8,
    auto_mode: bool,
    output_dir: []const u8,  // .hot_ralph/
};

pub const RunResult = union(enum) {
    success: struct { output_file: []const u8 },
    failure: struct { message: []const u8 },
    interrupted,
};
```

### Beads Integration

```zig
pub const Beads = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,

    pub fn readyCount(self: *@This()) !usize;
    pub fn getNextReady(self: *@This()) !?Task;
    pub fn claim(self: *@This(), task_id: []const u8) !void;
    pub fn complete(self: *@This(), task_id: []const u8, reason: []const u8) !void;
    pub fn sync(self: *@This()) !void;
};
```

### Claude Integration

```zig
pub const Claude = struct {
    allocator: std.mem.Allocator,

    pub fn run(self: *@This(), prompt: []const u8, opts: RunOptions) !RunResult;

    pub const RunOptions = struct {
        output_file: []const u8,
        stream_to_terminal: bool = true,
    };
};
```

Subprocess invocation:
```
claude --print --verbose --output-format stream-json --dangerously-skip-permissions "<prompt>"
```

Output is JSON-streamed, parsed to extract assistant text responses.

### Prompt Structure

Task execution prompt:
```
You are implementing a single atomic task.

## Task
**{title}**

{description}

## Context Files
- @SPEC.md - Project specification
- @VISION.md - Project vision
- @TESTING.md - Testing requirements

## Instructions
1. Implement ONLY what this task specifies - no more, no less
2. Run any validation criteria specified in the description
3. If validation passes, commit with message based on task title
4. Report success or failure clearly

This is an ATOMIC task. Stay focused.
```

Code simplification prompt:
```
Review the code changes made for task: {title}

Use the code-simplifier approach:
1. Find recently modified files (check git status and git diff)
2. Simplify and refine code for clarity, consistency, and maintainability
3. Preserve all functionality - no behavior changes
4. Run tests to verify nothing broke
5. If tests pass, commit any simplification changes

Focus on the code that was just modified. Keep changes minimal and safe.
```

### Error Handling

All operations return error unions. Key error types:

```zig
pub const BeadsError = error{
    NotInitialized,      // .beads/ directory missing
    NoReadyTasks,        // Queue empty
    TaskNotFound,
    InvalidJson,
    CommandFailed,
};

pub const ClaudeError = error{
    NotInstalled,
    NotAuthenticated,
    SpawnFailed,
    StreamInterrupted,
    OutputParseFailed,
};

pub const ConfigError = error{
    MissingSpecMd,
    MissingVisionMd,
    MissingTestingMd,
    NotGitRepo,
};
```

### State Persistence

State file: `.hot_ralph/state.json`

```json
{
    "current_task_id": "abc123",
    "phase": "executing",
    "output_file": ".hot_ralph/20250130_143022_task_abc123.md",
    "started_at": "2025-01-30T14:30:22Z"
}
```

Phases: `idle`, `executing`, `awaiting_confirmation`, `simplifying`

On startup, check for existing state and offer to resume.

### Signal Handling

- **SIGINT (Ctrl+C)**: During countdown, exit gracefully after syncing Beads
- **SIGINT during execution**: Let Claude handle it, then prompt user

### Output Logging

All Claude responses saved to `.hot_ralph/YYYYMMDD_HHMMSS_{label}.md`

Labels: `task_{id}`, `simplify_{id}`, `final_review`

---

## Phase 2: TUI (Future)

Phase 2 adds a terminal user interface with:

- Live task tree visualization
- Streaming Claude output panel
- Git status indicators
- Keyboard navigation

See `docs/hot_ralph_zig_project_reference.md` for TUI architecture details.

---

## Dependencies

External tools (must be in PATH):
- `claude` - Anthropic Claude CLI
- `br` - Beads Rust CLI
- `git` - Version control

Zig dependencies: None (stdlib only)

---

## Configuration

No config file for Phase 1. All configuration via CLI arguments and environment.

Future: `.hot_ralph/config.json` for persistent preferences.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success - all tasks complete |
| 1 | Error - missing requirements |
| 2 | Error - Beads operation failed |
| 3 | Error - Claude operation failed |
| 130 | Interrupted (Ctrl+C) |
