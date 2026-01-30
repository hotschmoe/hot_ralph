const std = @import("std");
const builtin = @import("builtin");
const ColorSystem = @import("color.zig").ColorSystem;

pub const TerminalInfo = struct {
    width: u16 = 80,
    height: u16 = 24,
    color_system: ColorSystem = .standard,
    is_tty: bool = false,
    supports_unicode: bool = true,
    supports_hyperlinks: bool = false,
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
};

const TerminalSize = struct { width: u16, height: u16 };

pub fn detect() TerminalInfo {
    var info = TerminalInfo{};

    // Get environment variables (cross-platform)
    info.term = std.process.getEnvVarOwned(std.heap.page_allocator, "TERM") catch null;
    info.term_program = std.process.getEnvVarOwned(std.heap.page_allocator, "TERM_PROGRAM") catch null;

    // Check if stdout is a TTY
    info.is_tty = isTty();

    if (!info.is_tty) {
        // Check FORCE_COLOR
        if (getEnv("FORCE_COLOR")) |_| {
            info.color_system = .truecolor;
        } else {
            info.color_system = .standard;
        }
        return info;
    }

    // Get terminal size
    const size = getTerminalSize();
    info.width = size.width;
    info.height = size.height;

    // Detect color support
    if (getEnv("NO_COLOR")) |_| {
        info.color_system = .standard;
    } else {
        info.color_system = detectColorSystem();
    }

    // Detect hyperlink support
    info.supports_hyperlinks = detectHyperlinks();

    return info;
}

fn isTty() bool {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return false;
        var mode: std.os.windows.DWORD = 0;
        return std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0;
    } else {
        const fd = std.posix.STDOUT_FILENO;
        return std.posix.isatty(fd);
    }
}

fn getEnv(name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, name) catch null;
}

fn getTerminalSize() TerminalSize {
    if (builtin.os.tag == .windows) {
        return getTerminalSizeWindows();
    } else if (builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32) {
        return .{ .width = 80, .height = 24 };
    } else {
        return getTerminalSizePosix();
    }
}

fn getTerminalSizeWindows() TerminalSize {
    const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch
        return .{ .width = 80, .height = 24 };

    var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(handle, &info) != 0) {
        const width: u16 = @intCast(info.srWindow.Right - info.srWindow.Left + 1);
        const height: u16 = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1);
        return .{ .width = width, .height = height };
    }

    return .{ .width = 80, .height = 24 };
}

fn getTerminalSizePosix() TerminalSize {
    if (@hasDecl(std.posix, "winsize")) {
        var ws: std.posix.winsize = undefined;
        const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            return .{ .width = ws.col, .height = ws.row };
        }
    }
    return .{ .width = 80, .height = 24 };
}

fn detectColorSystem() ColorSystem {
    // Check COLORTERM
    if (getEnv("COLORTERM")) |ct| {
        defer std.heap.page_allocator.free(ct);
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
            return .truecolor;
        }
    }

    // Check TERM
    if (getEnv("TERM")) |term| {
        defer std.heap.page_allocator.free(term);
        if (std.mem.indexOf(u8, term, "256color") != null or
            std.mem.indexOf(u8, term, "256") != null)
        {
            return .eight_bit;
        }
        if (std.mem.indexOf(u8, term, "truecolor") != null) {
            return .truecolor;
        }
    }

    // Check terminal program
    if (getEnv("TERM_PROGRAM")) |prog| {
        defer std.heap.page_allocator.free(prog);
        const truecolor_terminals = [_][]const u8{
            "iTerm.app",
            "Apple_Terminal",
            "WezTerm",
            "vscode",
            "Hyper",
            "mintty",
            "Terminus",
            "Alacritty",
            "kitty",
        };
        for (truecolor_terminals) |t| {
            if (std.mem.eql(u8, prog, t)) return .truecolor;
        }
    }

    // Windows Terminal
    if (getEnv("WT_SESSION")) |wt| {
        defer std.heap.page_allocator.free(wt);
        return .truecolor;
    }

    // ConEmu
    if (getEnv("ConEmuANSI")) |ce| {
        defer std.heap.page_allocator.free(ce);
        if (std.mem.eql(u8, ce, "ON")) {
            return .truecolor;
        }
    }

    // Default for modern terminals
    return .eight_bit;
}

fn detectHyperlinks() bool {
    // OSC 8 hyperlink support detection
    if (getEnv("TERM_PROGRAM")) |prog| {
        defer std.heap.page_allocator.free(prog);
        const supported = [_][]const u8{
            "iTerm.app",
            "WezTerm",
            "vscode",
            "Hyper",
            "Alacritty",
            "kitty",
        };
        for (supported) |t| {
            if (std.mem.eql(u8, prog, t)) return true;
        }
    }

    // Windows Terminal supports hyperlinks
    if (getEnv("WT_SESSION")) |wt| {
        defer std.heap.page_allocator.free(wt);
        return true;
    }

    return false;
}

pub fn enableVirtualTerminal() bool {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return false;
        var mode: std.os.windows.DWORD = 0;
        if (std.os.windows.kernel32.GetConsoleMode(handle, &mode) == 0) {
            return false;
        }
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        mode |= 0x0004;
        return std.os.windows.kernel32.SetConsoleMode(handle, mode) != 0;
    }
    return true; // Always supported on POSIX
}

pub fn enableUtf8() bool {
    if (builtin.os.tag == .windows) {
        // Set console output code page to UTF-8 (65001)
        const CP_UTF8 = 65001;
        return std.os.windows.kernel32.SetConsoleOutputCP(CP_UTF8) != 0;
    }
    return true; // POSIX terminals typically use UTF-8 by default
}

// Tests
test "TerminalInfo defaults" {
    const info = TerminalInfo{};
    try std.testing.expectEqual(@as(u16, 80), info.width);
    try std.testing.expectEqual(@as(u16, 24), info.height);
    try std.testing.expectEqual(ColorSystem.standard, info.color_system);
}

test "detect returns valid info" {
    const info = detect();
    try std.testing.expect(info.width > 0);
    try std.testing.expect(info.height > 0);
}
