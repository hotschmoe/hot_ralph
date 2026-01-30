# Ralph.sh Design Sketches

Two approaches for maintaining coherence in automated Claude workflows.

---

## Option A: Session Persistence with `--resume`

**Concept**: Keep Claude's context alive between PLAN and EXECUTE phases using session IDs.

### How It Works

```
                    +------------------+
                    |  Start Session   |
                    |  (get session_id)|
                    +--------+---------+
                             |
                             v
+------------------>+--------+---------+
|                   |   PLAN PHASE     |
|                   | --resume $SID    |
|                   +--------+---------+
|                            |
|                            v
|                   +--------+---------+
|                   |  USER APPROVAL   |
|                   |  [Y/n/q]         |
|                   +--------+---------+
|                            |
|         +------------------+------------------+
|         |                  |                  |
|         v                  v                  v
|    [rejected]         [approved]          [quit]
|         |                  |                  |
|         |                  v                  v
+---------+         +--------+---------+     EXIT
                    |  EXECUTE PHASE   |
                    | --resume $SID    |
                    | (remembers plan!)|
                    +--------+---------+
                             |
                             v
                    +--------+---------+
                    |  CHECK COMPLETE  |
                    +--------+---------+
                             |
              +--------------+--------------+
              |                             |
              v                             v
         [incomplete]                  [complete]
              |                             |
              v                             v
    +------------------+             FINAL REVIEW
    | CLEAR CONTEXT    |                  |
    | (new session_id) |                  v
    +--------+---------+               EXIT
              |
              +-----------> back to PLAN
```

### Sketch Implementation

```bash
#!/bin/bash
set -e

PROJECT_DIR="${1:-.}"
MAX_ITERATIONS="${2:-100}"

# Session management
SESSION_FILE="$PROJECT_DIR/.ralph-session"
start_new_session() {
    # First call establishes session, capture the ID
    local response=$(claude --output-format json --print "Session initialized for $PROJECT_DIR" 2>/dev/null)
    echo "$response" | jq -r '.session_id // empty' > "$SESSION_FILE"
}

run_claude_resumable() {
    local prompt="$1"
    local session_id=$(cat "$SESSION_FILE" 2>/dev/null || echo "")

    if [[ -n "$session_id" ]]; then
        claude --resume "$session_id" --print --output-format stream-json "$prompt" \
            | tee >(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty') \
            | jq -r 'select(.type == "result") | .session_id // empty' > "$SESSION_FILE.new"

        # Update session ID if we got a new one
        [[ -s "$SESSION_FILE.new" ]] && mv "$SESSION_FILE.new" "$SESSION_FILE"
    else
        start_new_session
        run_claude_resumable "$prompt"  # retry with new session
    fi
}

clear_context() {
    rm -f "$SESSION_FILE"
    start_new_session
}

# Main loop
cd "$PROJECT_DIR"
start_new_session

for ((i=1; i<=MAX_ITERATIONS; i++)); do
    echo "=== ITERATION $i ==="

    # PLAN - Claude remembers this
    run_claude_resumable "Read @SPEC.md @testing.md @VISION.md.
        Identify the next 3-5 uncompleted features.
        Create a detailed implementation plan.
        Wait for approval before executing."

    read -p "Accept plan? [Y/n/q] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Qq]$ ]] && exit 0
    [[ $REPLY =~ ^[Nn]$ ]] && { clear_context; continue; }

    # EXECUTE - Claude remembers the plan!
    run_claude_resumable "Execute the plan you just created.
        Implement, test, commit each feature.
        Mark completed items in SPEC.md as [x]."

    # CHECK
    if ! grep -q '\[ \]' "$PROJECT_DIR/SPEC.md"; then
        echo "SPEC COMPLETE!"
        exit 0
    fi

    # Fresh context for next iteration (optional - could keep going)
    clear_context
done
```

### Pros

- Natural conversation flow - "execute the plan you just created" actually works
- Claude can reference its own reasoning from planning phase
- Corrections/clarifications carry forward
- Closer to how a human would work with Claude

### Cons

- Session IDs might expire or have limits
- Context window still fills up over long sessions
- Need to handle session recovery if interrupted
- `--resume` behavior needs verification (is it stable in CLI?)

### Open Questions

1. Does `--resume` work with `--print` mode?
2. What's the session timeout/context limit?
3. Can we query session state to check if it's still valid?

---

## Option B: Pre-Generated Task Manifest

**Concept**: Front-load ALL planning into a structured `tasks.md`, then loop through atomic tasks without needing cross-phase memory.

### How It Works

```
+--------------------------------------------------+
|              BOOTSTRAP PHASE (once)              |
+--------------------------------------------------+
                         |
                         v
+------------------------+-------------------------+
|  Claude reads SPEC.md, VISION.md                 |
|  Generates exhaustive tasks.md with:             |
|    - Sprints (demoable milestones)               |
|    - Tasks (atomic, testable units)              |
|    - Validation criteria per task                |
+------------------------+-------------------------+
                         |
                         v
+------------------------+-------------------------+
|  Subagent reviews tasks.md                       |
|  Suggests improvements                           |
|  Final tasks.md written                          |
+------------------------+-------------------------+
                         |
                         v
+--------------------------------------------------+
|              EXECUTION LOOP (many)               |
+--------------------------------------------------+
                         |
                         v
              +----------+-----------+
              |  Parse tasks.md      |
              |  Find next pending   |
              |  task: [ ]           |
              +----------+-----------+
                         |
                         v
              +----------+-----------+
              |  Claude executes     |
              |  SINGLE atomic task  |
              |  (self-contained)    |
              +----------+-----------+
                         |
                         v
              +----------+-----------+
              |  Validate:           |
              |  - Tests pass?       |
              |  - Builds?           |
              |  - Criteria met?     |
              +----------+-----------+
                         |
              +----------+-----------+
              |                      |
              v                      v
         [failed]              [success]
              |                      |
              v                      v
         LOG ERROR           Mark task [x]
         CONTINUE            Commit
              |                      |
              +----------+-----------+
                         |
                         v
              +----------+-----------+
              |  Sprint complete?    |
              +----------+-----------+
                         |
              +----------+-----------+
              |                      |
              v                      v
           [no]                   [yes]
              |                      |
              |                      v
              |              RUN DEMO/SMOKE
              |              TESTS FOR SPRINT
              |                      |
              +----------+-----------+
                         |
                         v
                    NEXT TASK
```

### tasks.md Format

```markdown
# Project Tasks

Generated from: SPEC.md, VISION.md
Generated at: 2024-01-29T10:00:00Z

## Sprint 1: Core Foundation

**Goal**: Basic project skeleton that builds and runs hello world.
**Demo**: `zig build run` prints "Hello from project"

### Tasks

- [ ] **T1.1**: Initialize zig project structure
  - Create build.zig with basic executable target
  - Create src/main.zig with minimal entry point
  - **Validation**: `zig build` succeeds with exit code 0

- [ ] **T1.2**: Add basic test infrastructure
  - Create src/tests/root.zig
  - Wire test step in build.zig
  - **Validation**: `zig build test` runs and passes

- [ ] **T1.3**: Implement hello world output
  - Add print statement to main
  - **Validation**: `zig build run` outputs "Hello from project"

---

## Sprint 2: First Feature

**Goal**: [description]
**Demo**: [how to verify sprint is complete]

### Tasks

- [ ] **T2.1**: [task title]
  - [implementation details]
  - **Validation**: [specific test or check]

...
```

### Bootstrap Prompt

```markdown
Read @SPEC.md and @VISION.md carefully.

Break this project into sprints and tasks following these rules:

**Sprints**:
- Each sprint produces a demoable, runnable piece of software
- Sprints build on each other incrementally
- Sprint goal should be achievable in ~5-10 atomic tasks
- Include a concrete demo/validation for the sprint

**Tasks**:
- Every task is atomic - one commit, one focused change
- Every task has explicit validation criteria (test command, expected output, etc.)
- Tasks within a sprint can be done in order listed
- No task depends on uncommitted work from another task
- Include file paths and function names where relevant

**Format**:
Use the exact markdown format shown, with checkboxes [ ] for tracking.

Be exhaustive. Be technical. Small atomic tasks that compose into sprint goals.

After generating, I will have a subagent review for:
- Missing edge cases
- Tasks that are too large (should be split)
- Unclear validation criteria
- Dependency issues between tasks

Write the final result to tasks.md.
```

### Sketch Implementation

```bash
#!/bin/bash
set -e

PROJECT_DIR="${1:-.}"
TASKS_FILE="$PROJECT_DIR/tasks.md"

# ============================================================
# BOOTSTRAP: Generate tasks.md if it doesn't exist
# ============================================================
bootstrap_tasks() {
    if [[ -f "$TASKS_FILE" ]]; then
        echo "tasks.md exists, skipping bootstrap"
        return
    fi

    echo "=== BOOTSTRAP: Generating task manifest ==="

    # Phase 1: Initial generation
    claude --print "
        Read @SPEC.md @VISION.md @testing.md

        Break this into sprints and atomic tasks.
        [full prompt from above]

        Output ONLY the markdown content for tasks.md.
    " > "$TASKS_FILE.draft"

    # Phase 2: Subagent review
    claude --print "
        Review @tasks.md.draft for:
        - Tasks that should be split (too large)
        - Missing validation criteria
        - Unclear descriptions
        - Dependency problems

        Output a revised tasks.md with improvements.
    " > "$TASKS_FILE"

    rm "$TASKS_FILE.draft"
    echo "=== tasks.md generated ==="
}

# ============================================================
# EXECUTION: Work through tasks
# ============================================================
get_next_task() {
    # Extract first unchecked task
    grep -n '^\- \[ \]' "$TASKS_FILE" | head -1 | cut -d: -f1
}

get_task_content() {
    local line_num=$1
    # Extract task block (from checkbox to next checkbox or section)
    sed -n "${line_num},/^- \[/p" "$TASKS_FILE" | head -n -1
}

mark_task_complete() {
    local line_num=$1
    sed -i "${line_num}s/\[ \]/[x]/" "$TASKS_FILE"
}

get_current_sprint() {
    # Find which sprint the current task is in
    local task_line=$1
    head -n "$task_line" "$TASKS_FILE" | grep -n '^## Sprint' | tail -1 | cut -d: -f2
}

# ============================================================
# MAIN
# ============================================================
cd "$PROJECT_DIR"
bootstrap_tasks

while true; do
    task_line=$(get_next_task)

    if [[ -z "$task_line" ]]; then
        echo "=== ALL TASKS COMPLETE ==="
        exit 0
    fi

    task_content=$(get_task_content "$task_line")
    current_sprint=$(get_current_sprint "$task_line")

    echo ""
    echo "============================================"
    echo "SPRINT: $current_sprint"
    echo "TASK LINE: $task_line"
    echo "--------------------------------------------"
    echo "$task_content"
    echo "============================================"

    read -p "Execute this task? [Y/n/s(kip)/q] " -n 1 -r
    echo

    [[ $REPLY =~ ^[Qq]$ ]] && exit 0
    [[ $REPLY =~ ^[Ss]$ ]] && { mark_task_complete "$task_line"; continue; }
    [[ $REPLY =~ ^[Nn]$ ]] && continue

    # Execute the task
    claude --print --dangerously-skip-permissions "
        You are working on a project. Here is the current task:

        $task_content

        Context files: @SPEC.md @VISION.md @testing.md

        Execute this task completely:
        1. Implement the required changes
        2. Run the validation criteria
        3. If validation passes, commit with a descriptive message
        4. Report success or failure

        This is an ATOMIC task. Do not do more or less than specified.
    "

    read -p "Task successful? Mark complete? [Y/n] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        mark_task_complete "$task_line"
        git add "$TASKS_FILE"
        git commit --amend --no-edit  # Include tasks.md update in task commit
    fi
done
```

### Pros

- No session management complexity
- Each Claude invocation is self-contained
- tasks.md is human-readable progress tracker
- Can be paused/resumed trivially (just re-run script)
- Subagent review catches planning issues early
- Progress survives crashes, context limits, interruptions
- Can manually edit tasks.md to adjust plan

### Cons

- Upfront planning might miss things discovered during implementation
- Rigid structure - hard to pivot mid-sprint
- Task descriptions must be very precise (no "you know what I mean")
- Bootstrap phase could be slow/expensive
- May need periodic re-planning if tasks.md gets stale

### Hybrid: Re-Planning Checkpoints

Add periodic re-evaluation:

```bash
# After each sprint completion
if sprint_complete; then
    claude --print "
        Review @tasks.md and current codebase.

        Sprint '$current_sprint' is complete.

        Should remaining sprints/tasks be adjusted based on what we learned?
        If yes, output revised remaining sprints.
        If no, output 'NO_CHANGES'.
    " | handle_replan
fi
```

---

## Comparison

| Aspect | Option A (Resume) | Option B (Task Manifest) |
|--------|-------------------|--------------------------|
| **Context** | Natural conversation | Must be explicit in task |
| **Flexibility** | Can adapt on the fly | Rigid, pre-planned |
| **Robustness** | Session can expire | Survives anything |
| **Debugging** | Harder to inspect | tasks.md is transparent |
| **Human oversight** | Plan review per iteration | Task review per task |
| **Upfront cost** | None | Bootstrap phase |
| **Discovery** | Claude finds issues | Must re-plan to adapt |

## Recommendation

**Start with Option B** for these reasons:

1. **Debuggability**: tasks.md is a concrete artifact you can inspect, edit, version
2. **Robustness**: No session state to lose
3. **Atomic commits**: Natural fit for "one task, one commit" discipline
4. **Human control**: You can edit tasks.md to skip, reorder, or modify tasks
5. **Resumability**: Stop anytime, pick up where you left off

**Add Option A patterns later** if you find that:
- Tasks frequently need context from previous tasks
- The rigid structure is too limiting
- You want more conversational flow within a sprint

---

---

## Option C: Beads Integration (ralph_c.sh)

**Concept**: Same as Option B, but use beads (`br`) as the task tracker instead of tasks.md.

### Why Beads Over tasks.md

| Aspect | tasks.md | Beads |
|--------|----------|-------|
| **Query** | grep/awk parsing | `br ready --json` |
| **Priority** | Manual ordering | Native priority field |
| **Status** | Checkbox `[ ]`/`[x]` | open/in_progress/closed |
| **Filtering** | DIY | `br ready`, `br blocked` |
| **Dependencies** | Implicit ordering | Explicit `--deps` links |
| **Git integration** | Manual commits | `.beads/` auto-syncs |
| **Multiple workers** | Conflicts likely | Handles concurrent access |

### Workflow

```
+------------------+
|   br ready       |  <-- Entry point for loop
+--------+---------+
         |
         v
+--------+---------+
| Get next task    |
| (highest prio)   |
+--------+---------+
         |
         v
+--------+---------+
| br update        |
| --status         |
| in_progress      |
+--------+---------+
         |
         v
+--------+---------+
| Claude executes  |
| atomic task      |
+--------+---------+
         |
    +----+----+
    |         |
    v         v
[success]  [failed]
    |         |
    v         v
br close   br update
    |      (stays in_progress
    v       for retry)
br sync
    |
    v
git push
```

### Bootstrap Creates Beads

Instead of writing tasks.md, bootstrap generates JSON and creates beads:

```bash
# Claude outputs structured JSON
{
  "sprints": [
    {
      "number": 1,
      "name": "Foundation",
      "tasks": [
        {"id": "T1.1", "title": "...", "description": "...", "priority": 2}
      ]
    }
  ]
}

# Script creates beads from JSON
br create "[T1.1] Initialize project" --type task --priority 2 --description "..."
br create "[T1.2] Add tests" --type task --priority 2 --description "..."
```

### Key Commands in ralph_c

```bash
# Get next ready task as JSON
br ready --json | jq -s '.[0]'

# Claim task
br update bd-abc123 --status in_progress

# Complete task
br close bd-abc123 --reason "Implemented and tested"

# Sync to git
br sync
git add .beads/ && git commit -m "beads: sync"
```

---

## Implementation Summary

Three scripts created:

| Script | Approach | Entry Point | State Storage |
|--------|----------|-------------|---------------|
| `ralph_a.sh` | Session persistence | Loop with `--resume` | `.ralph-session` |
| `ralph_b.sh` | Task manifest | Parse `tasks.md` | `tasks.md` checkboxes |
| `ralph_c.sh` | Beads integration | `br ready` | `.beads/` directory |

---

## Current Implementation: hot_ralph (ralph_beads.sh)

**Status**: Production-ready, actively used.

### Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Hotschmoe/hotschmoe-setup/master/real/ralph_beads.sh -o ~/.local/bin/hot_ralph && chmod +x ~/.local/bin/hot_ralph
```

### Usage

```bash
# Interactive mode (default)
hot_ralph

# Auto mode - runs through all tasks without prompts
hot_ralph --auto
hot_ralph -a

# With project directory
hot_ralph /path/to/project --auto
```

### Features

| Feature | Description |
|---------|-------------|
| **Beads Integration** | Uses `br` CLI for task tracking with priority, status, dependencies |
| **Auto Mode** | `--auto` flag bypasses prompts for continuous execution |
| **Output Logging** | Saves all Claude output to `.hot_ralph/{timestamp}_{label}.md` |
| **Code Simplifier** | Runs simplification pass after each successful task |
| **Countdown Window** | 5-second Ctrl+C window between tasks for graceful exit |
| **Graceful Exit** | Ctrl+C syncs beads before exiting |

### Required Project Files

```
project/
  SPEC.md       # Project specification
  VISION.md     # Project vision
  TESTING.md    # Testing requirements
  .beads/       # Beads task database (br init)
```

### Task Lifecycle

```
br ready --json
      |
      v
+-----+------+
| 5s countdown |<-- Ctrl+C exits gracefully here
+-----+------+
      |
      v
+-----+------+
| Show task  |
| [Y/n/s/v/q]|
+-----+------+
      |
      v
+-----+------+
| Claim task |
| (in_progress)|
+-----+------+
      |
      v
+-----+------+
| Claude     |
| executes   |
+-----+------+
      |
      v
+-----+------+
| Success?   |
| [Y/n/r]    |
+-----+------+
      |
  +---+---+
  |       |
  v       v
[Y]     [n/r]
  |       |
  v       |
+-----+   |
|Simplify|  |
|code    |  |
+-----+   |
  |       |
  v       |
+-----+   |
|Complete|  |
|task    |  |
+-----+   |
  |       |
  +---+---+
      |
      v
  Next task
```

### Output Structure

```
.hot_ralph/
  20260129_010530_task_bd_2f8_.md      # Task execution output
  20260129_010545_simplify_bd_2f8_.md  # Simplification output
  20260129_012000_final_review.md      # Final review when all done
```

### Key Functions

| Function | Purpose |
|----------|---------|
| `run_claude` | Execute Claude with streaming JSON, save output |
| `prompt_user` | Interactive prompt (bypassed in auto mode) |
| `countdown_window` | 5-second interruptible pause between tasks |
| `graceful_exit` | Sync beads and exit on Ctrl+C |
| `beads_*` | Beads CLI wrappers (ready_count, get_next, claim, complete, sync) |
| `commit_beads` | Sync and commit .beads/ changes |
| `commit_all` | Stage and commit all changes |

---

## Design History

### Option A: Session Persistence (not implemented)
- Used `--resume` for cross-phase context
- Rejected: session management complexity, potential expiration issues

### Option B: Task Manifest (not implemented)
- Used `tasks.md` with checkboxes
- Rejected: grep/awk parsing fragile, no priority/dependency support

### Option C: Beads Integration (implemented as hot_ralph)
- Uses beads (`br`) for structured task tracking
- Chosen: robust querying, native priorities, git-friendly `.beads/` directory

---

## Future Considerations

1. **Parallel execution**: Run multiple Claude instances for independent tasks
2. **Re-planning checkpoints**: Periodic task list review after sprint completion
3. **Error recovery**: Better handling of Claude failures mid-task
4. **Session persistence hybrid**: Add `--resume` for multi-turn tasks if needed
