const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;

pub const ExitMonitor = struct {
    exit_requested: std.atomic.Value(bool),
    running: std.atomic.Value(bool),
    monitor_thread: ?std.Thread,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExitMonitor {
        return ExitMonitor{
            .exit_requested = std.atomic.Value(bool).init(false),
            .running = std.atomic.Value(bool).init(false),
            .monitor_thread = null,
            .allocator = allocator,
        };
    }

    pub fn start(self: *ExitMonitor) !void {
        if (self.running.load(.acquire)) {
            return;
        }

        self.running.store(true, .release);
        self.monitor_thread = try std.Thread.spawn(.{}, monitorThread, .{self});
    }

    pub fn shouldExit(self: *ExitMonitor) bool {
        return self.exit_requested.load(.acquire);
    }

    pub fn requestExit(self: *ExitMonitor) void {
        self.exit_requested.store(true, .release);
    }

    pub fn stop(self: *ExitMonitor) void {
        self.running.store(false, .release);

        if (self.monitor_thread) |thread| {
            thread.join();
            self.monitor_thread = null;
        }
    }

    pub fn deinit(self: *ExitMonitor) void {
        self.stop();
    }

    fn monitorThread(self: *ExitMonitor) void {
        const stdin = fs.File.stdin();

        while (self.running.load(.acquire)) {
            if (self.pollStdin(stdin)) |char| {
                if (char == 'e' or char == 'E') {
                    self.exit_requested.store(true, .release);
                    return;
                }
            }

            // Sleep briefly to avoid busy-waiting
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn pollStdin(self: *ExitMonitor, stdin: fs.File) ?u8 {
        _ = self;

        if (builtin.os.tag == .windows) {
            return pollStdinWindows(stdin);
        } else {
            return pollStdinPosix(stdin);
        }
    }
};

fn pollStdinWindows(stdin: fs.File) ?u8 {
    // On Windows, check if stdin has data available using WaitForSingleObject
    const windows = std.os.windows;
    const handle = stdin.handle;

    // Wait with 0 timeout (immediate return)
    // WaitForSingleObject returns void on success, error on timeout/abandoned
    windows.WaitForSingleObject(handle, 0) catch {
        // Timeout or error - no data available
        return null;
    };

    // Data available, try to read
    var buf: [1]u8 = undefined;
    var stdin_buf: [256]u8 = undefined;
    var reader = stdin.reader(&stdin_buf);

    const bytes = reader.interface.readSliceShort(&buf) catch return null;
    if (bytes > 0) {
        return buf[0];
    }
    return null;
}

fn pollStdinPosix(stdin: fs.File) ?u8 {
    // On POSIX systems, use poll() to check for available input
    var pollfd = [_]std.posix.pollfd{
        .{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    // Poll with 0 timeout (immediate return)
    const ready = std.posix.poll(&pollfd, 0) catch return null;
    if (ready > 0 and (pollfd[0].revents & std.posix.POLL.IN) != 0) {
        var buf: [1]u8 = undefined;
        var stdin_buf: [256]u8 = undefined;
        var reader = stdin.reader(&stdin_buf);

        const bytes = reader.interface.readSliceShort(&buf) catch return null;
        if (bytes > 0) {
            return buf[0];
        }
    }
    return null;
}

// Tests

test "ExitMonitor - flag starts false" {
    const allocator = std.testing.allocator;
    var monitor = ExitMonitor.init(allocator);
    defer monitor.deinit();

    try std.testing.expect(!monitor.shouldExit());
}

test "ExitMonitor - flag can be set directly" {
    const allocator = std.testing.allocator;
    var monitor = ExitMonitor.init(allocator);
    defer monitor.deinit();

    try std.testing.expect(!monitor.shouldExit());
    monitor.requestExit();
    try std.testing.expect(monitor.shouldExit());
}

test "ExitMonitor - stop clears running flag" {
    const allocator = std.testing.allocator;
    var monitor = ExitMonitor.init(allocator);
    defer monitor.deinit();

    // Initially not running
    try std.testing.expect(!monitor.running.load(.acquire));

    // After stop, still not running
    monitor.stop();
    try std.testing.expect(!monitor.running.load(.acquire));
}

test "ExitMonitor - multiple deinit safe" {
    const allocator = std.testing.allocator;
    var monitor = ExitMonitor.init(allocator);

    monitor.deinit();
    monitor.deinit(); // Should be safe to call twice
}
