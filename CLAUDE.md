<!-- BEGIN:header -->
# CLAUDE.md

we love you, Claude! do your best today
<!-- END:header -->

<!-- BEGIN:rule-1-no-delete -->
## RULE 1 - NO DELETIONS (ARCHIVE INSTEAD)

You may NOT delete any file or directory. Instead, move deprecated files to `.archive/`.

**When you identify files that should be removed:**
1. Create `.archive/` directory if it doesn't exist
2. Move the file: `mv path/to/file .archive/`
3. Notify me: "Moved `path/to/file` to `.archive/` - deprecated because [reason]"

**Rules:**
- This applies to ALL files, including ones you just created (tests, tmp files, scripts, etc.)
- You do not get to decide that something is "safe" to delete
- The `.archive/` directory is gitignored - I will review and permanently delete when ready
- If `.archive/` doesn't exist and you can't create it, ask me before proceeding

**Only I can run actual delete commands** (`rm`, `git clean`, etc.) after reviewing `.archive/`.
<!-- END:rule-1-no-delete -->

<!-- BEGIN:irreversible-actions -->
### IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.
<!-- END:irreversible-actions -->

<!-- BEGIN:code-discipline -->
### Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.
- **NO EMOJIS** - do not use emojis or non-textual characters.
- ASCII diagrams are encouraged for visualizing flows.
- Keep in-line comments to a minimum. Use external documentation for complex logic.
- In-line commentary should be value-add, concise, and focused on info not easily gleaned from the code.
<!-- END:code-discipline -->

<!-- BEGIN:no-legacy -->
### No Legacy Code - Full Migrations Only

We optimize for clean architecture, not backwards compatibility. **When we refactor, we fully migrate.**

- No "compat shims", "v2" file clones, or deprecation wrappers
- When changing behavior, migrate ALL callers and remove old code **in the same commit**
- No `_legacy` suffixes, no `_old` prefixes, no "will remove later" comments
- New files are only for genuinely new domains that don't fit existing modules
- The bar for adding files is very high

**Rationale**: Legacy compatibility code creates technical debt that compounds. A clean break is always better than a gradual migration that never completes.
<!-- END:no-legacy -->

<!-- BEGIN:dev-philosophy -->
## Development Philosophy

**Make it work, make it right, make it fast** - in that order.

**This codebase will outlive you** - every shortcut becomes someone else's burden. Patterns you establish will be copied. Corners you cut will be cut again.

**Fight entropy** - leave the codebase better than you found it.

**Inspiration vs. Recreation** - take the opportunity to explore unconventional or new ways to accomplish tasks. Do not be afraid to challenge assumptions or propose new ideas. BUT we also do not want to reinvent the wheel for the sake of it. If there is a well-established pattern or library take inspiration from it and make it your own. (or suggest it for inclusion in the codebase)
<!-- END:dev-philosophy -->

<!-- BEGIN:testing-philosophy -->
## Testing Philosophy: Diagnostics, Not Verdicts

**Tests are diagnostic tools, not success criteria.** A passing test suite does not mean the code is good. A failing test does not mean the code is wrong.

**When a test fails, ask three questions in order:**
1. Is the test itself correct and valuable?
2. Does the test align with our current design vision?
3. Is the code actually broken?

Only if all three answers are "yes" should you fix the code.

**Why this matters:**
- Tests encode assumptions. Assumptions can be wrong or outdated.
- Changing code to pass a bad test makes the codebase worse, not better.
- Evolving projects explore new territory - legacy testing assumptions don't always apply.

**What tests ARE good for:**
- **Regression detection**: Did a refactor break dependent modules? Did API changes break integrations?
- **Sanity checks**: Does initialization complete? Do core operations succeed? Does the happy path work?
- **Behavior documentation**: Tests show what the code currently does, not necessarily what it should do.

**What tests are NOT:**
- A definition of correctness
- A measure of code quality
- Something to "make pass" at all costs
- A specification to code against

**The real success metric**: Does the code further our project's vision and goals?
<!-- END:testing-philosophy -->

<!-- BEGIN:footer -->
---

we love you, Claude! do your best today
<!-- END:footer -->


---

## Project-Specific Content

<!-- Add your project's toolchain, architecture, workflows here -->
<!-- This section will not be touched by haj.sh -->

# hot_ralph - Atomic Task Execution with Claude and Beads

Automated task runner that pulls work from Beads, executes via Claude CLI, and commits results. Designed for autonomous, incremental project development.

- **Version**: 0.3.0
- **Minimum Zig**: 0.15.2
- **Dependencies**: rich_zig (terminal UI)

---

## Zig Toolchain

```bash
zig build                    # Build the executable
zig build run -- --help      # Show help (note: -- separates zig args from program args)
zig build run -- --dry-run   # Dry run in current directory
zig build test               # Run all tests
zig fmt src/                 # Format before commits
```

---

## Usage

```bash
hot_ralph [OPTIONS] [PROJECT_DIR]

# Examples:
zig build run -- --dry-run                      # Preview mode, current dir
zig build run -- --dry-run ~/beads_zig/         # Preview mode, specific project
zig build run -- -p --dry-run ~/beads_zig/      # Plan mode preview (5 tasks)
zig build run -- -p 7 --dry-run ~/beads_zig/    # Plan mode with 7 tasks
zig build run -- -a ~/beads_zig/                # Auto mode (no prompts)
zig build run -- -v ~/beads_zig/                # Verbose (stream Claude output)
```

### Options

| Flag | Long | Description |
|------|------|-------------|
| `-a` | `--auto` | Skip all prompts, assume yes |
| `-p [N]` | `--planmode [N]` | Batch N related tasks into single session (default: 5) |
| `-i` | `--introspection` | Enable periodic introspection (every 5 tasks) |
| `-s` | `--silent` | Don't stream Claude responses to terminal |
| `-q` | `--quiet` | Minimal output |
| | `--dry-run` | Preview what would be done without executing |
| `-h` | `--help` | Show help |
| `-V` | `--version` | Show version |

---

## Project Requirements

Target project must contain:

```
project/
  SPEC.md        # Project specification
  VISION.md      # Project vision
  TESTING.md     # Testing requirements
  .beads/        # Beads task tracking (br init)
  .git/          # Git repository
```

External commands (must be in PATH):
- `claude` - Anthropic Claude CLI
- `br` - Beads Rust CLI
- `git` - Version control

---

## Project Layout

```
hot_ralph/
  build.zig         # Build configuration
  build.zig.zon     # Package manifest (depends on rich_zig)
  src/
    main.zig        # Entry point, main loop, plan mode
    root.zig        # Library exports
    config.zig      # Args parsing, requirements check
    beads.zig       # Beads CLI wrapper
    claude.zig      # Claude CLI wrapper
    git.zig         # Git operations
    prompt.zig      # Prompt templates
    scanner.zig     # Project file scanner
    state.zig       # Persistent state (.hot_ralph/state.json)
    ui.zig          # Terminal UI (uses rich_zig)
    exit_monitor.zig # Graceful exit on 'e' key
```

---

## Execution Flow

```
1. Parse args, load config
2. Check requirements (files, commands)
3. Load or resume state
4. Main loop (or plan mode):
   a. Get next ready task from beads
   b. Display task, prompt for execution
   c. Claim task, run Claude with prompt
   d. On success: complete task, run simplification pass
   e. Git commit changes
   f. Periodic introspection (if enabled)
5. Final sync and review
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Missing requirements |
| 2 | Beads operation failed |
| 3 | Claude operation failed (unknown) |
| 4 | Git operation failed |
| 5 | Claude subscription/quota limit |
| 6 | Claude authentication error |
| 7 | Claude rate limit exceeded |
| 8 | Claude network failure |
| 9 | Claude malformed response |
| 130 | Interrupted (Ctrl+C) |

---

## State Management

hot_ralph creates `.hot_ralph/` in the target project:

```
.hot_ralph/
  state.json           # Current task, phase, counters
  task_<id>_<ts>.md    # Claude output logs
  simplify_<id>.md     # Simplification pass output
  introspection_<ts>.md # Introspection output
```

---

## Issue Tracking: beads_rust (br)

Local-first issue tracker stored in `.beads/`.

### Core Commands

```bash
br init                    # Initialize in current repo
br create "Title"          # Create issue
br list                    # Show all open issues
br ready                   # Show unblocked, actionable work
br show <id>               # Display issue details
br close <id>              # Mark complete
```

### Workflow

```bash
br create "Bug title" --type bug --priority 1
br update <id> --status in_progress
br dep add <child-id> <parent-id>   # child blocked by parent
br sync --flush-only                # Export for git commit
```

**Priority**: 0=critical, 1=high, 2=medium, 3=low, 4=backlog

