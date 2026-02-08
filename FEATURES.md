# hot_ralph Features (Phase 1 CLI)

## Features from Bash Script (Port)

These features exist in the original `hot_ralph` bash script and must be ported to Zig.

### Core Workflow

| Feature | Bash Implementation | Notes | Status |
|---------|---------------------|-------|--------|
| Project directory argument | `PROJECT_DIR="$1"` | Default to current directory | DONE |
| Auto mode | `--auto` / `-a` flag | Skip all user prompts, assume yes | DONE |
| Requirements check | `require_file`, `require_command` | Validate SPEC.md, VISION.md, TESTING.md, claude, br, .beads/ | DONE |
| Output directory | `.hot_ralph/` | Create if missing | DONE |
| Timestamped output files | `YYYYMMDD_HHMMSS_{label}.md` | All Claude responses saved | DONE |

### Beads Integration

| Feature | Bash Implementation | Notes | Status |
|---------|---------------------|-------|--------|
| Ready count | `br ready --json \| jq 'length'` | Check if tasks available | DONE |
| Get next task | `br ready --json \| jq 'sort_by(.priority, .created_at) \| .[0]'` | Priority + creation order | DONE |
| Claim task | `br update <id> --status in_progress` | Mark as in-progress | DONE |
| Complete task | `br close <id> --reason "..."` | Mark as done | DONE |
| Sync beads | `br sync` | Export to JSONL for git | DONE |

### Claude Integration

| Feature | Bash Implementation | Notes | Status |
|---------|---------------------|-------|--------|
| Run Claude | `claude --print --verbose --output-format stream-json --dangerously-skip-permissions` | Streaming JSON output | DONE |
| Stream to terminal | `jq \| tee` | Show output while capturing | DONE |
| Task prompt | Structured markdown with context files | @SPEC.md, @VISION.md, @TESTING.md | DONE |
| Simplification pass | Second Claude call after task success | Review and simplify changes | DONE |
| Final review | Claude call when all tasks complete | Check against VISION.md | DONE |

### Git Operations

| Feature | Bash Implementation | Notes | Status |
|---------|---------------------|-------|--------|
| Commit beads | `git add .beads/ && git commit` | After task completion | DONE |
| Commit all | `git add -A && git commit` | After simplification | DONE |
| Periodic push | `git push` (20% chance per task) | Background, ignore failures | DONE |

### User Interaction

| Feature | Bash Implementation | Notes | Status |
|---------|---------------------|-------|--------|
| Execute prompt | `[Y/n/s(kip)/v(iew all)/q]` | Before each task | DONE |
| Success prompt | `[Y/n/r(etry)]` | After Claude completes | DONE |
| Countdown window | 5 seconds between tasks | Ctrl+C opportunity | DONE |
| Graceful exit | `trap SIGINT` | Sync beads before exit | DONE |
| Task display | Show title, ID, priority, ready count, tags, description | Clear task context | DONE |

### Error Handling (Improve)

| Bash Problem | Zig Solution | Status |
|--------------|--------------|--------|
| Silent `set -e` failures | Explicit error unions | DONE |
| `eval` code injection risk | Native JSON parsing | DONE |
| Unclear crash state | Checkpoint/resume | DONE |
| jq dependency | stdlib JSON | DONE |

---

## New Features (CLI Enhancements)

Features not in the bash script that improve the CLI experience.

### Checkpoint/Resume - DONE

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

### Native JSON Streaming Parser - DONE

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

### Concurrent Git Push - DONE

**Problem**: `git push` blocks the workflow.

**Solution**: Push in background thread while next task runs:
```zig
const push_thread = try std.Thread.spawn(.{}, gitPush, .{});
// ... continue with next task ...
push_thread.join();
```

Non-blocking, errors logged but don't halt workflow.

### Structured Prompt Templates - DONE

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

### Better Task Display - DONE

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

### Validation Before Execution - DONE

**Problem**: Bash only checks requirements at startup.

**Solution**: Validate before each task:
- Git working directory clean (or warn)
- Claude CLI still authenticated
- Beads state consistent
- Output directory writable

Fail fast with actionable error messages.

### Dry Run Mode - DONE

**Problem**: No way to preview what hot_ralph will do.

**Solution**: `--dry-run` flag:
```bash
hot_ralph --dry-run /path/to/project
```

Shows:
- Tasks that would be executed (in order)
- Prompts that would be sent
- Files that would be created

No Claude calls, no git operations, no state changes.

### Verbose/Quiet Modes - DONE

**Problem**: Bash output is fixed verbosity.

**Solution**:
- `--quiet` / `-q`: Only show errors and prompts
- `--verbose` / `-v`: Show all commands, full prompts, timing

Default: Current bash behavior (task info + Claude output).

### Exit Codes - DONE

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

### Exit After Current Task - DONE

**Problem**: User wants to stop but must wait for 5-second countdown window to Ctrl+C.

**Solution**: Non-blocking input monitoring during task execution:
- User presses `e` at any time during the loop
- hot_ralph sets `exit_requested` flag
- Current task completes normally (Claude finishes, simplification runs, commit happens)
- Before starting next task, hot_ralph checks flag and exits cleanly

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

### Claude Introspection - DONE

**Problem**: Development patterns emerge over time. CLAUDE.md becomes stale. Opportunities for skills/agents go unnoticed.

**Solution**: Periodic self-improvement pass every 5 completed tasks:

1. Claude reads last 10 task logs from `.hot_ralph/`
2. Analyzes patterns: repeated operations, common errors, workflow friction
3. Proposes updates:
   - CLAUDE.md additions (new patterns, gotchas discovered)
   - New skill in `.claude/skills/` (repeated multi-step operations)
   - New agent in `.claude/agents/` (specialized task types)
4. Writes log to `.hot_ralph/{timestamp}_introspection.md`

**Flags**:
- `-i` / `--introspection`: Enable introspection (disabled by default)
- Combined with `-a`: Auto-approve all suggestions

```bash
hot_ralph -i              # Introspection enabled, prompt for approval
hot_ralph -i -a           # Introspection enabled, auto-approve suggestions
hot_ralph -a              # Auto mode, no introspection
```

**Output**:
```
[15:20:00] Running introspection (5 tasks completed, reviewing last 10 logs)...
[15:20:45] Introspection complete. Log: .hot_ralph/20250130_152045_introspection.md

Suggestions:
1. Add to CLAUDE.md: "Always run zig fmt before commits"
2. Create skill: /fix-imports - automated import cleanup pattern seen 3x
3. No agent suggestions

Apply suggestions? [Y/n/review]
```

With `-i -a` (auto mode):
```
[15:20:00] Running introspection (5 tasks completed, reviewing last 10 logs)...
[15:20:45] Introspection complete. Log: .hot_ralph/20250130_152045_introspection.md
[15:20:45] Auto-applying 2 suggestions...
[15:20:46] Updated CLAUDE.md
[15:20:47] Created .claude/skills/fix-imports.md
```

**Introspection log format** (`.hot_ralph/{timestamp}_introspection.md`):
```markdown
# Introspection - 2025-01-30 15:20:45

## Logs Reviewed
- 20250130_140000_task_abc123.md
- 20250130_141500_task_def456.md
- ... (10 total)

## Analysis

### Patterns Observed
- Import cleanup performed manually 3 times
- zig fmt mentioned in 4 task completions

### Suggestions

#### 1. CLAUDE.md Update
**Reason**: zig fmt consistently needed before commits
**Content**:
> Always run `zig fmt src/` before committing Zig code changes.

#### 2. New Skill: /fix-imports
**Reason**: Import cleanup is a repeated 3-step operation
**File**: .claude/skills/fix-imports.md
**Content**:
> [skill content here]

## Applied
- [ ] CLAUDE.md update (pending approval)
- [ ] /fix-imports skill (pending approval)
```

**Introspection prompt**:
```
Review the last 10 task logs from this development session.

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

**State tracking**: `.hot_ralph/state.json` includes `tasks_since_introspection` counter (resets to 0 after introspection runs).

### Plan Mode - DONE

**Problem**: Working on single beads one at a time can be inefficient when multiple related tasks could be planned and executed together.

**Hypothesis**: Using plan mode to implement 5-10 beads in one session will use fewer tokens than processing them individually. Each single-bead invocation pays the full cost of instruction context and project exploration. Batching amortizes that overhead across multiple beads.

**Solution**: `-p` / `--planmode` flag that batches related beads:

1. Query beads for 5-10 related tasks (by tags, dependencies, or semantic similarity)
2. Instruct Claude to enter plan mode for the batch
3. User reviews/approves plan (or auto-approve with `-a -p`)
4. Execute plan, then run normal post-task cycle (simplification, commit, save output)

**Flags**:
- `-p` / `--planmode`: Enable plan mode batching
- Combined with `-a`: Auto-approve the generated plan

```bash
hot_ralph -p              # Plan mode, prompt for approval
hot_ralph -p -a           # Plan mode, auto-approve plan
hot_ralph -a              # Normal auto mode, single tasks
```

**Workflow**:
```
[14:00:00] Plan mode enabled. Finding related beads...
[14:00:02] Found 7 related beads:
  - abc123: Implement parser base
  - def456: Add tokenizer
  - ghi789: Create AST nodes
  - ... (4 more)

[14:00:03] Entering Claude plan mode...
[14:01:30] Plan generated. Review: .hot_ralph/20250130_140130_plan.md

Approve plan? [Y/n/view]
> y

[14:01:35] Executing plan...
[14:15:00] Plan complete. Running simplification pass...
[14:16:00] Committing changes...
```

**Plan prompt**:
```
You have the following related beads to implement:

## Beads
{list of 5-10 beads with titles, descriptions, dependencies}

## Context Files
@SPEC.md @VISION.md @TESTING.md

Enter plan mode and create an implementation plan that:
1. Identifies the optimal order considering dependencies
2. Groups changes that should be made together
3. Notes any conflicts or decisions needed
4. Estimates which files will be modified

After plan approval, implement all beads in order.
```

**Bead selection strategy**:
- Primary: Beads with shared tags
- Secondary: Beads in same dependency chain
- Fallback: Oldest ready beads by priority

**State tracking**: `.hot_ralph/state.json` includes `plan_mode` boolean and `planned_beads` array when active.

### Subscription Limit and Error Handling - DONE

**Problem**: When Claude subscription limits are hit or unknown errors occur, hot_ralph continues cycling and generates noise instead of exiting cleanly.

**Solution**: Detect fatal errors and exit gracefully with actionable messages.

**Error Categories**:

| Category | Detection | Action |
|----------|-----------|--------|
| Subscription limit | `rate_limit`, `quota_exceeded` in response | Exit with code 5, show renewal info |
| Auth expired | `authentication_error`, 401 status | Exit with code 6, prompt re-auth |
| Unknown Claude error | Unrecognized error structure | Log full response, exit with code 7 |
| Network failure | Connection refused, timeout | Retry 3x with backoff, then exit code 8 |
| Malformed response | JSON parse failure on stream | Log partial response, exit code 9 |

**Exit codes** (extending existing):
| Code | Meaning |
|------|---------|
| 5 | Subscription/rate limit reached |
| 6 | Authentication error |
| 7 | Unknown Claude error |
| 8 | Network failure (after retries) |
| 9 | Malformed response |

**Behavior**:
```
[14:32:15] Executing task abc123...
[14:32:16] ERROR: Subscription limit reached

Your Claude subscription has hit its usage limit.
- Check usage: https://console.anthropic.com/usage
- Limits reset: [timestamp if available]

Syncing beads before exit...
[14:32:17] Beads synced. Exiting with code 5.
```

**Implementation**:
```zig
const ClaudeError = union(enum) {
    subscription_limit: struct { reset_at: ?i64 },
    auth_error: []const u8,
    rate_limit: struct { retry_after: u32 },
    network: std.net.ConnectError,
    unknown: struct { raw_response: []const u8 },
    malformed: struct { partial: []const u8 },
};

fn handleClaudeError(err: ClaudeError) noreturn {
    // Sync beads before exit
    beads.syncOrLog();

    switch (err) {
        .subscription_limit => |info| {
            log.err("Subscription limit reached");
            if (info.reset_at) |ts| {
                log.info("Resets at: {}", .{formatTimestamp(ts)});
            }
            std.process.exit(5);
        },
        // ... other cases
    }
}
```

**Retry logic** (network only):
```
Attempt 1: immediate
Attempt 2: wait 2s
Attempt 3: wait 5s
After 3 failures: exit with code 8
```

**Graceful shutdown on any fatal error**:
1. Log error with full context to `.hot_ralph/{timestamp}_error.md`
2. Sync beads (`br sync`)
3. If task was in progress, leave it as `in_progress` (not closed)
4. Exit with appropriate code

---

## Phase 1.9: Context Optimization Research

Before Phase 2 (TUI), research and prototype context-saving strategies to reduce token usage per loop.

### Problem

Each hot_ralph loop sends full context to Claude:
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
- How does `--resume` interact with hot_ralph's workflow?
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

## Phase 2: TUI and Loop Refinement

Inspiration: [Chief](https://github.com/minicodemonkey/chief) - a Go tool that orchestrates Claude Code with a Bubble Tea TUI and clean iterative loop. Chief calls this the "Ralph Wiggum loop" -- each iteration gets a fresh context window while progress persists between runs. We should study Chief's approach and take what works while building on our Zig/rich_zig foundation.

### Loop Architecture Cleanup

**Problem**: The current main loop mixes orchestration, I/O, and state transitions. As we add TUI, this coupling will fight us.

**Inspiration from Chief**: Chief cleanly separates the iteration loop from presentation. Each iteration is atomic -- fresh Claude context, single task, atomic commit. Progress is tracked externally so any single iteration can fail without corrupting state.

**Goals**:
- Extract the core loop into a clean state machine: `idle -> claim -> execute -> simplify -> commit -> idle`
- Each state transition is explicit and testable
- Loop body is presentation-agnostic (CLI and TUI are just different renderers)
- Failed iterations leave state recoverable (already partially done via checkpoint/resume)

### TUI Dashboard (rich_zig)

**Problem**: CLI output scrolls away. No at-a-glance view of session progress.

**Inspiration from Chief**: Chief's Bubble Tea TUI shows task list, execution status, and lets the user press `s` to start. Interactive but minimal.

**Solution**: Full-screen TUI using rich_zig with panels:

```
+-------------------------------------------+
| hot_ralph v0.5.0    [3/12 tasks]   14:32  |
+-------------------+-----------------------+
| TASKS             | OUTPUT                |
|                   |                       |
| [x] abc123 parse  | Running claude...     |
| [x] def456 token  | > Implementing the    |
| [>] ghi789 AST    |   parser module with  |
| [ ] jkl012 eval   |   proper error...     |
| [ ] mno345 repl   |                       |
|                   |                       |
+-------------------+-----------------------+
| STATUS: executing ghi789 | git: clean     |
+-------------------------------------------+
```

**Panels**:
- **Task list**: Ready/in-progress/done with scroll, current task highlighted
- **Output stream**: Live Claude output (replaces terminal scroll)
- **Status bar**: Current phase, git status, task counts, elapsed time

**Keyboard**:
- `s` - Start/resume execution
- `p` - Pause after current task
- `e` - Exit after current task (mirrors existing)
- `j/k` - Scroll task list
- `v` - Toggle verbose output
- `q` - Quit (with confirmation if task in progress)
- `tab` - Cycle focus between panels

### Live Task Tree

**Problem**: Flat task list hides dependency relationships.

**Solution**: Tree view showing blocked/unblocked chains:

```
TASKS
  [x] abc123 Implement parser base
    [>] ghi789 Create AST nodes       <- unblocked by abc123
      [ ] jkl012 Add evaluator        <- blocked by ghi789
  [x] def456 Add tokenizer
  [ ] mno345 Build REPL               <- blocked by jkl012, def456
```

Collapse/expand subtrees. Color-code by status.

### Streaming Output Panel

**Problem**: Claude output floods the terminal. Hard to read while it streams.

**Solution**: Dedicated scrollable panel for Claude's streaming response:
- Auto-scroll during execution, manual scroll when paused
- Syntax highlighting for code blocks
- Wrap long lines, respect terminal width
- Keep last N tasks' output in a ring buffer for review

### Git Status Indicators

**Solution**: Persistent status in the TUI footer:
- Branch name, dirty/clean indicator
- Last push time, push status (pending/success/failed)
- Uncommitted file count

### Session Metrics

**Solution**: Running counters in the TUI header:
- Tasks completed / total ready
- Session duration
- Token usage (parsed from Claude stream-json cost fields)
- Average time per task

---

## Deferred to Phase 3+

These features are complex and not needed for initial CLI:

- Task dependency DAG modeling
- Embedded SQLite metrics database
- Semantic search over past tasks
- Multiple AI backend support
