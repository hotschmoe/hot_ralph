const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const rich = @import("rich_zig");

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
    verbose: bool,
    quiet: bool,
    stdout_buf: [4096]u8 = undefined,

    pub fn init(allocator: mem.Allocator, auto_mode: bool, verbose: bool, quiet: bool) UI {
        return UI{
            .allocator = allocator,
            .stdout = fs.File.stdout(),
            .stdin = fs.File.stdin(),
            .auto_mode = auto_mode,
            .verbose = verbose,
            .quiet = quiet,
        };
    }

    fn getWriter(self: *UI) fs.File.Writer {
        return self.stdout.writer(&self.stdout_buf);
    }

    fn flushWriter(_: *UI, writer: *fs.File.Writer) void {
        writer.interface.flush() catch {};
    }

    pub fn displayTask(self: *UI, task: Task, ready_count: usize, blocked_count: usize) !void {
        if (self.quiet) return;

        var writer = self.getWriter();
        const w = &writer.interface;
        try w.writeAll("\n");

        // Build content with styled priority
        const priority_color: []const u8 = switch (task.priority) {
            0 => "red",
            1 => "yellow",
            2 => "cyan",
            else => "dim",
        };

        // Format priority line with color markup
        const priority_line = try std.fmt.allocPrint(self.allocator, "[bold {s}]P{d}[/] | Ready: {d} | Blocked: {d}", .{
            priority_color,
            task.priority,
            ready_count,
            blocked_count,
        });
        defer self.allocator.free(priority_line);

        // Build tags line if present
        var tags_line: ?[]const u8 = null;
        if (task.tags.len > 0) {
            var tags_buf: std.ArrayList(u8) = .empty;
            defer tags_buf.deinit(self.allocator);
            try tags_buf.appendSlice(self.allocator, "Tags: ");
            for (task.tags, 0..) |tag, i| {
                if (i > 0) try tags_buf.appendSlice(self.allocator, ", ");
                try tags_buf.appendSlice(self.allocator, tag);
            }
            tags_line = try tags_buf.toOwnedSlice(self.allocator);
        }
        defer if (tags_line) |t| self.allocator.free(t);

        // Build the body content
        var body_parts: std.ArrayList(u8) = .empty;
        defer body_parts.deinit(self.allocator);

        try body_parts.appendSlice(self.allocator, priority_line);
        if (tags_line) |t| {
            try body_parts.appendSlice(self.allocator, "\n");
            try body_parts.appendSlice(self.allocator, t);
        }
        if (task.description) |desc| {
            try body_parts.appendSlice(self.allocator, "\n\n");
            try body_parts.appendSlice(self.allocator, desc);
        }

        // Create the title with ID
        const title = try std.fmt.allocPrint(self.allocator, "TASK: {s} [{s}]", .{ task.title, task.id });
        defer self.allocator.free(title);

        // Create and render the panel
        var panel = rich.renderables.Panel.fromText(self.allocator, body_parts.items);
        panel = panel.withTitle(title).rounded();

        const segments = try panel.render(80, self.allocator);
        defer self.allocator.free(segments);

        for (segments) |segment| {
            try w.writeAll(segment.text);
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

    pub fn countdownWithExitCheck(self: *UI, seconds: u32, exit_monitor: anytype) !bool {
        if (self.auto_mode) {
            return true;
        }

        var remaining: u32 = seconds;
        while (remaining > 0) : (remaining -= 1) {
            // Check for exit request
            if (exit_monitor.shouldExit()) {
                var writer = self.getWriter();
                try writer.interface.writeAll("\r                                                        \r");
                self.flushWriter(&writer);
                return false;
            }

            var writer = self.getWriter();
            try writer.interface.print("\rNext task in {d} seconds... (press 'e' to exit after current task)", .{remaining});
            self.flushWriter(&writer);

            std.Thread.sleep(std.time.ns_per_s);
        }

        // Final check before continuing
        if (exit_monitor.shouldExit()) {
            var writer = self.getWriter();
            try writer.interface.writeAll("\r                                                        \r");
            self.flushWriter(&writer);
            return false;
        }

        var writer = self.getWriter();
        try writer.interface.writeAll("\r                                                        \r");
        self.flushWriter(&writer);
        return true;
    }

    pub fn status(self: *UI, message: []const u8) !void {
        if (self.quiet) return;

        var writer = self.getWriter();
        const timestamp = self.getTimestamp();
        // Green bold for success status
        try writer.interface.print("\x1b[1;32m[{s}]\x1b[0m {s}\n", .{ timestamp, message });
        self.flushWriter(&writer);
    }

    pub fn statusFmt(self: *UI, comptime fmt: []const u8, args: anytype) !void {
        if (self.quiet) return;

        var writer = self.getWriter();
        const w = &writer.interface;
        const timestamp = self.getTimestamp();
        // Green bold for timestamp
        try w.print("\x1b[1;32m[{s}]\x1b[0m ", .{timestamp});
        try w.print(fmt, args);
        try w.writeAll("\n");
        self.flushWriter(&writer);
    }

    pub fn err(self: *UI, message: []const u8) !void {
        // Errors always shown even in quiet mode
        var writer = self.getWriter();
        // Red bold for errors
        try writer.interface.print("\x1b[1;31mERROR:\x1b[0m {s}\n", .{message});
        self.flushWriter(&writer);
    }

    pub fn errFmt(self: *UI, comptime fmt: []const u8, args: anytype) !void {
        // Errors always shown even in quiet mode
        var writer = self.getWriter();
        const w = &writer.interface;
        // Red bold for errors
        try w.writeAll("\x1b[1;31mERROR:\x1b[0m ");
        try w.print(fmt, args);
        try w.writeAll("\n");
        self.flushWriter(&writer);
    }

    pub fn warn(self: *UI, message: []const u8) !void {
        if (self.quiet) return;

        var writer = self.getWriter();
        // Yellow bold for warnings
        try writer.interface.print("\x1b[1;33mWARN:\x1b[0m {s}\n", .{message});
        self.flushWriter(&writer);
    }

    pub fn info(self: *UI, message: []const u8) !void {
        if (self.quiet) return;

        var writer = self.getWriter();
        // Dim for info
        try writer.interface.print("\x1b[2m{s}\x1b[0m\n", .{message});
        self.flushWriter(&writer);
    }

    pub fn displayAllTasks(self: *UI, tasks: []const Task) !void {
        if (self.quiet) return;

        var writer = self.getWriter();
        const w = &writer.interface;

        try w.writeAll("\n");

        // Create table with columns using builder pattern
        var table = rich.renderables.Table.init(self.allocator);
        defer table.deinit();

        _ = table.withColumn(rich.renderables.Column.init("#").withJustify(.center).withStyle(rich.Style.empty.dim()));
        _ = table.withColumn(rich.renderables.Column.init("ID").withStyle(rich.Style.empty.fg(rich.Color.cyan)));
        _ = table.withColumn(rich.renderables.Column.init("Title").withStyle(rich.Style.empty.bold()));
        _ = table.withColumn(rich.renderables.Column.init("Pri").withJustify(.center));
        _ = table.withColumn(rich.renderables.Column.init("Tags").withStyle(rich.Style.empty.dim()));

        for (tasks, 0..) |task, i| {
            // Build row number
            const num = std.fmt.allocPrint(self.allocator, "{d}", .{i + 1}) catch continue;
            defer self.allocator.free(num);

            // Build priority string
            const pri = std.fmt.allocPrint(self.allocator, "{d}", .{task.priority}) catch continue;
            defer self.allocator.free(pri);

            // Build tags string
            var tags_buf: std.ArrayList(u8) = .empty;
            defer tags_buf.deinit(self.allocator);
            for (task.tags, 0..) |tag, j| {
                if (j > 0) tags_buf.appendSlice(self.allocator, ", ") catch {};
                tags_buf.appendSlice(self.allocator, tag) catch {};
            }
            const tags_str = tags_buf.toOwnedSlice(self.allocator) catch "";
            defer if (tags_str.len > 0) self.allocator.free(tags_str);

            // Truncate title if too long
            const max_title_len: usize = 40;
            const title_display = if (task.title.len > max_title_len)
                task.title[0..max_title_len]
            else
                task.title;

            table.addRow(&.{ num, task.id, title_display, pri, tags_str }) catch {};
        }

        _ = table.withBoxStyle(rich.box.BoxStyle.rounded);
        _ = table.withTitle("All Ready Tasks");

        const segments = table.render(100, self.allocator) catch {
            try w.writeAll("=== All Ready Tasks ===\n");
            self.flushWriter(&writer);
            return;
        };
        defer self.allocator.free(segments);

        for (segments) |segment| {
            try w.writeAll(segment.text);
        }

        try w.writeAll("\n");
        self.flushWriter(&writer);
    }

    pub fn displayComplete(self: *UI, tasks_completed: usize) !void {
        var writer = self.getWriter();
        const w = &writer.interface;

        try w.writeAll("\n");

        // Build body content
        const body = std.fmt.allocPrint(self.allocator, "[bold green]Tasks completed: {d}[/]", .{tasks_completed}) catch {
            try w.print("=== Session Complete ===\nTasks completed: {d}\n", .{tasks_completed});
            self.flushWriter(&writer);
            return;
        };
        defer self.allocator.free(body);

        // Create panel with double border
        var panel = rich.renderables.Panel.fromText(self.allocator, body);
        panel = panel.withTitle("Session Complete").double();

        const segments = panel.render(50, self.allocator) catch {
            try w.print("=== Session Complete ===\nTasks completed: {d}\n", .{tasks_completed});
            self.flushWriter(&writer);
            return;
        };
        defer self.allocator.free(segments);

        for (segments) |segment| {
            try w.writeAll(segment.text);
        }

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

    fn getTimestamp(_: *UI) [8]u8 {
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
    const ui = UI.init(allocator, false, false, false);
    try std.testing.expect(!ui.auto_mode);
    try std.testing.expect(!ui.verbose);
    try std.testing.expect(!ui.quiet);
}

test "UI - auto mode returns defaults" {
    const allocator = std.testing.allocator;
    var ui = UI.init(allocator, true, false, false);

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
