# hot_ralph

A Zig-native development loop tool for atomic task execution with Claude and Beads integration.

## What is hot_ralph?

hot_ralph automates the development workflow of:
1. Pulling the next ready task from your Beads queue
2. Sending it to Claude with project context
3. Validating the result
4. Committing and moving to the next task

It replaces a fragile bash script with proper error handling, native JSON parsing, and reliable subprocess management.

## Status

**Phase 1 (Current)**: CLI tool - direct port of hot_ralph bash functionality to Zig
**Phase 2 (Future)**: TUI - terminal interface with task visualization and live output

## Requirements

- Zig 0.15.2 or later
- [claude](https://claude.ai/download) CLI installed and authenticated
- [br](https://github.com/Dicklesworthstone/beads_rust) (Beads) for task tracking
- Git repository with `.beads/` initialized

## Installation

```bash
git clone https://github.com/yourusername/hot_ralph.git
cd hot_ralph
zig build -Doptimize=ReleaseSafe
```

The binary is at `zig-out/bin/hot_ralph`.

## Quick Start

```bash
# Initialize Beads in your project
cd /path/to/your/project
br init

# Create some tasks
br create "Implement feature X" --type task --description "..."
br create "Fix bug Y" --type bug --priority 1

# Run hot_ralph
hot_ralph /path/to/your/project

# Or with auto-mode (no prompts)
hot_ralph --auto /path/to/your/project
```

## Project Structure

Your project needs:
- `SPEC.md` - Technical specification
- `VISION.md` - Project vision and goals
- `TESTING.md` - Testing requirements
- `.beads/` - Beads task database

## Commands

```bash
hot_ralph [OPTIONS] [PROJECT_DIR]

Options:
  -a, --auto          Auto mode - no user prompts, assume yes
  -h, --help          Show help message
  -V, --version       Show version
  --dry-run           Preview mode - show what would be done
  -v, --verbose       Stream Claude responses to terminal
  -q, --quiet         Minimal output (errors only)
  -i, --introspection Enable periodic introspection every 5 tasks

Arguments:
  PROJECT_DIR   Path to project (default: current directory)
```

## Workflow

1. hot_ralph shows the next ready task from Beads
2. You confirm execution (or use --auto)
3. Claude receives the task with project context files
4. You confirm success, retry, or skip
5. On success, hot_ralph runs code simplification and commits
6. Loop continues until all tasks complete

## Development

```bash
zig build              # Build
zig build test         # Run tests
zig build run          # Run demo
zig fmt src/           # Format code
```

See [SPEC.md](SPEC.md) for technical details and [VISION.md](VISION.md) for project direction.

## License

MIT
