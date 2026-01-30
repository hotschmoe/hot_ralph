# Cross-Platform Build Progress

Living document tracking cross-platform compatibility status and fixes.

**Last Updated**: 2026-01-29
**Zig Version**: 0.15.2

---

## Current Status

| Target | Build | Tests | Status |
|--------|-------|-------|--------|
| Native (Windows) | PASS | PASS | OK |
| x86_64-windows | PASS | - | OK |
| x86_64-linux | PASS | - | OK |
| aarch64-linux | PASS | - | OK |
| x86_64-macos | PASS | - | OK |
| aarch64-macos | PASS | - | OK |
| wasm32-wasi | PASS | - | OK |

### Optimization Level Results (Native)

| Level | Build | Tests |
|-------|-------|-------|
| Debug | PASS | PASS |
| ReleaseSafe | PASS | PASS |
| ReleaseFast | PASS | PASS |
| ReleaseSmall | PASS | PASS |

---

## Issue 1: POSIX `winsize` Field Name Mismatch

**Status**: Fixed (v0.7.1)
**Severity**: Critical (blocks Linux/macOS builds)
**Location**: `src/terminal.zig:98`

### Problem

The `getTerminalSizePosix()` function uses `ws.ws_col` and `ws.ws_row` to access terminal dimensions:

```zig
fn getTerminalSizePosix() TerminalSize {
    if (@hasDecl(std.posix, "winsize")) {
        var ws: std.posix.winsize = undefined;
        const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            return .{ .width = ws.ws_col, .height = ws.ws_row };  // <-- HERE
        }
    }
    return .{ .width = 80, .height = 24 };
}
```

The `std.posix.winsize` struct has different field names depending on the target platform. On some platforms, these fields may be named differently (e.g., `col`/`row` vs `ws_col`/`ws_row`).

### Error Message

```
error: no field named 'ws_col' in struct 'posix.winsize'
    return .{ .width = ws.ws_col, .height = ws.ws_row };
```

### Affected Targets

- x86_64-linux
- aarch64-linux
- x86_64-macos
- aarch64-macos

### Suggested Fix Approaches

#### Approach A: Check Field Names at Comptime

Use `@hasField` to detect which field names are available:

```zig
fn getTerminalSizePosix() TerminalSize {
    if (@hasDecl(std.posix, "winsize")) {
        var ws: std.posix.winsize = undefined;
        const result = std.posix.system.ioctl(
            std.posix.STDOUT_FILENO,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&ws)
        );
        if (result == 0) {
            // Handle different field naming conventions
            const width = if (@hasField(std.posix.winsize, "ws_col"))
                ws.ws_col
            else if (@hasField(std.posix.winsize, "col"))
                ws.col
            else
                80;

            const height = if (@hasField(std.posix.winsize, "ws_row"))
                ws.ws_row
            else if (@hasField(std.posix.winsize, "row"))
                ws.row
            else
                24;

            return .{ .width = width, .height = height };
        }
    }
    return .{ .width = 80, .height = 24 };
}
```

#### Approach B: Use OS-Specific Branches

Branch based on target OS at comptime:

```zig
fn getTerminalSizePosix() TerminalSize {
    if (!@hasDecl(std.posix, "winsize")) {
        return .{ .width = 80, .height = 24 };
    }

    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&ws)
    );

    if (result != 0) {
        return .{ .width = 80, .height = 24 };
    }

    return switch (builtin.os.tag) {
        .linux, .macos => .{ .width = ws.col, .height = ws.row },
        else => .{ .width = ws.ws_col, .height = ws.ws_row },
    };
}
```

#### Approach C: Investigate Zig std Library

Check the Zig 0.15.2 standard library source to see:
1. What the actual field names are for each platform
2. If there's a portable accessor or helper function

**Where to look**:
- `lib/std/posix.zig` - POSIX type definitions
- `lib/std/os/linux.zig` - Linux-specific definitions
- `lib/std/os/darwin.zig` - macOS-specific definitions

### Starting Point

1. Cross-compile to identify exact field names:
   ```bash
   zig build -Dtarget=x86_64-linux 2>&1 | head -50
   ```
2. Check std library source for `winsize` definition
3. Implement Approach A (most flexible) or B (most explicit)

---

## Issue 2: WASM Target Missing `ioctl`

**Status**: Fixed (v0.7.1)
**Severity**: Medium (WASM is a secondary target)
**Location**: `src/terminal.zig:93-102`

### Problem

The `getTerminalSizePosix()` function uses `ioctl()` which requires libc. The wasm32-wasi target does not have libc available by default.

### Error Message

```
error: ioctl not available without libc
```

### Affected Targets

- wasm32-wasi

### Suggested Fix Approaches

#### Approach A: Guard WASM at Comptime

Skip POSIX terminal size detection entirely for WASM:

```zig
fn getTerminalSize() TerminalSize {
    if (builtin.os.tag == .windows) {
        return getTerminalSizeWindows();
    } else if (builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32) {
        // WASM environments don't have terminal size - use defaults
        return .{ .width = 80, .height = 24 };
    } else {
        return getTerminalSizePosix();
    }
}
```

#### Approach B: Use `@hasDecl` Guard

The existing `@hasDecl(std.posix, "winsize")` check might need to also verify `ioctl` availability:

```zig
fn getTerminalSizePosix() TerminalSize {
    if (@hasDecl(std.posix, "winsize") and @hasDecl(std.posix.system, "ioctl")) {
        // ... existing code ...
    }
    return .{ .width = 80, .height = 24 };
}
```

### Starting Point

1. Add WASM guard in `getTerminalSize()` function before calling POSIX path
2. Test with: `zig build -Dtarget=wasm32-wasi`

---

## Fix Priority

1. **Issue 1** (POSIX winsize) - Critical, blocks major platforms
2. **Issue 2** (WASM ioctl) - Medium, nice-to-have for web targets

---

## Progress Log

| Date | Change | By |
|------|--------|----|
| 2026-01-29 | Fixed both issues: winsize field names and WASM guard (v0.7.1) | - |
| 2026-01-28 | Initial document created from build-verifier output | - |

---

## Verification Commands

```bash
# Native build and test
zig build test

# Cross-platform verification
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
zig build -Dtarget=wasm32-wasi

# All optimization levels
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSmall
```
