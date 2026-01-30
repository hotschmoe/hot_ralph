# Specification: rich_zig

This document defines the technical requirements for rich_zig to achieve 100% feature parity with rich_rust.

---

## Table of Contents

1. [Scope](#scope)
2. [API Contract](#api-contract)
3. [Module Specifications](#module-specifications)
4. [Renderable Protocol](#renderable-protocol)
5. [Terminal Support](#terminal-support)
6. [Feature Requirements](#feature-requirements)
7. [Performance Requirements](#performance-requirements)
8. [Testing Requirements](#testing-requirements)
9. [Documentation Requirements](#documentation-requirements)

---

## Scope

### In Scope

| Category | Features |
|----------|----------|
| Core | Color (4/8/24-bit), Style, Segment, Cells (Unicode width), Markup parsing |
| Text | Styled text with spans, wrapping, alignment, truncation |
| Console | Print, capture, export (HTML/text), status, logging |
| Renderables | Panel, Table, Rule, Progress, Tree, Columns, Padding, Align, Layout, Live |
| Optional | JSON pretty-print, Syntax highlighting, Markdown rendering |

### Out of Scope

| Feature | Reason |
|---------|--------|
| Python inspect() equivalent | Language-specific introspection |
| Traceback with local variables | Requires debug info parsing |
| REPL integration | Python-specific |
| Jupyter notebook rendering | Environment-specific |

### Deferred (Post-1.0)

| Feature | Notes |
|---------|-------|
| SVG export | Complex, low priority |
| Pager support | Requires terminal raw mode handling |

---

## API Contract

### Allocator Convention

All public APIs that allocate memory take `allocator: std.mem.Allocator` as their first parameter.

```zig
// Correct
pub fn fromText(allocator: Allocator, text: []const u8) !Panel

// Incorrect - no allocator parameter
pub fn fromText(text: []const u8) !Panel
```

### Resource Management

Types that allocate must implement `deinit(self: *@This()) void`:

```zig
var panel = try Panel.fromText(allocator, "content");
defer panel.deinit();
```

### Error Handling

- All fallible operations return `!T` (error union)
- Error sets are explicit at API boundaries
- No `catch unreachable` without documented justification

```zig
pub const ParseError = error{
    UnbalancedBracket,
    InvalidTag,
    UnclosedTag,
    OutOfMemory,
};

pub fn parse(allocator: Allocator, input: []const u8) ParseError![]Token
```

### Builder Pattern

Renderables use fluent builder APIs that return `*Self` for chaining:

```zig
const panel = Panel.fromText(allocator, "content")
    .withTitle("Title")
    .withSubtitle("Subtitle")
    .withWidth(50)
    .withBoxStyle(box.rounded);
```

Builder methods:
- Do not allocate (store references/values)
- Return `*Self` for chaining
- Are order-independent where possible

---

## Module Specifications

### Color (`color.zig`)

```zig
pub const Color = union(enum) {
    default,                    // Terminal default
    standard: Standard,         // 16 ANSI colors (0-15)
    indexed: u8,                // 256-color palette
    rgb: struct { r: u8, g: u8, b: u8 },
};
```

**Required operations:**

| Operation | Signature |
|-----------|-----------|
| From hex | `fromHex(hex: []const u8) !Color` |
| From RGB | `fromRgb(r: u8, g: u8, b: u8) Color` |
| From name | `fromName(name: []const u8) ?Color` |
| Downgrade | `downgrade(self: Color, depth: ColorDepth) Color` |
| To ANSI | `toAnsi(self: Color, is_foreground: bool) []const u8` |
| Blend | `blend(self: Color, other: Color, factor: f32) Color` |

**Color depth auto-detection:**

| Environment | Detection | Depth |
|-------------|-----------|-------|
| COLORTERM=truecolor | Truecolor | 24-bit |
| COLORTERM=24bit | Truecolor | 24-bit |
| TERM contains "256" | 256-color | 8-bit |
| TERM contains "color" | Standard | 4-bit |
| NO_COLOR set | None | 0-bit |

### Style (`style.zig`)

```zig
pub const Style = struct {
    foreground: ?Color = null,
    background: ?Color = null,
    bold: ?bool = null,
    dim: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    blink: ?bool = null,
    blink_rapid: ?bool = null,
    reverse: ?bool = null,
    conceal: ?bool = null,
    strike: ?bool = null,
    hyperlink: ?[]const u8 = null,
};
```

**Required operations:**

| Operation | Signature |
|-----------|-----------|
| Parse string | `parse(spec: []const u8) !Style` |
| Combine | `combine(self: Style, other: Style) Style` |
| To ANSI | `toAnsi(self: Style, allocator: Allocator) ![]const u8` |
| Reset | `reset() []const u8` |

**Parse grammar:**

```
style_spec := attribute* [color] ["on" color]
attribute  := "bold" | "dim" | "italic" | "underline" | "blink" | "reverse" | "strike" | "conceal"
             | "not" attribute
color      := named_color | "#" hex{6} | "rgb(" num "," num "," num ")"
```

### Segment (`segment.zig`)

```zig
pub const Segment = struct {
    text: []const u8,
    style: Style = .{},
    control: ?ControlCode = null,
};
```

**Required operations:**

| Operation | Signature |
|-----------|-----------|
| Cell length | `cellLength(self: Segment) usize` |
| Split at | `splitAt(self: Segment, pos: usize, allocator: Allocator) !struct { Segment, Segment }` |
| Strip style | `stripStyle(self: Segment) Segment` |
| Is control | `isControl(self: Segment) bool` |

### Cells (`cells.zig`)

Unicode width calculation per UAX #11.

| Character Class | Width |
|-----------------|-------|
| ASCII printable | 1 |
| CJK ideographs | 2 |
| CJK punctuation | 2 |
| Emoji (most) | 2 |
| Zero-width joiners | 0 |
| Combining marks | 0 |
| Control characters | 0 |

**Required operations:**

| Operation | Signature |
|-----------|-----------|
| Char width | `charWidth(c: u21) u2` |
| String width | `stringWidth(s: []const u8) usize` |
| Truncate | `truncate(s: []const u8, max_width: usize, ellipsis: []const u8) []const u8` |
| Pad | `pad(s: []const u8, width: usize, align: Align, allocator: Allocator) ![]const u8` |

### Markup (`markup.zig`)

BBCode-style markup parser.

**Syntax:**

```
[style]text[/style]  - Apply style to text
[style]text[/]       - Auto-close most recent tag
\[                   - Escaped literal bracket
[link=url]text[/]    - Hyperlink
```

**Required error handling:**

| Error | Condition |
|-------|-----------|
| UnbalancedBracket | `[` without matching `]` |
| UnclosedTag | Tag opened but never closed |
| InvalidTag | Empty tag `[]` or malformed |

### Console (`console.zig`)

Central output management.

```zig
pub const Console = struct {
    allocator: Allocator,
    writer: Writer,
    terminal: Terminal,
    force_terminal: ?bool = null,
    force_color: ?ColorDepth = null,
    width: ?usize = null,

    pub fn print(self: *Console, markup: []const u8) !void;
    pub fn printStyled(self: *Console, text: []const u8, style: Style) !void;
    pub fn printRenderable(self: *Console, renderable: anytype) !void;
    pub fn rule(self: *Console, title: ?[]const u8) !void;
    pub fn log(self: *Console, message: []const u8) !void;
    pub fn clear(self: *Console) !void;
    pub fn bell(self: *Console) !void;
};
```

**Capture mode:**

```zig
var captured = std.ArrayList(u8).init(allocator);
var console = Console.initCapture(allocator, &captured);
try console.print("[bold]test[/]");
const output = captured.items; // Contains rendered output
```

---

## Renderable Protocol

All renderables implement a common interface for composition.

### Required Method

```zig
pub fn render(self: *const @This(), max_width: usize, allocator: Allocator) ![]Segment
```

### Optional Method (Measurement)

```zig
pub fn measure(self: *const @This(), max_width: usize) Measurement

pub const Measurement = struct {
    minimum: usize,  // Minimum width needed
    maximum: usize,  // Maximum width that makes sense
};
```

### Renderable Specifications

#### Panel

| Property | Type | Default |
|----------|------|---------|
| content | Renderable | required |
| title | ?[]const u8 | null |
| subtitle | ?[]const u8 | null |
| title_align | Align | .left |
| subtitle_align | Align | .right |
| box_style | BoxStyle | ascii |
| border_style | Style | {} |
| width | ?usize | null (expand) |
| height | ?usize | null (fit) |
| padding | Padding | 1,1,0,1 |
| expand | bool | true |

#### Table

| Property | Type | Default |
|----------|------|---------|
| columns | []Column | required |
| rows | [][]Cell | [] |
| title | ?[]const u8 | null |
| caption | ?[]const u8 | null |
| box_style | BoxStyle | ascii |
| show_header | bool | true |
| show_edge | bool | true |
| show_lines | bool | false |
| show_footer | bool | false |
| padding | Padding | 0,1 |
| collapse_padding | bool | false |
| expand | bool | false |

**Column properties:**

| Property | Type | Default |
|----------|------|---------|
| header | []const u8 | required |
| justify | Align | .left |
| width | ?usize | null (auto) |
| min_width | ?usize | null |
| max_width | ?usize | null |
| ratio | ?usize | null |
| no_wrap | bool | false |
| overflow | Overflow | .fold |

#### Progress

| Property | Type | Default |
|----------|------|---------|
| completed | usize | 0 |
| total | usize | 100 |
| width | ?usize | null |
| style | Style | {} |
| complete_style | Style | {blue} |
| finished_style | Style | {green} |
| pulse | bool | false |

**Spinner styles (minimum required):**

- dots, dots2, dots3
- line
- arc
- arrow
- bouncingBar
- bouncingBall

#### Tree

| Property | Type | Default |
|----------|------|---------|
| root | TreeNode | required |
| guides | GuideStyle | .rounded |
| hide_root | bool | false |
| expanded | bool | true |

#### Rule

| Property | Type | Default |
|----------|------|---------|
| title | ?[]const u8 | null |
| characters | []const u8 | "-" |
| style | Style | {} |
| align | Align | .center |
| end | []const u8 | "" |

---

## Terminal Support

### Minimum Requirements

| Platform | Minimum Version |
|----------|-----------------|
| Linux | Any with ANSI support |
| macOS | 10.12+ |
| Windows | Windows 10 1607+ (Windows Terminal, ConEmu, or VT mode enabled) |

### Detection Requirements

| Capability | Environment Check |
|------------|-------------------|
| Is TTY | `std.posix.isatty()` |
| Truecolor | COLORTERM contains "truecolor" or "24bit" |
| 256-color | TERM contains "256" |
| Basic color | TERM set and not "dumb" |
| No color | NO_COLOR set |
| Force color | FORCE_COLOR set |
| Width/Height | ioctl TIOCGWINSZ or Windows API |
| Unicode | LC_ALL/LANG contains "UTF" or Windows >= 10 |

### Legacy Windows Console

When VT mode is unavailable:
- Strip ANSI codes from output
- Use Windows console API for colors if available
- Gracefully degrade to plain text

---

## Feature Requirements

### P0 - Core (Required for 1.0)

All features in FEATURE_PARITY.md marked P0 must be complete:

- [x] Color system (all types, downgrading)
- [x] Style (all attributes, parsing)
- [x] Segment (creation, measurement)
- [x] Cells (Unicode width)
- [x] Markup (parsing, rendering)
- [x] Text (spans, rendering)
- [x] Terminal (detection)
- [x] Console (print, renderables)
- [x] Box (all styles)
- [x] Panel (basic features)
- [x] Table (basic features)
- [x] Rule (all features)

### P1 - Extended (Required for 1.0)

- [x] Progress (bar, spinner)
- [x] Tree (all features)
- [x] Columns, Padding, Align
- [x] Layout (basic splits)
- [x] Live display
- [x] Console capture/export

### P2 - Optional (Target for 1.0)

- [x] JSON pretty-printing
- [ ] Syntax highlighting (basic - Zig, JSON, Markdown)
- [ ] Markdown rendering (CommonMark subset)
- [x] Emoji support

### Not Required for 1.0

- SVG export
- Pager support
- Logging integration (std.log handler)
- Full syntax highlighting (all languages)
- Full Markdown (GFM tables, task lists)

---

## Performance Requirements

### Targets

| Operation | Target |
|-----------|--------|
| Markup parse (1KB) | < 1ms |
| Table render (100 rows) | < 10ms |
| Unicode width (1KB) | < 0.5ms |
| Color downgrade | < 1us |

### Memory

| Constraint | Requirement |
|------------|-------------|
| No global allocations | All allocations via passed allocator |
| Segment pooling | Optional, for high-throughput |
| Lazy rendering | Defer work until render() called |

### Compile Time

| Metric | Target |
|--------|--------|
| Clean build | < 30s |
| Incremental | < 5s |
| Debug build | < 15s |

---

## Testing Requirements

### Coverage Targets

| Category | Coverage |
|----------|----------|
| P0 modules | > 90% line coverage |
| P1 modules | > 85% line coverage |
| P2 modules | > 75% line coverage |
| Public APIs | 100% documented and tested |

### Test Types Required

1. **Unit tests** - Every public function
2. **Integration tests** - Component interactions
3. **Fuzz tests** - All parsers (markup, style, color)
4. **Snapshot tests** - Visual output verification
5. **Platform tests** - CI runs on Linux, macOS, Windows

### Parity Tests

For each feature in FEATURE_PARITY.md, there must be a test verifying behavior matches rich_rust.

---

## Documentation Requirements

### Required Documentation

| Document | Content |
|----------|---------|
| README.md | Overview, installation, quick start |
| FEATURE_PARITY.md | Feature tracking vs rich_rust |
| SPEC.md | This document |
| VISION.md | Project goals and roadmap |
| API reference | Every public type and function |

### Code Documentation

- All public functions have doc comments
- Examples for non-trivial APIs
- Error conditions documented

### Examples Required

| Example | Demonstrates |
|---------|--------------|
| basic_output | Markup, colors, styles |
| tables | Table creation, columns, alignment |
| panels | Panels, nesting, box styles |
| progress | Progress bars, spinners |
| trees | Tree structures, styling |
| layout | Split views, composition |
| live | Real-time updates |

---

## Version Milestones

### 0.10.x (Current)

- P0 and P1 complete
- Basic P2 features
- Documentation in progress

### 0.11.0

- Syntax highlighting (Zig, JSON, Markdown)
- API stabilization
- Performance optimization

### 0.12.0

- Markdown rendering (CommonMark subset)
- Comprehensive examples
- API freeze for 1.0

### 1.0.0

- All P0, P1, P2 features complete
- Full documentation
- Stability commitment
- Performance benchmarks published

---

## Appendix: Box Styles

Required box styles matching rich_rust:

| Style | Characters |
|-------|------------|
| ascii | `+-+\|`, corners: `+` |
| square | Light box drawing |
| rounded | Rounded corners |
| heavy | Bold lines |
| double | Double lines |
| minimal | Minimal borders |
| simple | Simple style |
| horizontals | Horizontal only |
| markdown | Markdown-style |

---

## Appendix: ANSI SGR Codes

Reference for style implementation:

| Code | Effect |
|------|--------|
| 0 | Reset |
| 1 | Bold |
| 2 | Dim |
| 3 | Italic |
| 4 | Underline |
| 5 | Slow blink |
| 6 | Rapid blink |
| 7 | Reverse |
| 8 | Conceal |
| 9 | Strikethrough |
| 30-37 | Foreground (standard) |
| 38;5;n | Foreground (256) |
| 38;2;r;g;b | Foreground (RGB) |
| 40-47 | Background (standard) |
| 48;5;n | Background (256) |
| 48;2;r;g;b | Background (RGB) |
