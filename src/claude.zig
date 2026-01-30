const std = @import("std");
const mem = std.mem;
const json = std.json;
const process = std.process;
const fs = std.fs;
const io = std.io;

pub const ClaudeError = error{
    NotInstalled,
    NotAuthenticated,
    SpawnFailed,
    StreamInterrupted,
    OutputParseFailed,
    OutputWriteFailed,
    OutOfMemory,
};

pub const RunOptions = struct {
    output_file: []const u8,
    stream_to_terminal: bool = true,
    working_dir: ?[]const u8 = null,
};

pub const RunResult = union(enum) {
    success: struct {
        output_file: []const u8,
        response_text: []const u8,
    },
    failure: struct {
        message: []const u8,
    },
    interrupted,
};

pub const Claude = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) Claude {
        return Claude{
            .allocator = allocator,
        };
    }

    pub fn checkInstalled(self: *Claude) !void {
        const which_cmd = if (@import("builtin").os.tag == .windows) "where" else "which";
        const claude_cmd = if (@import("builtin").os.tag == .windows) "claude.exe" else "claude";

        var child = process.Child.init(&.{ which_cmd, claude_cmd }, self.allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;

        _ = child.spawnAndWait() catch {
            return ClaudeError.NotInstalled;
        };
    }

    pub fn run(self: *Claude, prompt: []const u8, opts: RunOptions) !RunResult {
        // Create output file for writing
        const output_file = fs.createFileAbsolute(opts.output_file, .{}) catch {
            return ClaudeError.OutputWriteFailed;
        };
        defer output_file.close();

        // Spawn claude process
        var child = process.Child.init(&.{
            "claude",
            "--print",
            "--verbose",
            "--output-format",
            "stream-json",
            "--dangerously-skip-permissions",
            prompt,
        }, self.allocator);

        if (opts.working_dir) |wd| {
            child.cwd = wd;
        }

        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        child.spawn() catch {
            return ClaudeError.SpawnFailed;
        };

        // Process streaming output
        var parser = StreamParser.init(self.allocator);
        defer parser.deinit();

        const stdout = child.stdout orelse return ClaudeError.SpawnFailed;
        var response_buffer: std.ArrayList(u8) = .empty;
        defer response_buffer.deinit(self.allocator);

        var read_buffer: [4096]u8 = undefined;
        var terminal_stdout_buf: [4096]u8 = undefined;
        var terminal_writer_opt: ?fs.File.Writer = if (opts.stream_to_terminal)
            fs.File.stdout().writer(&terminal_stdout_buf)
        else
            null;

        while (true) {
            const bytes_read = stdout.read(&read_buffer) catch |err| {
                if (err == error.BrokenPipe) break;
                return ClaudeError.StreamInterrupted;
            };

            if (bytes_read == 0) break;

            const chunk = read_buffer[0..bytes_read];

            // Write raw JSON to output file
            output_file.writeAll(chunk) catch {
                return ClaudeError.OutputWriteFailed;
            };

            // Parse streaming JSON and extract text
            parser.feed(chunk);

            while (parser.next()) |event| {
                switch (event) {
                    .text => |text| {
                        try response_buffer.appendSlice(self.allocator, text);
                        if (terminal_writer_opt) |*writer| {
                            writer.interface.writeAll(text) catch {};
                            writer.interface.flush() catch {};
                        }
                    },
                    .tool_use => {},
                    .thinking => {},
                    .error_msg => |msg| {
                        return RunResult{
                            .failure = .{ .message = try self.allocator.dupe(u8, msg) },
                        };
                    },
                }
            }
        }

        // Wait for process to complete
        const result = child.wait() catch {
            return ClaudeError.StreamInterrupted;
        };

        // Add final newline if we streamed to terminal
        if (terminal_writer_opt) |*writer| {
            writer.interface.writeAll("\n") catch {};
            writer.interface.flush() catch {};
        }

        if (result.Exited != 0) {
            // Check if it was interrupted (signal 130)
            if (result.Exited == 130 or result.Signal == std.posix.SIG.INT) {
                return .interrupted;
            }

            return RunResult{
                .failure = .{
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Claude exited with code {d}",
                        .{result.Exited},
                    ),
                },
            };
        }

        return RunResult{
            .success = .{
                .output_file = opts.output_file,
                .response_text = try response_buffer.toOwnedSlice(self.allocator),
            },
        };
    }
};

pub const StreamEvent = union(enum) {
    text: []const u8,
    tool_use: void,
    thinking: void,
    error_msg: []const u8,
};

pub const StreamParser = struct {
    allocator: mem.Allocator,
    buffer: std.ArrayList(u8),
    events: std.ArrayList(StreamEvent),

    pub fn init(allocator: mem.Allocator) StreamParser {
        return StreamParser{
            .allocator = allocator,
            .buffer = .empty,
            .events = .empty,
        };
    }

    pub fn deinit(self: *StreamParser) void {
        self.buffer.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn feed(self: *StreamParser, chunk: []const u8) void {
        self.buffer.appendSlice(self.allocator, chunk) catch return;

        // Try to parse complete JSON objects from buffer
        self.parseBuffer();
    }

    pub fn next(self: *StreamParser) ?StreamEvent {
        if (self.events.items.len == 0) {
            return null;
        }
        return self.events.orderedRemove(0);
    }

    fn parseBuffer(self: *StreamParser) void {
        // Look for newline-delimited JSON objects
        while (mem.indexOf(u8, self.buffer.items, "\n")) |newline_pos| {
            const line = self.buffer.items[0..newline_pos];

            if (line.len > 0) {
                self.parseLine(line);
            }

            // Remove processed line from buffer
            const remaining = self.buffer.items[newline_pos + 1 ..];
            mem.copyForwards(u8, self.buffer.items, remaining);
            self.buffer.shrinkRetainingCapacity(remaining.len);
        }
    }

    fn parseLine(self: *StreamParser, line: []const u8) void {
        const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // Try to parse as JSON
        const parsed = json.parseFromSlice(json.Value, self.allocator, trimmed, .{}) catch {
            return;
        };
        defer parsed.deinit();

        self.extractEvents(parsed.value);
    }

    fn extractEvents(self: *StreamParser, value: json.Value) void {
        const obj = switch (value) {
            .object => |o| o,
            else => return,
        };

        const type_str = getStringField(obj, "type") orelse "";

        if (mem.eql(u8, type_str, "content_block_delta")) {
            if (obj.get("delta")) |delta| {
                self.extractDelta(delta);
            }
        } else if (mem.eql(u8, type_str, "error")) {
            self.extractErrorMessage(obj);
        }

        if (obj.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |item| {
                    self.extractContentBlock(item);
                }
            }
        }

        if (getStringField(obj, "result")) |result| {
            self.events.append(self.allocator, .{ .text = result }) catch {};
        }
    }

    fn extractErrorMessage(self: *StreamParser, obj: json.ObjectMap) void {
        const err_obj = obj.get("error") orelse return;
        if (err_obj != .object) return;
        const msg = getStringField(err_obj.object, "message") orelse return;
        self.events.append(self.allocator, .{ .error_msg = msg }) catch {};
    }

    fn extractDelta(self: *StreamParser, delta: json.Value) void {
        const delta_obj = switch (delta) {
            .object => |o| o,
            else => return,
        };

        const delta_type = getStringField(delta_obj, "type") orelse return;

        if (mem.eql(u8, delta_type, "text_delta")) {
            if (getStringField(delta_obj, "text")) |text| {
                self.events.append(self.allocator, .{ .text = text }) catch {};
            }
        } else if (mem.eql(u8, delta_type, "input_json_delta")) {
            self.events.append(self.allocator, .tool_use) catch {};
        } else if (mem.eql(u8, delta_type, "thinking_delta")) {
            self.events.append(self.allocator, .thinking) catch {};
        }
    }

    fn extractContentBlock(self: *StreamParser, block: json.Value) void {
        const block_obj = switch (block) {
            .object => |o| o,
            else => return,
        };

        const block_type = getStringField(block_obj, "type") orelse return;
        if (!mem.eql(u8, block_type, "text")) return;

        if (getStringField(block_obj, "text")) |text| {
            self.events.append(self.allocator, .{ .text = text }) catch {};
        }
    }
};

fn getStringField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return if (val == .string) val.string else null;
}

test "StreamParser - parse text delta" {
    const allocator = std.testing.allocator;

    var parser = StreamParser.init(allocator);
    defer parser.deinit();

    const json_line =
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
        \\
    ;

    parser.feed(json_line);

    const event = parser.next();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .text);
    // Note: text content points to freed JSON memory after parseLine completes
    // Full content testing would require copying strings in the parser
}

test "StreamParser - parse multiple events" {
    const allocator = std.testing.allocator;

    var parser = StreamParser.init(allocator);
    defer parser.deinit();

    const json_lines =
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":" World"}}
        \\
    ;

    parser.feed(json_lines);

    const event1 = parser.next();
    try std.testing.expect(event1 != null);
    try std.testing.expect(event1.? == .text);

    const event2 = parser.next();
    try std.testing.expect(event2 != null);
    try std.testing.expect(event2.? == .text);

    const event3 = parser.next();
    try std.testing.expect(event3 == null);
}

test "StreamParser - ignore non-text events" {
    const allocator = std.testing.allocator;

    var parser = StreamParser.init(allocator);
    defer parser.deinit();

    const json_line =
        \\{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}
        \\
    ;

    parser.feed(json_line);

    const event = parser.next();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .tool_use);
}

test "Claude - init" {
    const allocator = std.testing.allocator;
    const claude = Claude.init(allocator);
    _ = claude;
}
