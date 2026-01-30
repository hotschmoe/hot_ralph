# rich_zig

A full-featured Zig port of [Python Rich](https://github.com/Textualize/rich), targeting **100% feature parity** with [rich_rust](https://github.com/Dicklesworthstone/rich_rust).

```
+--------------------------------------------------+
|  rich_zig: Beautiful Terminal Output in Pure Zig |
|                                                  |
|  [bold green]Tables[/] | [cyan]Panels[/] | [yellow]Progress[/] | [magenta]Trees[/]  |
+--------------------------------------------------+
```

[![CI](https://github.com/hotschmoe-zig/rich_zig/actions/workflows/ci.yml/badge.svg)](https://github.com/hotschmoe-zig/rich_zig/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange)](https://ziglang.org/)

## Overview

rich_zig brings rich text and beautiful formatting to Zig terminal applications. Create visually sophisticated CLI apps with styled text, tables, panels, progress bars, trees, syntax highlighting, and more.

### Design Goals

- **100% Feature Parity**: Complete port of Rich/rich_rust functionality
- **Zero Dependencies**: Core features use only Zig standard library
- **Pure Zig**: No unsafe code, explicit memory management
- **Terminal-Aware**: Automatic color detection and downgrading
- **Unicode-Correct**: Proper CJK, emoji, and combining mark handling
- **Allocator-Explicit**: All allocations visible and controllable
- **Cross-Platform**: Linux, macOS, Windows with consistent behavior

## Features

### Core (Phase 1-3) - Complete

| Component | Description | Status |
|-----------|-------------|--------|
| Color | 4-bit, 8-bit, 24-bit with auto-downgrade | Complete |
| Style | Bold, italic, underline, dim, reverse, strike, hyperlinks | Complete |
| Segment | Atomic rendering unit with text + style + control codes | Complete |
| Cells | Unicode width calculation (CJK, emoji, zero-width) | Complete |
| Markup | BBCode-like syntax `[bold red]text[/]` | Complete |
| Text | Styled text with spans, wrapping, alignment | Complete |
| Terminal | TTY, color, size, unicode detection | Complete |
| Console | Print, log, capture, export, status | Complete |

### Renderables (Phase 4) - Complete

| Component | Description | Status |
|-----------|-------------|--------|
| Panel | Bordered boxes with title/subtitle, all box styles | Complete |
| Table | Unicode tables with alignment, headers, footer, caption | Complete |
| Rule | Horizontal rules with title alignment | Complete |
| Progress | Progress bars, spinners, timing, speed, groups | Complete |
| Tree | Tree structures with guides, styling, collapse | Complete |
| Padding | Uniform and per-side padding with styling | Complete |
| Align | Horizontal and vertical alignment | Complete |
| Columns | Multi-column layout | Complete |
| Layout | Split views (horizontal/vertical) | Complete |
| Live | Real-time updating display | Complete |

### Optional (Phase 5) - Partial

| Component | Description | Status |
|-----------|-------------|--------|
| JSON | Pretty-printed JSON with themes | Complete |
| Syntax | Syntax highlighting | Planned |
| Markdown | Terminal markdown rendering | Planned |

## Installation

### Using Zig Package Manager (Recommended)

Add rich_zig to your project using `zig fetch`:

```bash
zig fetch --save git+https://github.com/hotschmoe-zig/rich_zig.git
```

Or add manually to your `build.zig.zon`:

```zig
.dependencies = .{
    .rich_zig = .{
        .url = "git+https://github.com/hotschmoe-zig/rich_zig.git",
        .hash = "...",  // Will be filled by zig fetch
    },
},
```

Then in your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the rich_zig dependency
    const rich_zig = b.dependency("rich_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rich_zig", .module = rich_zig.module("rich_zig") },
            },
        }),
    });

    b.installArtifact(exe);
}
```

### Using a Specific Version

```zig
.dependencies = .{
    .rich_zig = .{
        .url = "git+https://github.com/hotschmoe-zig/rich_zig.git#v0.9.1",
        .hash = "...",
    },
},
```

### Local Development

Clone and reference locally:

```zig
.dependencies = .{
    .rich_zig = .{
        .path = "../rich_zig",
    },
},
```

## Usage

### Basic Styled Output

```zig
const std = @import("std");
const rich = @import("rich_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var console = rich.Console.init(allocator);

    // Markup syntax
    try console.print("[bold green]Success![/] Operation completed.");
    try console.print("[red on white]Error:[/] [italic]File not found[/]");

    // Horizontal rule
    try console.rule("Configuration");
}
```

### Tables

```zig
var table = rich.Table.init(allocator)
    .withTitle("Server Status")
    .withColumn(rich.Column.init("Service"))
    .withColumn(rich.Column.init("Status").withJustify(.center))
    .withColumn(rich.Column.init("Uptime").withJustify(.right));

try table.addRowCells(.{ "nginx", "Running", "14d 3h" });
try table.addRowCells(.{ "postgres", "Running", "14d 3h" });
try table.addRowCells(.{ "redis", "Stopped", "0s" });

try console.printRenderable(table);
```

Output:
```
+----------+---------+---------+
| Service  | Status  |  Uptime |
+----------+---------+---------+
| nginx    | Running |  14d 3h |
| postgres | Running |  14d 3h |
| redis    | Stopped |      0s |
+----------+---------+---------+
```

### Panels

```zig
const panel = rich.Panel.fromText(allocator, "Welcome to the system!")
    .withTitle("Message")
    .withSubtitle("v0.9.1")
    .withWidth(50)
    .rounded();

try console.printRenderable(panel);
```

Output:
```
+-- Message --------------------------+
| Welcome to the system!             |
+------------------------- v0.9.1 ---+
```

### Progress Bars

```zig
var i: usize = 0;
while (i <= 100) : (i += 5) {
    const bar = rich.ProgressBar.init()
        .withCompleted(i)
        .withTotal(100)
        .withWidth(40);

    try console.writer.writeAll("\r");
    try console.printRenderable(bar);
    std.time.sleep(100 * std.time.ns_per_ms);
}
```

### Trees

```zig
var root = rich.TreeNode.init(allocator, "project");

var src = try root.addChildLabel("src");
_ = try src.addChildLabel("main.zig");
_ = try src.addChildLabel("lib.zig");

_ = try root.addChildLabel("build.zig");
_ = try root.addChildLabel("README.md");

const tree = rich.Tree.init(root);
try console.printRenderable(tree);
```

Output:
```
project
+-- src
|   +-- main.zig
|   +-- lib.zig
+-- build.zig
+-- README.md
```

## Architecture

```
+-------------------+
|     Console       |  Central output manager
+-------------------+
         |
         v
+-------------------+
|   Renderables     |  Panel, Table, Tree, etc.
+-------------------+
         |
         v
+-------------------+
|     Segment       |  Text + Style atomic unit
+-------------------+
         |
    +----+----+
    v         v
+-------+ +-------+
| Style | | Text  |
+-------+ +-------+
    |
    v
+-------+
| Color |
+-------+
```

### Module Structure

```
src/
+-- root.zig           # Library entry point (public API)
+-- main.zig           # CLI executable
+-- color.zig          # Color types and conversions
+-- style.zig          # Text styling attributes
+-- segment.zig        # Atomic render unit
+-- cells.zig          # Unicode width calculations
+-- text.zig           # Text with styled spans
+-- markup.zig         # Markup parser [bold]...[/]
+-- terminal.zig       # Terminal detection
+-- console.zig        # Output management
+-- box.zig            # Box drawing characters
+-- renderables/
    +-- panel.zig      # Bordered panels
    +-- table.zig      # Tables with columns
    +-- rule.zig       # Horizontal rules
    +-- progress.zig   # Progress bars, spinners
    +-- tree.zig       # Tree structures
    +-- json.zig       # JSON pretty-printing
```

## Color System

rich_zig automatically detects terminal color capabilities and downgrades colors as needed:

| System | Colors | Detection |
|--------|--------|-----------|
| Standard | 16 (4-bit) | Default fallback |
| 256 | 256 (8-bit) | TERM contains "256" |
| Truecolor | 16M (24-bit) | COLORTERM=truecolor |

```zig
// Explicit color specification
const style = Style.empty
    .foreground(Color.fromRgb(255, 128, 0))  // Truecolor
    .background(Color.from256(42));           // 256-color

// Named colors
const warning = Style.empty.foreground(Color.yellow).bold();
```

## Building

```bash
# Build library and executable
zig build

# Run tests
zig build test

# Run executable
zig build run

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Testing

See [docs/testing.md](docs/testing.md) for the comprehensive testing strategy.

```bash
# Run all tests
zig build test

# Run with specific optimization
zig build test -Doptimize=ReleaseSafe

# Run fuzz tests
zig build test --fuzz
```

## Feature Parity

We track 100% feature parity with Rich/rich_rust. See [docs/FEATURE_PARITY.md](docs/FEATURE_PARITY.md) for detailed progress.

| Phase | Components | Status |
|-------|------------|--------|
| Core (P0) | Color, Style, Segment, Cells, Markup, Text | 100% Complete |
| Console (P0) | Terminal detection, Console I/O | 100% Complete |
| Renderables (P1) | Panel, Table, Rule, Progress, Tree, Layout | ~95% Complete |
| Optional (P2) | JSON, Syntax, Markdown | ~35% Complete |

## CI/CD

Automated testing via GitHub Actions:

- **Platforms**: Linux, macOS, Windows
- **Optimization Levels**: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
- **Fuzz Testing**: Parser robustness
- **Package Validation**: Consumer integration test
- **Auto-Release**: Tags created on version bump to master

## Compatibility

| Requirement | Version |
|-------------|---------|
| Zig | 0.15.2+ |
| Platforms | Linux, macOS, Windows |
| Terminals | Any with ANSI support |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Ensure tests pass: `zig build test`
4. Ensure formatting: `zig fmt src/`
5. Submit a pull request

See [docs/FEATURE_PARITY.md](docs/FEATURE_PARITY.md) for what needs implementation.

## References

- [Python Rich](https://github.com/Textualize/rich) - Original library
- [rich_rust](https://github.com/Dicklesworthstone/rich_rust) - Rust port
- [Unicode East Asian Width](https://www.unicode.org/reports/tr11/) - UAX #11
- [ANSI Escape Codes](https://en.wikipedia.org/wiki/ANSI_escape_code)

## License

MIT License - See LICENSE file for details.
