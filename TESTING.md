# ralph Testing Strategy

## Philosophy

Tests are diagnostic tools, not success criteria. They help us detect regressions and verify sanity, but a passing test suite does not mean the code is correct.

When a test fails, ask:
1. Is the test itself correct and valuable?
2. Does the test align with current design?
3. Is the code actually broken?

Only fix the code if all three answers are "yes".

## Test Categories

### Unit Tests

Test individual modules in isolation:
- `beads.zig` - JSON parsing, command building
- `prompt.zig` - Template rendering
- `state.zig` - Serialization/deserialization
- `config.zig` - Path resolution, requirement detection

Run with:
```bash
zig build test
zig build test -Doptimize=ReleaseSafe  # Also test optimized builds
```

### Integration Tests

Test interactions between components using a mock project environment.

Location: `test/fixtures/mock_project/`

```
test/
├── fixtures/
│   └── mock_project/           # Fake project for testing
│       ├── .beads/
│       │   └── issues.jsonl    # Pre-populated test tasks
│       ├── SPEC.md
│       ├── VISION.md
│       ├── TESTING.md
│       └── src/
│           └── main.zig        # Minimal code to modify
├── integration/
│   ├── beads_test.zig          # br CLI interactions
│   ├── config_test.zig         # Requirement validation
│   └── state_test.zig          # Checkpoint/resume
└── mock/
    ├── mock_claude.zig         # Fake Claude responses
    └── mock_beads.zig          # Fake br output
```

### End-to-End Tests

Full workflow tests against the mock project:
1. Initialize state
2. Fetch task from mock Beads
3. Generate prompt
4. Run mock Claude
5. Verify state transitions

These tests do NOT:
- Call real Claude (would require auth, costs money)
- Modify the actual hot_ralph repository
- Make real git commits outside the mock project

### What We Mock

| Component | Mocking Strategy |
|-----------|-----------------|
| Claude CLI | Mock subprocess that returns canned responses |
| Beads CLI | Mock subprocess with fixture data |
| Git | Real git in isolated temp directory |
| Filesystem | Real filesystem in test fixtures |

### What We Don't Mock

- JSON parsing (test real parser)
- State serialization (test real format)
- Prompt generation (test real templates)

## Test Fixtures

### Mock Project Structure

`test/fixtures/mock_project/` contains a minimal but valid project:

```
mock_project/
├── .beads/
│   ├── beads.db          # SQLite (if needed)
│   └── issues.jsonl      # Git-friendly export
├── .git/                 # Real git repo
├── .hot_ralph/           # Output directory
├── SPEC.md               # "Mock project specification"
├── VISION.md             # "Mock project vision"
├── TESTING.md            # "Mock project testing"
└── src/
    └── main.zig          # Minimal file for modification tests
```

### Test Tasks (issues.jsonl)

```jsonl
{"id":"test-001","title":"Add greeting function","description":"Add a greet() function that returns 'Hello'","priority":1,"status":"open","type":"task","tags":["test"]}
{"id":"test-002","title":"Add farewell function","description":"Add a farewell() function that returns 'Goodbye'","priority":2,"status":"open","type":"task","tags":["test"]}
{"id":"test-003","title":"Blocked task","description":"This task depends on test-001","priority":1,"status":"open","type":"task","blocked_by":["test-001"]}
```

### Mock Claude Responses

`test/mock/responses/` contains canned Claude outputs:

```
responses/
├── success_simple.json     # Task completed, no changes
├── success_with_commit.json # Task completed with git commit
├── failure_test_error.json  # Task failed, tests don't pass
└── interrupted.json         # Partial response (simulates Ctrl+C)
```

## Running Tests

```bash
# All tests
zig build test

# With optimization (catches different bugs)
zig build test -Doptimize=ReleaseSafe

# Specific test file
zig build test --test-filter "beads"

# Verbose output
zig build test -- --verbose
```

## Test Isolation

Tests must:
1. Create all needed state in fixtures or temp directories
2. Clean up after themselves (or use defer)
3. Not depend on external tools being installed
4. Not require network access
5. Not modify files outside test directories

```zig
test "state serialization" {
    const allocator = std.testing.allocator;

    // Use temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const state = State{ .current_task_id = "test-001", ... };
    try state.save(tmp.dir, "state.json");

    const loaded = try State.load(tmp.dir, "state.json", allocator);
    try std.testing.expectEqualStrings("test-001", loaded.current_task_id);
}
```

## Coverage Goals

Focus testing effort on:

1. **Error paths** - Every `catch` and error return
2. **State transitions** - idle -> executing -> simplifying -> idle
3. **Edge cases** - Empty queue, malformed JSON, missing files
4. **Crash recovery** - State load after simulated interruption

Do not aim for line coverage metrics. Test what matters.

## CI Integration

GitHub Actions runs:
1. `zig build test` on Linux, macOS, Windows
2. Multiple optimization levels (Debug, ReleaseSafe, ReleaseFast)
3. Format check (`zig fmt --check src/`)

Tests must pass on all platforms before merge.

## Adding New Tests

When adding functionality:
1. Add unit tests for the new module
2. Add integration test if it interacts with external tools
3. Update mock fixtures if new task types are needed
4. Do NOT add tests just to increase coverage numbers

When fixing bugs:
1. Add a test that reproduces the bug (if practical)
2. Fix the bug
3. Verify test passes
4. Consider if the test is valuable long-term (delete if not)
