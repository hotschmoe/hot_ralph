//! Log Cleaner for Claude session logs
//!
//! Cleans raw JSONL session logs by filtering out streaming noise
//! and optionally converting to TOON format for efficient LLM consumption.
//!
//! Two output modes:
//! - JSONL: Cleaned JSON lines (~30x compression)
//! - TOON: Cleaned + converted via toon_zig (~35-40x compression)

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;
const toon = @import("toon");

pub const OutputFormat = enum {
    jsonl,
    toon,
};

pub const CleanerOptions = struct {
    format: OutputFormat = .toon,
    preserve_unknown: bool = true,
};

pub const CleanStats = struct {
    input_lines: usize = 0,
    output_lines: usize = 0,
    dropped_stream: usize = 0,
    dropped_protocol: usize = 0,
    parse_errors: usize = 0,
};

pub const CleanerError = Allocator.Error || fs.File.OpenError || fs.File.WriteError;

/// Patterns that indicate streaming noise (should be dropped)
const drop_patterns = [_][]const u8{
    "stream_event",
    "content_block_delta",
    "message_delta",
    "content_block_start",
    "content_block_stop",
    "message_start",
    "message_stop",
    "ping",
};

/// Patterns that indicate semantic events (should be kept)
const keep_patterns = [_][]const u8{
    "init",
    "system",
    "assistant",
    "user",
    "error",
    "result",
    "tool_use",
    "tool_result",
};

/// Check if an event type should be dropped (streaming noise)
fn shouldDrop(type_str: []const u8) bool {
    for (drop_patterns) |pattern| {
        if (mem.indexOf(u8, type_str, pattern) != null) {
            return true;
        }
    }
    return false;
}

/// Check if an event type is a known semantic event
fn isKnownSemantic(type_str: []const u8) bool {
    for (keep_patterns) |pattern| {
        if (mem.indexOf(u8, type_str, pattern) != null) {
            return true;
        }
    }
    return false;
}

/// Parse a JSON line and extract the type field
fn extractType(allocator: Allocator, line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const type_val = root.object.get("type") orelse return null;
    if (type_val != .string) return null;

    return allocator.dupe(u8, type_val.string) catch null;
}

/// Clean raw JSONL content and return cleaned content with stats
pub fn cleanSession(
    allocator: Allocator,
    raw_jsonl: []const u8,
    options: CleanerOptions,
) !struct { content: []const u8, stats: CleanStats } {
    var stats = CleanStats{};
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    var line_iter = mem.splitScalar(u8, raw_jsonl, '\n');

    while (line_iter.next()) |line| {
        stats.input_lines += 1;

        // Skip empty lines
        if (line.len == 0) continue;

        // Skip very short lines (protocol pings, etc.)
        if (line.len < 30) {
            stats.dropped_protocol += 1;
            continue;
        }

        // Try to extract the type field
        const type_str = extractType(allocator, line);
        defer if (type_str) |t| allocator.free(t);

        if (type_str) |event_type| {
            // Check if this is streaming noise
            if (shouldDrop(event_type)) {
                stats.dropped_stream += 1;
                continue;
            }

            // Keep known semantic events
            if (isKnownSemantic(event_type)) {
                try appendLine(allocator, &output, line, options);
                stats.output_lines += 1;
                continue;
            }

            // Unknown type with sufficient payload - preserve if configured
            if (options.preserve_unknown and line.len > 50) {
                try appendLine(allocator, &output, line, options);
                stats.output_lines += 1;
                continue;
            }

            // Unknown type with small payload - likely noise
            stats.dropped_protocol += 1;
        } else {
            // Parse error - preserve as comment if it has content
            stats.parse_errors += 1;
            if (line.len > 10) {
                const error_line = try std.fmt.allocPrint(
                    allocator,
                    "# PARSE_ERROR: {s}",
                    .{if (line.len > 100) line[0..100] else line},
                );
                defer allocator.free(error_line);
                try output.appendSlice(allocator, error_line);
                try output.append(allocator, '\n');
                stats.output_lines += 1;
            }
        }
    }

    return .{
        .content = try output.toOwnedSlice(allocator),
        .stats = stats,
    };
}

/// Append a line to output, converting to TOON if configured
fn appendLine(
    allocator: Allocator,
    output: *std.ArrayListUnmanaged(u8),
    json_line: []const u8,
    options: CleanerOptions,
) !void {
    if (options.format == .toon) {
        const toon_content = toon.jsonToToon(allocator, json_line) catch {
            // Fall back to JSON if TOON conversion fails
            try output.appendSlice(allocator, json_line);
            try output.append(allocator, '\n');
            return;
        };
        defer allocator.free(toon_content);
        try output.appendSlice(allocator, toon_content);
        // TOON already has trailing newline
        if (toon_content.len == 0 or toon_content[toon_content.len - 1] != '\n') {
            try output.append(allocator, '\n');
        }
    } else {
        try output.appendSlice(allocator, json_line);
        try output.append(allocator, '\n');
    }
}

/// Clean a session log file and write to output file
pub fn cleanSessionFile(
    allocator: Allocator,
    input_path: []const u8,
    output_path: []const u8,
    options: CleanerOptions,
) !CleanStats {
    // Read input file
    const input_file = try fs.openFileAbsolute(input_path, .{});
    defer input_file.close();

    const raw_content = try input_file.readToEndAlloc(allocator, 50 * 1024 * 1024); // 50MB max
    defer allocator.free(raw_content);

    // Clean the content
    const result = try cleanSession(allocator, raw_content, options);
    defer allocator.free(result.content);

    // Write output file
    const output_file = try fs.createFileAbsolute(output_path, .{});
    defer output_file.close();

    try output_file.writeAll(result.content);

    return result.stats;
}

/// Generate the cleaned output path from an input path
pub fn generateCleanedPath(allocator: Allocator, input_path: []const u8, format: OutputFormat) ![]const u8 {
    const extension = switch (format) {
        .toon => ".toon",
        .jsonl => ".cleaned.jsonl",
    };

    // Remove existing extension if present
    const base = if (mem.lastIndexOf(u8, input_path, ".")) |dot_pos|
        input_path[0..dot_pos]
    else
        input_path;

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, extension });
}

/// Generate timestamped log path with format: YYYYMMDD_HHMMSS_{label}.md
pub fn generateLogPath(
    allocator: Allocator,
    output_dir: []const u8,
    label: []const u8,
) ![]const u8 {
    const ts = std.time.timestamp();

    // Convert to datetime components
    const epoch_seconds: u64 = @intCast(ts);
    const days_since_epoch = epoch_seconds / 86400;
    const seconds_in_day = epoch_seconds % 86400;

    const hours: u8 = @intCast(seconds_in_day / 3600);
    const minutes: u8 = @intCast((seconds_in_day % 3600) / 60);
    const seconds: u8 = @intCast(seconds_in_day % 60);

    // Calculate date from days since epoch
    var remaining_days = days_since_epoch;
    var year: u16 = 1970;
    while (true) {
        const days_in_year: u64 = if (isLeapYear(@intCast(year))) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u8 = 1;
    for (days_in_month, 0..) |days, i| {
        var d = days;
        if (i == 1 and isLeapYear(@intCast(year))) d += 1;
        if (remaining_days < d) break;
        remaining_days -= d;
        month += 1;
    }
    const day: u8 = @intCast(remaining_days + 1);

    const filename = try std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{s}.md",
        .{ year, month, day, hours, minutes, seconds, label },
    );
    defer allocator.free(filename);

    return fs.path.join(allocator, &.{ output_dir, filename });
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

/// One-shot: raw JSON -> clean (filter noise) -> save to .md file
/// Uses cleaned JSONL format (not TOON) so introspection can read it
pub fn saveCleanLog(
    allocator: Allocator,
    raw_json: []const u8,
    output_path: []const u8,
) !CleanStats {
    const result = try cleanSession(allocator, raw_json, .{ .format = .jsonl });
    defer allocator.free(result.content);

    const file = try fs.createFileAbsolute(output_path, .{});
    defer file.close();
    try file.writeAll(result.content);

    return result.stats;
}

// ============================================================================
// Tests
// ============================================================================

test "shouldDrop stream events" {
    try std.testing.expect(shouldDrop("stream_event"));
    try std.testing.expect(shouldDrop("content_block_delta"));
    try std.testing.expect(shouldDrop("message_delta"));
    try std.testing.expect(shouldDrop("message_start"));
    try std.testing.expect(shouldDrop("message_stop"));
    try std.testing.expect(shouldDrop("ping"));
}

test "shouldDrop preserves semantic events" {
    try std.testing.expect(!shouldDrop("system"));
    try std.testing.expect(!shouldDrop("assistant"));
    try std.testing.expect(!shouldDrop("user"));
    try std.testing.expect(!shouldDrop("tool_result"));
    try std.testing.expect(!shouldDrop("error"));
}

test "isKnownSemantic identifies semantic events" {
    try std.testing.expect(isKnownSemantic("system"));
    try std.testing.expect(isKnownSemantic("assistant_message"));
    try std.testing.expect(isKnownSemantic("user_input"));
    try std.testing.expect(isKnownSemantic("tool_result"));
    try std.testing.expect(isKnownSemantic("error"));
}

test "isKnownSemantic rejects unknown" {
    try std.testing.expect(!isKnownSemantic("random_event"));
    try std.testing.expect(!isKnownSemantic("something_else"));
}

test "extractType parses type field" {
    const allocator = std.testing.allocator;

    const type_str = extractType(allocator, "{\"type\":\"system\",\"data\":{}}");
    try std.testing.expect(type_str != null);
    defer allocator.free(type_str.?);
    try std.testing.expectEqualStrings("system", type_str.?);
}

test "extractType returns null for missing type" {
    const allocator = std.testing.allocator;

    const type_str = extractType(allocator, "{\"data\":{}}");
    try std.testing.expect(type_str == null);
}

test "extractType returns null for invalid JSON" {
    const allocator = std.testing.allocator;

    const type_str = extractType(allocator, "not json");
    try std.testing.expect(type_str == null);
}

test "cleanSession filters streaming noise" {
    const allocator = std.testing.allocator;

    const input =
        \\{"type":"stream_event","data":"noise_noise_noise_noise_noise"}
        \\{"type":"system","content":"keep this one here please"}
        \\{"type":"content_block_delta","delta":"more noise here"}
        \\{"type":"assistant","message":"also keep this one"}
        \\{"type":"message_start","data":"start_noise_here_too"}
    ;

    const result = try cleanSession(allocator, input, .{ .format = .jsonl });
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 5), result.stats.input_lines);
    try std.testing.expectEqual(@as(usize, 2), result.stats.output_lines);
    try std.testing.expectEqual(@as(usize, 3), result.stats.dropped_stream);
}

test "cleanSession handles empty input" {
    const allocator = std.testing.allocator;

    const result = try cleanSession(allocator, "", .{});
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 0), result.stats.output_lines);
    try std.testing.expectEqualStrings("", result.content);
}

test "cleanSession preserves unknown with large payload" {
    const allocator = std.testing.allocator;

    // Line with >50 bytes and unknown type
    const input =
        \\{"type":"unknown_event","data":"this is a long enough payload to be preserved"}
    ;

    const result = try cleanSession(allocator, input, .{ .format = .jsonl, .preserve_unknown = true });
    defer allocator.free(result.content);

    try std.testing.expectEqual(@as(usize, 1), result.stats.output_lines);
}

test "generateCleanedPath toon format" {
    const allocator = std.testing.allocator;

    const path = try generateCleanedPath(allocator, "/path/to/session.jsonl", .toon);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/path/to/session.toon", path);
}

test "generateCleanedPath jsonl format" {
    const allocator = std.testing.allocator;

    const path = try generateCleanedPath(allocator, "/path/to/session.jsonl", .jsonl);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/path/to/session.cleaned.jsonl", path);
}

test "generateCleanedPath no extension" {
    const allocator = std.testing.allocator;

    const path = try generateCleanedPath(allocator, "/path/to/session", .toon);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/path/to/session.toon", path);
}

test "generateLogPath creates timestamped path" {
    const allocator = std.testing.allocator;

    const path = try generateLogPath(allocator, "/output", "task_abc");
    defer allocator.free(path);

    // Verify format: /output/YYYYMMDD_HHMMSS_task_abc.md
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, path, "/output/"));
    try std.testing.expect(std.mem.endsWith(u8, path, "_task_abc.md"));
    // Should have timestamp portion: 8 digits + _ + 6 digits = 15 chars
    try std.testing.expect(path.len >= "/output/".len + 15 + "_task_abc.md".len);
}

test "isLeapYear" {
    try std.testing.expect(isLeapYear(2000)); // divisible by 400
    try std.testing.expect(!isLeapYear(1900)); // divisible by 100 but not 400
    try std.testing.expect(isLeapYear(2024)); // divisible by 4
    try std.testing.expect(!isLeapYear(2023)); // not divisible by 4
}
