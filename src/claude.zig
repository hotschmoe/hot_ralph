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

pub const FatalErrorType = enum {
    subscription_limit, // exit 5
    auth_error, // exit 6
    rate_limit, // exit 7
    network_failure, // exit 8
    malformed_response, // exit 9
    unknown, // exit 3

    pub fn toExitCode(self: FatalErrorType) u8 {
        return switch (self) {
            .subscription_limit => 5,
            .auth_error => 6,
            .rate_limit => 7,
            .network_failure => 8,
            .malformed_response => 9,
            .unknown => 3,
        };
    }

    pub fn toString(self: FatalErrorType) []const u8 {
        return switch (self) {
            .subscription_limit => "Subscription/quota limit reached",
            .auth_error => "Authentication error",
            .rate_limit => "Rate limit exceeded",
            .network_failure => "Network failure",
            .malformed_response => "Malformed response",
            .unknown => "Unknown error",
        };
    }
};

pub fn classifyError(message: []const u8) FatalErrorType {
    const lower_buf = blk: {
        var buf: [512]u8 = undefined;
        const len = @min(message.len, buf.len);
        for (0..len) |i| {
            buf[i] = std.ascii.toLower(message[i]);
        }
        break :blk buf[0..len];
    };

    // Rate limit errors - check first since "rate limit exceeded" matches both patterns
    if (mem.indexOf(u8, lower_buf, "rate limit") != null or
        mem.indexOf(u8, lower_buf, "429") != null or
        mem.indexOf(u8, lower_buf, "too many requests") != null or
        mem.indexOf(u8, lower_buf, "overloaded") != null)
    {
        return .rate_limit;
    }

    // Subscription/quota errors
    if (mem.indexOf(u8, lower_buf, "subscription") != null or
        mem.indexOf(u8, lower_buf, "quota") != null or
        mem.indexOf(u8, lower_buf, "usage limit") != null or
        mem.indexOf(u8, lower_buf, "limit exceeded") != null or
        mem.indexOf(u8, lower_buf, "quota exceeded") != null)
    {
        return .subscription_limit;
    }

    // Auth errors
    if (mem.indexOf(u8, lower_buf, "unauthorized") != null or
        mem.indexOf(u8, lower_buf, "not authenticated") != null or
        mem.indexOf(u8, lower_buf, "invalid key") != null or
        mem.indexOf(u8, lower_buf, "api key") != null or
        mem.indexOf(u8, lower_buf, "authentication") != null)
    {
        return .auth_error;
    }

    // Network errors
    if (mem.indexOf(u8, lower_buf, "connection") != null or
        mem.indexOf(u8, lower_buf, "timeout") != null or
        mem.indexOf(u8, lower_buf, "network") != null or
        mem.indexOf(u8, lower_buf, "econnrefused") != null)
    {
        return .network_failure;
    }

    // Malformed response errors
    if (mem.indexOf(u8, lower_buf, "parse") != null or
        mem.indexOf(u8, lower_buf, "invalid json") != null or
        mem.indexOf(u8, lower_buf, "malformed") != null or
        mem.indexOf(u8, lower_buf, "unexpected") != null)
    {
        return .malformed_response;
    }

    return .unknown;
}

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
        error_type: FatalErrorType,
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
                        defer self.allocator.free(text);
                        try response_buffer.appendSlice(self.allocator, text);
                        if (terminal_writer_opt) |*writer| {
                            writer.interface.writeAll(text) catch {};
                            writer.interface.flush() catch {};
                        }
                    },
                    .tool_use => {},
                    .thinking => {},
                    .error_msg => |msg| {
                        // msg is already owned, pass ownership to result
                        return RunResult{
                            .failure = .{
                                .message = msg,
                                .error_type = classifyError(msg),
                            },
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

            const exit_msg = try std.fmt.allocPrint(
                self.allocator,
                "Claude exited with code {d}",
                .{result.Exited},
            );
            return RunResult{
                .failure = .{
                    .message = exit_msg,
                    .error_type = classifyError(exit_msg),
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
        // Free any remaining events with owned strings
        for (self.events.items) |event| {
            switch (event) {
                .text => |t| self.allocator.free(t),
                .error_msg => |m| self.allocator.free(m),
                else => {},
            }
        }
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

        self.extractEvents(parsed.value, true);
    }

    fn extractEvents(self: *StreamParser, value: json.Value, dupe_strings: bool) void {
        const obj = switch (value) {
            .object => |o| o,
            else => return,
        };

        const type_str = getStringField(obj, "type") orelse "";

        if (mem.eql(u8, type_str, "content_block_delta")) {
            if (obj.get("delta")) |delta| {
                self.extractDelta(delta, dupe_strings);
            }
        } else if (mem.eql(u8, type_str, "error")) {
            self.extractErrorMessage(obj, dupe_strings);
        }

        if (obj.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |item| {
                    self.extractContentBlock(item, dupe_strings);
                }
            }
        }

        if (getStringField(obj, "result")) |result| {
            const text = if (dupe_strings) self.allocator.dupe(u8, result) catch return else result;
            self.events.append(self.allocator, .{ .text = text }) catch {};
        }
    }

    fn extractErrorMessage(self: *StreamParser, obj: json.ObjectMap, dupe_strings: bool) void {
        const err_obj = obj.get("error") orelse return;
        if (err_obj != .object) return;
        const msg = getStringField(err_obj.object, "message") orelse return;
        const text = if (dupe_strings) self.allocator.dupe(u8, msg) catch return else msg;
        self.events.append(self.allocator, .{ .error_msg = text }) catch {};
    }

    fn extractDelta(self: *StreamParser, delta: json.Value, dupe_strings: bool) void {
        const delta_obj = switch (delta) {
            .object => |o| o,
            else => return,
        };

        const delta_type = getStringField(delta_obj, "type") orelse return;

        if (mem.eql(u8, delta_type, "text_delta")) {
            if (getStringField(delta_obj, "text")) |t| {
                const text = if (dupe_strings) self.allocator.dupe(u8, t) catch return else t;
                self.events.append(self.allocator, .{ .text = text }) catch {};
            }
        } else if (mem.eql(u8, delta_type, "input_json_delta")) {
            self.events.append(self.allocator, .tool_use) catch {};
        } else if (mem.eql(u8, delta_type, "thinking_delta")) {
            self.events.append(self.allocator, .thinking) catch {};
        }
    }

    fn extractContentBlock(self: *StreamParser, block: json.Value, dupe_strings: bool) void {
        const block_obj = switch (block) {
            .object => |o| o,
            else => return,
        };

        const block_type = getStringField(block_obj, "type") orelse return;
        if (!mem.eql(u8, block_type, "text")) return;

        if (getStringField(block_obj, "text")) |t| {
            const text = if (dupe_strings) self.allocator.dupe(u8, t) catch return else t;
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
    switch (event.?) {
        .text => |t| {
            try std.testing.expectEqualStrings("Hello", t);
            allocator.free(t);
        },
        else => try std.testing.expect(false),
    }
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
    switch (event1.?) {
        .text => |t| {
            try std.testing.expectEqualStrings("Hello", t);
            allocator.free(t);
        },
        else => try std.testing.expect(false),
    }

    const event2 = parser.next();
    try std.testing.expect(event2 != null);
    switch (event2.?) {
        .text => |t| {
            try std.testing.expectEqualStrings(" World", t);
            allocator.free(t);
        },
        else => try std.testing.expect(false),
    }

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

test "classifyError - subscription limit" {
    try std.testing.expect(classifyError("Your subscription quota has been exceeded") == .subscription_limit);
    try std.testing.expect(classifyError("Usage limit reached") == .subscription_limit);
}

test "classifyError - auth error" {
    try std.testing.expect(classifyError("Unauthorized: invalid API key") == .auth_error);
    try std.testing.expect(classifyError("Not authenticated") == .auth_error);
    try std.testing.expect(classifyError("Authentication failed") == .auth_error);
}

test "classifyError - rate limit" {
    try std.testing.expect(classifyError("Rate limit exceeded") == .rate_limit);
    try std.testing.expect(classifyError("Error 429: too many requests") == .rate_limit);
    try std.testing.expect(classifyError("Server overloaded") == .rate_limit);
}

test "classifyError - network failure" {
    try std.testing.expect(classifyError("Connection refused") == .network_failure);
    try std.testing.expect(classifyError("Request timeout") == .network_failure);
    try std.testing.expect(classifyError("Network error") == .network_failure);
}

test "classifyError - malformed response" {
    try std.testing.expect(classifyError("Failed to parse response") == .malformed_response);
    try std.testing.expect(classifyError("Invalid JSON received") == .malformed_response);
    try std.testing.expect(classifyError("Malformed data") == .malformed_response);
}

test "classifyError - unknown" {
    try std.testing.expect(classifyError("Some random error") == .unknown);
    try std.testing.expect(classifyError("") == .unknown);
}

test "FatalErrorType - exit codes" {
    try std.testing.expect(FatalErrorType.subscription_limit.toExitCode() == 5);
    try std.testing.expect(FatalErrorType.auth_error.toExitCode() == 6);
    try std.testing.expect(FatalErrorType.rate_limit.toExitCode() == 7);
    try std.testing.expect(FatalErrorType.network_failure.toExitCode() == 8);
    try std.testing.expect(FatalErrorType.malformed_response.toExitCode() == 9);
    try std.testing.expect(FatalErrorType.unknown.toExitCode() == 3);
}
