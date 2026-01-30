# Testing Strategy for rich_zig

This document defines the testing regime for rich_zig, ensuring **100% feature parity** with the Rich/rich_rust specification while maintaining Zig idioms.

## Goal: 100% Feature Parity

All features documented in [FEATURE_PARITY.md](FEATURE_PARITY.md) must have corresponding tests. A feature is not considered complete until:

1. Implementation matches Rich/rich_rust behavior
2. Unit tests cover all edge cases
3. Integration tests verify component interaction
4. Visual output matches expected snapshots

## Testing Philosophy

1. **Correctness First**: Every public API must have corresponding tests
2. **Property-Based Testing**: Use fuzz testing for parsers and text handling
3. **Visual Verification**: Snapshot tests for rendered output
4. **Cross-Platform**: Tests must pass on Linux, macOS, and Windows
5. **No Flaky Tests**: Deterministic output, no timing-dependent assertions
6. **Parity Verification**: Output should match rich_rust where possible

## Test Categories

### Unit Tests

Each module contains inline tests for its core functionality:

```zig
// src/color.zig
test "Color.fromHex parses valid hex colors" {
    const color = try Color.fromHex("#FF8800");
    try std.testing.expectEqual(@as(u8, 255), color.triplet.?.r);
    try std.testing.expectEqual(@as(u8, 136), color.triplet.?.g);
    try std.testing.expectEqual(@as(u8, 0), color.triplet.?.b);
}

test "Color.fromHex rejects invalid input" {
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("FF88"));
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("#GG0000"));
}
```

### Integration Tests

Test component interactions:

```zig
// tests/console_integration.zig
test "Console renders styled text with markup" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var console = Console.initWithWriter(testing.allocator, buffer.writer());
    try console.print("[bold red]Error[/]: Something failed");

    // Verify ANSI codes present
    try testing.expect(std.mem.indexOf(u8, buffer.items, "\x1b[1;31m") != null);
}
```

### Fuzz Tests

Parser robustness via fuzzing:

```zig
// src/markup.zig
test "fuzz markup parser" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            // Parser should never crash on any input
            const result = parseMarkup(input, std.testing.allocator) catch |err| switch (err) {
                error.UnbalancedBracket,
                error.InvalidTag,
                error.UnclosedTag => return,  // Expected errors
                else => return err,
            };
            defer std.testing.allocator.free(result);
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
```

### Visual Snapshot Tests

Capture expected output for renderables:

```zig
// tests/snapshots.zig
test "Panel renders with rounded borders" {
    const panel = Panel.fromText(testing.allocator, "Hello")
        .withTitle("Test")
        .rounded();

    const segments = try panel.render(40, testing.allocator);
    defer testing.allocator.free(segments);

    const output = try segmentsToString(segments, testing.allocator);
    defer testing.allocator.free(output);

    try testing.expectEqualStrings(
        \\+-- Test -----------------------------+
        \\| Hello                               |
        \\+-------------------------------------+
        \\
    , output);
}
```

## Module-Specific Test Requirements

### Color Module (`color.zig`)

| Test Case | Priority |
|-----------|----------|
| Parse valid hex colors (#RGB, #RRGGBB) | Critical |
| Reject invalid hex colors | Critical |
| Standard 16-color lookup | Critical |
| 256-color palette indexing | Critical |
| RGB to 256 downgrade accuracy | High |
| RGB to 16 downgrade accuracy | High |
| Color blending interpolation | Medium |
| ANSI code generation (fg/bg) | Critical |

### Style Module (`style.zig`)

| Test Case | Priority |
|-----------|----------|
| Individual attribute setters | Critical |
| Style combination/merge | Critical |
| Parse style strings ("bold red") | Critical |
| Parse with background ("red on white") | Critical |
| ANSI SGR sequence generation | Critical |
| Empty style handling | High |
| Unknown style token error | High |

### Cells Module (`cells.zig`)

| Test Case | Priority |
|-----------|----------|
| ASCII characters = width 1 | Critical |
| CJK characters = width 2 | Critical |
| Emoji = width 2 | Critical |
| Zero-width characters = width 0 | Critical |
| Combining marks = width 0 | Critical |
| Control characters = width 0 | High |
| Mixed-width string measurement | Critical |
| String truncation at cell boundary | High |

### Markup Module (`markup.zig`)

| Test Case | Priority |
|-----------|----------|
| Parse plain text (no tags) | Critical |
| Parse single tag pair | Critical |
| Parse nested tags | Critical |
| Escaped brackets (\[ \]) | Critical |
| Auto-close tags [/] | High |
| Unclosed tag error | Critical |
| Unbalanced bracket error | Critical |
| Empty tag error | High |

### Segment Module (`segment.zig`)

| Test Case | Priority |
|-----------|----------|
| Plain segment creation | Critical |
| Styled segment creation | Critical |
| Control segment creation | High |
| Segment cell length calculation | Critical |
| Segment splitting at cell position | High |
| Strip styles from segments | Medium |

### Text Module (`text.zig`)

| Test Case | Priority |
|-----------|----------|
| Plain text creation | Critical |
| Markup text parsing | Critical |
| Span application | Critical |
| Text concatenation | High |
| Render to segments | Critical |
| Cell length calculation | Critical |

### Terminal Module (`terminal.zig`)

| Test Case | Priority |
|-----------|----------|
| TTY detection | Critical |
| Truecolor detection (COLORTERM) | Critical |
| 256-color detection (TERM) | Critical |
| Terminal size detection | High |
| Hyperlink support detection | Medium |
| FORCE_COLOR override | High |

### Console Module (`console.zig`)

| Test Case | Priority |
|-----------|----------|
| Print plain text | Critical |
| Print with markup | Critical |
| Print styled text | Critical |
| Print renderables | Critical |
| Capture mode | High |
| Style reset between outputs | Critical |

### Panel (`renderables/panel.zig`)

| Test Case | Priority |
|-----------|----------|
| Basic panel rendering | Critical |
| Panel with title | Critical |
| Panel with subtitle | Critical |
| Box style variants (rounded, square, heavy, double, ascii) | High |
| Padding application | High |
| Width constraint | High |

### Table (`renderables/table.zig`)

| Test Case | Priority |
|-----------|----------|
| Basic table rendering | Critical |
| Column headers | Critical |
| Left/center/right alignment | Critical |
| Column width constraints | High |
| Auto-sizing columns | High |
| Table with title | Medium |
| Show/hide borders | Medium |
| Show/hide lines between rows | Medium |

### Rule (`renderables/rule.zig`)

| Test Case | Priority |
|-----------|----------|
| Plain rule rendering | Critical |
| Rule with centered title | Critical |
| Rule with left/right title | High |
| Custom characters | Medium |
| Style application | Medium |

### Progress (`renderables/progress.zig`)

| Test Case | Priority |
|-----------|----------|
| Progress bar at 0% | Critical |
| Progress bar at 50% | Critical |
| Progress bar at 100% | Critical |
| Width constraint | High |
| Style customization | Medium |
| Spinner frame advancement | High |

### Tree (`renderables/tree.zig`)

| Test Case | Priority |
|-----------|----------|
| Single node tree | Critical |
| Tree with children | Critical |
| Nested tree (multiple levels) | Critical |
| Tree guides rendering | High |
| Hide root option | Medium |
| Collapsed nodes | Medium |

## Test Coverage Goals

| Phase | Module Coverage | Line Coverage | Feature Parity |
|-------|----------------|---------------|----------------|
| Phase 1 (Core) | 100% | >90% | 100% |
| Phase 2 (Markup/Text) | 100% | >85% | 100% |
| Phase 3 (Console) | 100% | >80% | 100% |
| Phase 4 (Renderables) | 100% | >80% | 100% |
| Phase 5 (Optional) | 100% | >75% | 90%+ |

**Overall Target: 90-100% feature parity with Rich/rich_rust**

## Running Tests

### All Tests

```bash
zig build test
```

### With Optimization

```bash
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall
```

### Fuzz Testing

```bash
zig build test --fuzz
```

### Specific Module (using filter)

Tests can be filtered by name in the test runner output.

## Continuous Integration

The CI pipeline (`.github/workflows/ci.yml`) runs automatically on push/PR:

### Pipeline Stages

1. **Test Matrix**: Run all tests on Linux, macOS, Windows
2. **Optimization Levels**: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
3. **Fuzz Testing**: 60-second fuzzing session for parser robustness
4. **Format Check**: Verify `zig fmt` compliance
5. **Package Validation**: Test that external projects can import rich_zig
6. **Auto-Release**: Create GitHub release on version bump to master

### CI Matrix

| OS | Zig Version | Optimization |
|----|-------------|--------------|
| ubuntu-latest | 0.15.2 | Debug, ReleaseSafe, ReleaseFast, ReleaseSmall |
| macos-latest | 0.15.2 | Debug, ReleaseSafe |
| windows-latest | 0.15.2 | Debug, ReleaseSafe |

### Package Validation

CI creates a mock consumer project that imports rich_zig to verify:

- Package can be fetched and resolved
- Module can be imported
- Public API is accessible
- Build succeeds across platforms

## Feature Parity Checklist

Based on rich_rust spec, track implementation status:

### Core Features

- [ ] Color system (standard/256/truecolor)
- [ ] Color auto-downgrading
- [ ] Style attributes (bold, italic, underline, dim, reverse, strike, blink)
- [ ] Style parsing from strings
- [ ] Markup syntax parsing
- [ ] Unicode cell width calculation
- [ ] Terminal capability detection
- [ ] Console output management

### Renderables

- [ ] Panel with box styles
- [ ] Table with columns and alignment
- [ ] Horizontal rule with title
- [ ] Progress bar
- [ ] Spinner
- [ ] Tree structure

### Optional Features

- [ ] JSON pretty-printing
- [ ] Syntax highlighting
- [ ] Markdown rendering
- [ ] HTML export
- [ ] SVG export

## Test File Organization

```
rich_zig/
+-- src/
|   +-- color.zig           # Contains inline unit tests
|   +-- style.zig           # Contains inline unit tests
|   +-- ...
+-- tests/
|   +-- integration/
|   |   +-- console_test.zig
|   |   +-- rendering_test.zig
|   +-- snapshots/
|   |   +-- panel_test.zig
|   |   +-- table_test.zig
|   +-- fuzz/
|       +-- markup_fuzz.zig
|       +-- unicode_fuzz.zig
```

## Adding New Tests

When adding a new feature:

1. Add inline unit tests in the module file
2. Add integration tests if the feature interacts with other modules
3. Add snapshot tests if the feature produces visual output
4. Add fuzz tests if the feature parses user input
5. Update [FEATURE_PARITY.md](FEATURE_PARITY.md) to mark feature complete
6. Update this document with new test requirements

## Parity Testing

For features that exist in rich_rust, create parity tests:

```zig
// tests/parity/color_parity.zig
test "color downgrade matches rich_rust" {
    // RGB(255, 128, 0) should downgrade to 256-color 208
    const color = Color.fromRgb(255, 128, 0);
    const downgraded = color.downgrade(.eight_bit);
    try testing.expectEqual(@as(u8, 208), downgraded.number.?);
}
```

Reference rich_rust tests when implementing to ensure behavioral compatibility.

## Regression Testing

Before each release:

1. Run full test suite: `zig build test`
2. Run fuzz tests: `zig build test --fuzz`
3. Run optimization variants: `zig build test -Doptimize=ReleaseSafe`
4. Verify no new warnings or errors
5. Check FEATURE_PARITY.md is up to date
