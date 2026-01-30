@README.md @SPEC.md @FEATURE_PARITY.md @VISION.md @TESTING.md

Break this project down into beads (focus on @FEATURE_PARITY.md as this project is a zig port of an existing project). Timeline info doesn't matter.

## Bead Definition

A **bead** is a single task or feature—an atomic, commitable piece of work with validation.

### Key Principles

- **One task/feature per bead** — Cohesive unit of work
- **Self-contained details** — Each bead runs with a fresh agent context; include everything needed to complete the work
- **Atomic & commitable** — Clean, reviewable commit

### What to Include

1. **Goal** — What this bead accomplishes
2. **Technical approach** — How to implement it, key decisions
3. **Validation** — How to verify completion (test commands, checks)
4. **Dependencies** — Beads that must complete first (if any)

> [!NOTE]
> The agent receives `SPEC.md`, `VISION.md`, and `TESTING.md` automatically —no need to repeat that context in individual beads.

Be exhaustive, be clear, be technical.

## Commands

Create beads using `br` (beads_rust) — one bead per atomic task.

## Review

Once done, have a subagent review your beads and suggest improvements.