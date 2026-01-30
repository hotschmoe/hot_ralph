# ralph Features (Phase 1 CLI)

## Features from Bash Script (Port)

These features exist in the original `hot_ralph` bash script and must be ported to Zig.

### Core Workflow

| Feature | Bash Implementation | Notes |
|---------|---------------------|-------|
| Project directory argument | `PROJECT_DIR="$1"` | Default to current directory |
| Auto mode | `--auto` / `-a` flag | Skip all user prompts, assume yes |
| Requirements check | `require_file`, `require_command` | Validate SPEC.md, VISION.md, TESTING.md, claude, br, .beads/ |
| Output directory | `.hot_ralph/` | Create if missing |
| Timestamped output files | `YYYYMMDD_HHMMSS_{label}.md` | All Claude responses saved |

### Beads Integration

| Feature | Bash Implementation | Notes |
|---------|---------------------|-------|
| Ready count | `br ready --json \| jq 'length'` | Check if tasks available |
| Get next task | `br ready --json \| jq 'sort_by(.priority, .created_at) \| .[0]'` | Priority + creation order |
| Claim task | `br update <id> --status in_progress` | Mark as in-progress |
| Complete task | `br close <id> --reason "..."` | Mark as done |
| Sync beads | `br sync` | Export to JSONL for git |

### Claude Integration

| Feature | Bash Implementation | Notes |
|---------|---------------------|-------|
| Run Claude | `claude --print --verbose --output-format stream-json --dangerously-skip-permissions` | Streaming JSON output |
| Stream to terminal | `jq \| tee` | Show output while capturing |
| Task prompt | Structured markdown with context files | @SPEC.md, @VISION.md, @TESTING.md |
| Simplification pass | Second Claude call after task success | Review and simplify changes |
| Final review | Claude call when all tasks complete | Check against VISION.md |

### Git Operations

| Feature | Bash Implementation | Notes |
|---------|---------------------|-------|
| Commit beads | `git add .beads/ && git commit` | After task completion |
| Commit all | `git add -A && git commit` | After simplification |
| Periodic push | `git push` (20% chance per task) | Background, ignore failures |

### User Interaction

| Feature | Bash Implementation | Notes |
|---------|---------------------|-------|
| Execute prompt | `[Y/n/s(kip)/v(iew all)/q]` | Before each task |
| Success prompt | `[Y/n/r(etry)]` | After Claude completes |
| Countdown window | 5 seconds between tasks | Ctrl+C opportunity |
| Graceful exit | `trap SIGINT` | Sync beads before exit |
| Task display | Show title, ID, priority, ready count, tags, description | Clear task context |

### Error Handling (Improve)

| Bash Problem | Zig Solution |
|--------------|--------------|
| Silent `set -e` failures | Explicit error unions |
| `eval` code injection risk | Native JSON parsing |
| Unclear crash state | Checkpoint/resume |
| jq dependency | stdlib JSON |

---

## New Features (CLI Enhancements)

Features not in the bash script that improve the CLI experience.

### Checkpoint/Resume

**Problem**: Crash mid-task and state is unclear.

**Solution**: Persist state to `.hot_ralph/state.json`:
```
{
    "current_task_id": "abc123",
    "phase": "executing",
    "output_file": ".hot_ralph/20250130_143022_task_abc123.md",
    "started_at": "2025-01-30T14:30:22Z"
}
```

On startup, detect existing state and offer to resume.

Phases: `idle`, `executing`, `awaiting_confirmation`, `simplifying`

### Native JSON Streaming Parser

**Problem**: Bash uses `jq --unbuffered` to parse Claude's streaming JSON. Fragile, external dependency.

**Solution**: Parse streaming JSON directly in Zig:
```zig
const StreamParser = struct {
    pub fn feed(self: *@This(), chunk: []const u8) ?TextEvent {
        // Extract assistant text from stream-json format
    }
};
```

Handle tool use blocks, thinking blocks, and text content. No jq dependency.

### Concurrent Git Push

**Problem**: `git push` blocks the workflow.

**Solution**: Push in background thread while next task runs:
```zig
const push_thread = try std.Thread.spawn(.{}, gitPush, .{});
// ... continue with next task ...
push_thread.join();
```

Non-blocking, errors logged but don't halt workflow.

### Structured Prompt Templates

**Problem**: Bash embeds prompts as heredocs. Hard to test, modify, or validate.

**Solution**: Comptime-validated prompt structs:
```zig
const TaskPrompt = struct {
    task: Task,
    context_files: []const []const u8,

    pub fn render(self: @This(), writer: anytype) !void {
        // Type-safe template rendering
    }
};
```

Templates can be unit tested. Missing fields caught at compile time.

### Better Task Display

**Problem**: Bash shows minimal task info.

**Solution**: Show dependency context:
```
---------------------------------------------------------------
  TASK: Implement feature X
  ID: abc123 | Priority: 1 | Ready: 5 | Blocked: 2
  Tags: feature, api
  Blocks: def456, ghi789
---------------------------------------------------------------
Description here...
---------------------------------------------------------------
```

Show what this task unblocks, helping prioritization decisions.

### Validation Before Execution

**Problem**: Bash only checks requirements at startup.

**Solution**: Validate before each task:
- Git working directory clean (or warn)
- Claude CLI still authenticated
- Beads state consistent
- Output directory writable

Fail fast with actionable error messages.

### Dry Run Mode

**Problem**: No way to preview what ralph will do.

**Solution**: `--dry-run` flag:
```bash
ralph --dry-run /path/to/project
```

Shows:
- Tasks that would be executed (in order)
- Prompts that would be sent
- Files that would be created

No Claude calls, no git operations, no state changes.

### Verbose/Quiet Modes

**Problem**: Bash output is fixed verbosity.

**Solution**:
- `--quiet` / `-q`: Only show errors and prompts
- `--verbose` / `-v`: Show all commands, full prompts, timing

Default: Current bash behavior (task info + Claude output).

### Exit Codes

**Problem**: Bash exits 0 or 1, no granularity.

**Solution**: Meaningful exit codes:
| Code | Meaning |
|------|---------|
| 0 | Success - all tasks complete |
| 1 | Error - missing requirements |
| 2 | Error - Beads operation failed |
| 3 | Error - Claude operation failed |
| 4 | Error - Git operation failed |
| 130 | Interrupted (Ctrl+C) |

Scripts can handle different failure modes appropriately.

### Exit After Current Task

**Problem**: User wants to stop but must wait for 5-second countdown window to Ctrl+C.

**Solution**: Non-blocking input monitoring during task execution:
- User presses `e` at any time during the loop
- ralph sets `exit_requested` flag
- Current task completes normally (Claude finishes, simplification runs, commit happens)
- Before starting next task, ralph checks flag and exits cleanly

```
[14:32:15] Executing task abc123...
e
[14:32:16] Exit requested - will stop after current task completes
[14:35:42] Task complete. Syncing beads...
[14:35:43] Exiting as requested.
```

Benefits:
- No lost work (current task completes fully)
- No waiting for countdown window
- Cleaner than Ctrl+C mid-execution

Implementation: Spawn input monitoring thread that sets atomic flag on `e` keypress.

### Claude Introspection

**Problem**: Development patterns emerge over time. CLAUDE.md becomes stale. Opportunities for skills/agents go unnoticed.

**Solution**: Periodic self-improvement pass (20% chance every 5 completed tasks):

1. Claude reads last 5-10 task logs from `.hot_ralph/`
2. Analyzes patterns: repeated operations, common errors, workflow friction
3. Proposes updates:
   - CLAUDE.md additions (new patterns, gotchas discovered)
   - New skill in `.claude/skills/` (repeated multi-step operations)
   - New agent in `.claude/agents/` (specialized task types)

```
[15:20:00] Running introspection (5 tasks completed)...
[15:20:45] Introspection complete.

Suggestions:
1. Add to CLAUDE.md: "Always run zig fmt before commits"
2. Create skill: /fix-imports - automated import cleanup pattern seen 3x
3. No agent suggestions

Apply suggestions? [Y/n/review]
```

Introspection prompt:
```
Review the last {n} task logs from this development session.

## Task Logs
{concatenated logs}

## Current CLAUDE.md
{claude_md_content}

## Existing Skills
{list of .claude/skills/}

## Existing Agents
{list of .claude/agents/}

Analyze for:
1. Patterns that should be documented in CLAUDE.md
2. Repeated multi-step operations that could become a skill
3. Specialized task types that could benefit from a dedicated agent

For each suggestion, provide:
- What to add/create
- Why (evidence from logs)
- Exact content to add

Be conservative - only suggest high-value additions.
```

State tracking: `.hot_ralph/state.json` includes `tasks_since_introspection` counter.

---

## Phase 1.9: Context Optimization Research

Before Phase 2 (TUI), research and prototype context-saving strategies to reduce token usage per loop.

### Problem

Each ralph loop sends full context to Claude:
- SPEC.md, VISION.md, TESTING.md (potentially large)
- Task description
- Previous conversation context (if resuming)

Token costs compound over many tasks. Long documents waste tokens on unchanged content.

### Research Areas

#### 1. Incremental Context

Instead of sending full files every time:
- Hash file contents, send only if changed since last task
- Claude maintains mental model, ralph sends diffs
- Risk: Claude context window resets between calls

#### 2. Context Summarization

Pre-process large files:
- Generate summaries of SPEC.md, VISION.md at session start
- Send summary + relevant sections only
- Trade accuracy for token efficiency

#### 3. Semantic Chunking

Split documents into semantic sections:
- Index sections by topic/keyword
- Send only sections relevant to current task
- Requires understanding task-to-context mapping

#### 4. Session Persistence

Explore Claude's conversation continuation:
- Can we maintain a session across multiple tasks?
- How does `--resume` interact with ralph's workflow?
- Token implications of long vs. fresh sessions

#### 5. Local Context Cache

Cache Claude's "understanding" locally:
- After first task, Claude summarizes its understanding
- Subsequent tasks send summary instead of raw files
- Refresh periodically or on file change

### Experiments to Run

| Experiment | Measure | Success Criteria |
|------------|---------|------------------|
| Baseline token usage | Tokens per task (avg) | Establish baseline |
| Summary-only context | Task success rate, tokens | <50% tokens, >90% success |
| Incremental diffs | Task success rate, tokens | Measurable token reduction |
| Session continuation | Tokens across 10 tasks | Sublinear growth |

### Deliverables

1. Benchmark script measuring tokens per task
2. Summary generation prompt for context files
3. Recommendation for Phase 2 context strategy
4. Implementation if clear winner emerges

### Non-Goals

- Changing Claude's behavior or capabilities
- Complex caching infrastructure
- Anything requiring external services

---

## Deferred to Phase 2 (TUI)

These features require terminal UI and are out of scope for Phase 1:

- Live task tree visualization
- Streaming output panel
- Git status indicators
- Keyboard navigation
- Task reordering UI
- Metrics dashboard

---

## Deferred to Phase 3+

These features are complex and not needed for initial CLI:

- Task dependency DAG modeling
- Embedded SQLite metrics database
- Semantic search over past tasks
- Multiple AI backend support
