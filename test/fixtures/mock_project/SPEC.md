# Mock Project Specification

This is a test fixture for ralph integration tests.

## Purpose

Provides a minimal but valid project structure for testing ralph without modifying real codebases.

## Structure

- `src/main.zig` - Minimal Zig file for modification tests
- `.beads/` - Pre-populated task database
- `.hot_ralph/` - Output directory for Claude responses

## Constraints

- Tests should create/modify files only within this directory
- Git operations should be isolated to this directory
- No network calls or external tool invocations in unit tests
