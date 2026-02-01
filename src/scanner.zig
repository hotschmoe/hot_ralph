const std = @import("std");
const mem = std.mem;
const fs = std.fs;

pub const TaskLogEntry = struct {
    filename: []const u8,
    content: []const u8,
    timestamp: i64,
};

pub const Scanner = struct {
    allocator: mem.Allocator,
    base_dir: []const u8,

    pub fn init(allocator: mem.Allocator, base_dir: []const u8) Scanner {
        return Scanner{
            .allocator = allocator,
            .base_dir = base_dir,
        };
    }

    /// Scans .hot_ralph/ for files matching *_task_*.toon or other log patterns.
    /// Returns content of the most recent N task log files sorted by timestamp descending.
    pub fn scanTaskLogs(self: *Scanner, count: usize) ![][]const u8 {
        const hot_ralph_dir = try fs.path.join(self.allocator, &.{ self.base_dir, ".hot_ralph" });
        defer self.allocator.free(hot_ralph_dir);

        var dir = fs.openDirAbsolute(hot_ralph_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close();

        var entries: std.ArrayList(TaskLogEntry) = .empty;
        defer {
            for (entries.items) |entry| {
                self.allocator.free(entry.filename);
            }
            entries.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!mem.endsWith(u8, entry.name, ".toon")) continue;
            if (!matchesLogPattern(entry.name)) continue;

            const timestamp = parseTimestamp(entry.name) orelse continue;

            const filename = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(filename);

            try entries.append(self.allocator, .{
                .filename = filename,
                .content = "", // populated later
                .timestamp = timestamp,
            });
        }

        // Sort by timestamp descending
        mem.sort(TaskLogEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: TaskLogEntry, b: TaskLogEntry) bool {
                return a.timestamp > b.timestamp;
            }
        }.lessThan);

        // Take only the first 'count' entries and load their content
        const take_count = @min(count, entries.items.len);

        var result = std.ArrayList([]const u8).initCapacity(self.allocator, take_count) catch {
            return &.{};
        };
        errdefer {
            for (result.items) |content| self.allocator.free(content);
            result.deinit(self.allocator);
        }

        for (entries.items[0..take_count]) |entry| {
            const file_path = fs.path.join(self.allocator, &.{ hot_ralph_dir, entry.filename }) catch continue;
            defer self.allocator.free(file_path);

            const content = self.readFileLimited(file_path, 1024 * 1024) catch continue;
            result.appendAssumeCapacity(content);
        }

        return result.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Scans .claude/skills/ for *.md files.
    pub fn scanSkills(self: *Scanner) ![][]const u8 {
        const skills_dir = try fs.path.join(self.allocator, &.{ self.base_dir, ".claude", "skills" });
        defer self.allocator.free(skills_dir);

        return self.scanDirectory(skills_dir, ".md");
    }

    /// Scans .claude/agents/ for *.md files.
    pub fn scanAgents(self: *Scanner) ![][]const u8 {
        const agents_dir = try fs.path.join(self.allocator, &.{ self.base_dir, ".claude", "agents" });
        defer self.allocator.free(agents_dir);

        return self.scanDirectory(agents_dir, ".md");
    }

    /// Generic directory scanner returning filenames with given extension.
    fn scanDirectory(self: *Scanner, dir_path: []const u8, extension: []const u8) ![][]const u8 {
        var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close();

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| {
                self.allocator.free(item);
            }
            result.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!mem.endsWith(u8, entry.name, extension)) continue;

            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);
            try result.append(self.allocator, name);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Reads file content up to max_size bytes.
    fn readFileLimited(self: *Scanner, path: []const u8, max_size: usize) ![]const u8 {
        const file = try fs.openFileAbsolute(path, .{});
        defer file.close();

        const stat = try file.stat();
        const size = @min(stat.size, max_size);

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        if (bytes_read < size) {
            return self.allocator.realloc(buffer, bytes_read) catch buffer[0..bytes_read];
        }

        return buffer;
    }

    /// Frees a list of allocated strings (task logs, filenames, etc).
    pub fn freeStringList(self: *Scanner, list: [][]const u8) void {
        for (list) |item| {
            self.allocator.free(item);
        }
        if (list.len > 0) {
            self.allocator.free(list);
        }
    }

    /// Alias for freeStringList for API clarity when freeing task logs.
    pub const freeTaskLogs = freeStringList;
};

/// Parses timestamp from filename with format YYYYMMDD_HHMMSS_*.
/// Returns Unix timestamp or null if format doesn't match.
pub fn parseTimestamp(filename: []const u8) ?i64 {
    // Expected format: YYYYMMDD_HHMMSS_rest.md
    // Need at least 15 chars for timestamp portion
    if (filename.len < 15) return null;

    // Check for underscore separator
    if (filename[8] != '_') return null;

    // Parse date components
    const year = std.fmt.parseInt(i32, filename[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, filename[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u8, filename[6..8], 10) catch return null;

    // Parse time components
    const hour = std.fmt.parseInt(u8, filename[9..11], 10) catch return null;
    const minute = std.fmt.parseInt(u8, filename[11..13], 10) catch return null;
    const second = std.fmt.parseInt(u8, filename[13..15], 10) catch return null;

    // Validate ranges
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23) return null;
    if (minute > 59) return null;
    if (second > 59) return null;

    // Convert to epoch seconds (simplified calculation)
    const epoch_day = epochDayFromDate(year, month, day) orelse return null;
    const day_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return epoch_day * 86400 + day_seconds;
}

/// Checks if filename matches log patterns (task, plan_mode, simplify, introspection)
pub fn matchesLogPattern(filename: []const u8) bool {
    if (!mem.endsWith(u8, filename, ".toon")) return false;

    // Match various log types: task, plan_mode, plan_simplify, introspection
    return mem.indexOf(u8, filename, "_task_") != null or
        mem.indexOf(u8, filename, "_plan_") != null or
        mem.indexOf(u8, filename, "_simplify") != null or
        mem.indexOf(u8, filename, "_introspection") != null;
}

/// Calculates days since Unix epoch for a given date.
fn epochDayFromDate(year: i32, month: u8, day: u8) ?i64 {
    if (year < 1970) return null;

    var days: i64 = 0;

    // Add days for complete years
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }

    // Add days for complete months in current year
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += days_in_month[m - 1];
        if (m == 2 and isLeapYear(year)) {
            days += 1;
        }
    }

    // Add days in current month
    days += day - 1;

    return days;
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

// Tests

test "parseTimestamp - valid filename" {
    const timestamp = parseTimestamp("20250130_143022_task_abc.toon");
    try std.testing.expect(timestamp != null);

    // Verify the timestamp is reasonable (after 2025-01-01)
    const jan_2025: i64 = 1735689600; // approx 2025-01-01
    try std.testing.expect(timestamp.? > jan_2025);
}

test "parseTimestamp - invalid filename too short" {
    try std.testing.expect(parseTimestamp("short.md") == null);
}

test "parseTimestamp - invalid filename bad format" {
    try std.testing.expect(parseTimestamp("notadate_task_x.md") == null);
}

test "parseTimestamp - missing underscore separator" {
    try std.testing.expect(parseTimestamp("20250130X143022_task.md") == null);
}

test "matchesLogPattern - valid patterns" {
    try std.testing.expect(matchesLogPattern("20250130_143022_task_abc.toon"));
    try std.testing.expect(matchesLogPattern("20250130_143022_plan_mode.toon"));
    try std.testing.expect(matchesLogPattern("20250130_143022_plan_simplify.toon"));
    try std.testing.expect(matchesLogPattern("20250130_143022_introspection.toon"));
    try std.testing.expect(matchesLogPattern("anything_task_anything.toon"));
}

test "matchesLogPattern - invalid patterns" {
    try std.testing.expect(!matchesLogPattern("task.toon"));
    try std.testing.expect(!matchesLogPattern("20250130_143022_abc.toon"));
    try std.testing.expect(!matchesLogPattern("_task_.txt"));
    try std.testing.expect(!matchesLogPattern("notask.md"));
    try std.testing.expect(!matchesLogPattern("20250130_143022_task_abc.md")); // old format
}

test "epochDayFromDate - basic calculation" {
    // 1970-01-01 should be day 0
    const day0 = epochDayFromDate(1970, 1, 1);
    try std.testing.expect(day0 != null);
    try std.testing.expectEqual(@as(i64, 0), day0.?);

    // 1970-01-02 should be day 1
    const day1 = epochDayFromDate(1970, 1, 2);
    try std.testing.expect(day1 != null);
    try std.testing.expectEqual(@as(i64, 1), day1.?);
}

test "epochDayFromDate - year before 1970" {
    try std.testing.expect(epochDayFromDate(1969, 12, 31) == null);
}

test "isLeapYear" {
    try std.testing.expect(isLeapYear(2000)); // divisible by 400
    try std.testing.expect(!isLeapYear(1900)); // divisible by 100 but not 400
    try std.testing.expect(isLeapYear(2024)); // divisible by 4
    try std.testing.expect(!isLeapYear(2023)); // not divisible by 4
}

test "Scanner - scan nonexistent directory returns empty" {
    const allocator = std.testing.allocator;
    var scanner = Scanner.init(allocator, "/nonexistent/path/that/does/not/exist");

    const skills = try scanner.scanSkills();
    try std.testing.expectEqual(@as(usize, 0), skills.len);

    const agents = try scanner.scanAgents();
    try std.testing.expectEqual(@as(usize, 0), agents.len);

    const logs = try scanner.scanTaskLogs(10);
    try std.testing.expectEqual(@as(usize, 0), logs.len);
}
