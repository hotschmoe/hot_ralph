const std = @import("std");
const mem = std.mem;
const fs = std.fs;

pub const ExecuteChoice = enum {
    yes,
    no,
    skip,
    view_all,
    quit,
};

pub const SuccessChoice = enum {
    yes,
    no,
    retry,
};

pub const Task = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    priority: i32,
    tags: []const []const u8,
    blocks: []const []const u8 = &.{},
};

pub const UI = struct {
    allocator: mem.Allocator,
    stdout: fs.File,
    stdin: fs.File,
    auto_mode: bool,
    stdout_buf: [4096]u8 = undefined,

    pub fn init(allocator: mem.Allocator, auto_mode: bool) UI {
        return UI{
            .allocator = allocator,
            .stdout = fs.File.stdout(),
            .stdin = fs.File.stdin(),
            .auto_mode = auto_mode,
        };
    }

    fn getWriter(self: *UI) fs.File.Writer {
        return self.stdout.writer(&self.stdout_buf);
    }

    fn flushWriter(_: *UI, writer: *fs.File.Writer) void {
        writer.interface.flush() catch {};
    }

    pub fn displayTask(self: *UI, task: Task, ready_count: usize, blocked_count: usize) !void {
        var writer = self.getWriter();
        const w = &writer.interface;

        try w.writeAll("\n");
        try w.writeAll("---------------------------------------------------------------\n");
        try w.print("  TASK: {s}\n", .{task.title});
        try w.print("  ID: {s} | Priority: {d} | Ready: {d} | Blocked: {d}\n", .{
            task.id,
            task.priority,
            ready_count,
            blocked_count,
        });

        if (task.tags.len > 0) {
            try w.writeAll("  Tags: ");
            for (task.tags, 0..) |tag, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}", .{tag});
            }
            try w.writeAll("\n");
        }

        if (task.blocks.len > 0) {
            try w.writeAll("  Blocks: ");
            for (task.blocks, 0..) |blocked_id, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}", .{blocked_id});
            }
            try w.writeAll("\n");
        }

        try w.writeAll("---------------------------------------------------------------\n");

        if (task.description) |desc| {
            try w.print("{s}\n", .{desc});
            try w.writeAll("---------------------------------------------------------------\n");
        }

        self.flushWriter(&writer);
    }

    pub fn promptExecute(self: *UI) !ExecuteChoice {
        if (self.auto_mode) {
            return .yes;
        }

        var writer = self.getWriter();
        try writer.interface.writeAll("\nExecute this task? [Y/n/s(kip)/v(iew all)/q(uit)] ");
        self.flushWriter(&writer);

        const choice = try self.readSingleChar();

        return switch (choice) {
            'y', 'Y', '\n', '\r' => .yes,
            'n', 'N' => .no,
            's', 'S' => .skip,
            'v', 'V' => .view_all,
            'q', 'Q' => .quit,
            else => .yes,
        };
    }

    pub fn promptSuccess(self: *UI) !SuccessChoice {
        if (self.auto_mode) {
            return .yes;
        }

        var writer = self.getWriter();
        try writer.interface.writeAll("\nTask completed successfully. Accept? [Y/n/r(etry)] ");
        self.flushWriter(&writer);

        const choice = try self.readSingleChar();

        return switch (choice) {
            'y', 'Y', '\n', '\r' => .yes,
            'n', 'N' => .no,
            'r', 'R' => .retry,
            else => .yes,
        };
    }

    pub fn promptYesNo(self: *UI, message: []const u8, default_yes: bool) !bool {
        if (self.auto_mode) {
            return default_yes;
        }

        var writer = self.getWriter();
        const w = &writer.interface;
        if (default_yes) {
            try w.print("{s} [Y/n] ", .{message});
        } else {
            try w.print("{s} [y/N] ", .{message});
        }
        self.flushWriter(&writer);

        const choice = try self.readSingleChar();

        return switch (choice) {
            'y', 'Y' => true,
            'n', 'N' => false,
            '\n', '\r' => default_yes,
            else => default_yes,
        };
    }

    pub fn promptResume(self: *UI, task_id: []const u8) !bool {
        if (self.auto_mode) {
            return true;
        }

        var writer = self.getWriter();
        const w = &writer.interface;
        try w.print("\nFound interrupted task: {s}\n", .{task_id});
        try w.writeAll("Resume? [Y/n] ");
        self.flushWriter(&writer);

        const choice = try self.readSingleChar();

        return switch (choice) {
            'n', 'N' => false,
            else => true,
        };
    }

    pub fn countdown(self: *UI, seconds: u32) !bool {
        if (self.auto_mode) {
            return true;
        }

        var remaining: u32 = seconds;
        while (remaining > 0) : (remaining -= 1) {
            var writer = self.getWriter();
            try writer.interface.print("\rNext task in {d} seconds... (Ctrl+C to exit)", .{remaining});
            self.flushWriter(&writer);

            std.Thread.sleep(std.time.ns_per_s);
        }

        var writer = self.getWriter();
        try writer.interface.writeAll("\r                                              \r");
        self.flushWriter(&writer);
        return true;
    }

    pub fn status(self: *UI, message: []const u8) !void {
        var writer = self.getWriter();
        const timestamp = self.getTimestamp();
        try writer.interface.print("[{s}] {s}\n", .{ timestamp, message });
        self.flushWriter(&writer);
    }

    pub fn statusFmt(self: *UI, comptime fmt: []const u8, args: anytype) !void {
        var writer = self.getWriter();
        const w = &writer.interface;
        const timestamp = self.getTimestamp();
        try w.print("[{s}] ", .{timestamp});
        try w.print(fmt, args);
        try w.writeAll("\n");
        self.flushWriter(&writer);
    }

    pub fn err(self: *UI, message: []const u8) !void {
        var writer = self.getWriter();
        try writer.interface.print("ERROR: {s}\n", .{message});
        self.flushWriter(&writer);
    }

    pub fn errFmt(self: *UI, comptime fmt: []const u8, args: anytype) !void {
        var writer = self.getWriter();
        const w = &writer.interface;
        try w.writeAll("ERROR: ");
        try w.print(fmt, args);
        try w.writeAll("\n");
        self.flushWriter(&writer);
    }

    pub fn info(self: *UI, message: []const u8) !void {
        var writer = self.getWriter();
        try writer.interface.print("{s}\n", .{message});
        self.flushWriter(&writer);
    }

    pub fn displayAllTasks(self: *UI, tasks: []const Task) !void {
        var writer = self.getWriter();
        const w = &writer.interface;

        try w.writeAll("\n=== All Ready Tasks ===\n\n");

        for (tasks, 0..) |task, i| {
            try w.print("{d}. [{s}] {s} (priority: {d})\n", .{
                i + 1,
                task.id,
                task.title,
                task.priority,
            });
            if (task.description) |desc| {
                const max_len = @min(desc.len, 100);
                try w.print("   {s}{s}\n", .{
                    desc[0..max_len],
                    if (desc.len > 100) "..." else "",
                });
            }
        }

        try w.writeAll("\n");
        self.flushWriter(&writer);
    }

    pub fn displayComplete(self: *UI, tasks_completed: usize) !void {
        var writer = self.getWriter();
        const w = &writer.interface;
        try w.print("\n=== Session Complete ===\n", .{});
        try w.print("Tasks completed: {d}\n", .{tasks_completed});
        self.flushWriter(&writer);
    }

    fn readSingleChar(self: *UI) !u8 {
        var buf: [1]u8 = undefined;
        var stdin_buf: [256]u8 = undefined;
        var reader = self.stdin.reader(&stdin_buf);

        const bytes_read = reader.interface.readSliceShort(&buf) catch {
            return '\n';
        };
        if (bytes_read == 0) {
            return '\n';
        }
        return buf[0];
    }

    fn getTimestamp(self: *UI) [8]u8 {
        _ = self;
        const ts = std.time.timestamp();
        const epoch_seconds: u64 = @intCast(ts);

        const seconds_in_day = epoch_seconds % (24 * 60 * 60);
        const hours = seconds_in_day / 3600;
        const minutes = (seconds_in_day % 3600) / 60;
        const seconds = seconds_in_day % 60;

        var buf: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
            hours,
            minutes,
            seconds,
        }) catch unreachable;

        return buf;
    }
};

pub fn generateOutputFilename(allocator: mem.Allocator, output_dir: []const u8, label: []const u8) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(ts);

    const days_since_epoch = epoch_seconds / (24 * 60 * 60);
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const days_in_year: u64 = if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_months = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u32 = 1;
    for (days_in_months) |dim| {
        if (remaining_days < dim) break;
        remaining_days -= dim;
        month += 1;
    }
    const day: u32 = @intCast(remaining_days + 1);

    const seconds_in_day = epoch_seconds % (24 * 60 * 60);
    const hours: u32 = @intCast(seconds_in_day / 3600);
    const minutes: u32 = @intCast((seconds_in_day % 3600) / 60);
    const seconds: u32 = @intCast(seconds_in_day % 60);

    const filename = try std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{s}.md", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
        label,
    });
    defer allocator.free(filename);

    return try std.fs.path.join(allocator, &.{ output_dir, filename });
}

test "UI - init" {
    const allocator = std.testing.allocator;
    const ui = UI.init(allocator, false);
    try std.testing.expect(!ui.auto_mode);
}

test "UI - auto mode returns defaults" {
    const allocator = std.testing.allocator;
    var ui = UI.init(allocator, true);

    const exec_choice = try ui.promptExecute();
    try std.testing.expect(exec_choice == .yes);

    const success_choice = try ui.promptSuccess();
    try std.testing.expect(success_choice == .yes);

    const yes_no = try ui.promptYesNo("Test?", true);
    try std.testing.expect(yes_no == true);
}

test "generateOutputFilename" {
    const allocator = std.testing.allocator;

    const filename = try generateOutputFilename(allocator, "/tmp/ralph", "task_abc123");
    defer allocator.free(filename);

    try std.testing.expect(mem.indexOf(u8, filename, "task_abc123.md") != null);
    try std.testing.expect(mem.startsWith(u8, filename, "/tmp/ralph"));
}
