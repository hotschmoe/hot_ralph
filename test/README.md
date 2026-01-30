# ralph Test Suite

## Structure

```
test/
├── fixtures/
│   └── mock_project/       # Isolated test project
│       ├── .beads/         # Pre-populated task data
│       ├── .hot_ralph/     # Output directory
│       ├── src/            # Code for modification tests
│       ├── SPEC.md
│       ├── VISION.md
│       └── TESTING.md
└── mock/
    └── responses/          # Canned Claude responses
        ├── success_simple.json
        ├── success_with_commit.json
        ├── failure_test_error.json
        └── interrupted.json
```

## Purpose

- **mock_project/**: A complete but minimal project that satisfies ralph's requirements. Tests run against this directory instead of the real repository.

- **mock/responses/**: Pre-recorded Claude responses for integration tests. Avoids calling real Claude API during tests.

## Usage

Unit tests use `std.testing.tmpDir()` for isolation.

Integration tests operate within `fixtures/mock_project/`.

No test should modify files outside the `test/` directory.
