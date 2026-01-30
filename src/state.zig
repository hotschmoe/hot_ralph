const std = @import("std");
const fs = std.fs;
const json = std.json;
const mem = std.mem;

pub const Phase = enum {
    idle,
    executing,
    awaiting_confirmation,
    simplifying,

    pub fn toString(self: Phase) []const u8 {
        return switch (self) {
            .idle => "idle",
            .executing => "executing",
            .awaiting_confirmation => "awaiting_confirmation",
            .simplifying => "simplifying",
        };
    }

    pub fn fromString(s: []const u8) ?Phase {
        if (mem.eql(u8, s, "idle")) return .idle;
        if (mem.eql(u8, s, "executing")) return .executing;
        if (mem.eql(u8, s, "awaiting_confirmation")) return .awaiting_confirmation;
        if (mem.eql(u8, s, "simplifying")) return .simplifying;
        return null;
    }
};

pub const StateError = error{
    InvalidJson,
    InvalidPhase,
    FileReadError,
    FileWriteError,
};

pub const State = struct {
    allocator: mem.Allocator,
    current_task_id: ?[]const u8,
    phase: Phase,
    output_file: ?[]const u8,
    started_at: ?i64,
    tasks_since_introspection: u32,

    pub fn init(allocator: mem.Allocator) State {
        return State{
            .allocator = allocator,
            .current_task_id = null,
            .phase = .idle,
            .output_file = null,
            .started_at = null,
            .tasks_since_introspection = 0,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.current_task_id) |id| {
            self.allocator.free(id);
        }
        if (self.output_file) |file| {
            self.allocator.free(file);
        }
    }

    pub fn load(allocator: mem.Allocator, path: []const u8) !?State {
        const file = fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return StateError.FileReadError,
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            return StateError.FileReadError;
        };
        defer allocator.free(content);

        return parseJson(allocator, content) catch {
            return StateError.InvalidJson;
        };
    }

    pub fn save(self: *const State, path: []const u8) !void {
        const dir_path = fs.path.dirname(path) orelse return StateError.FileWriteError;

        fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return StateError.FileWriteError,
        };

        const file = fs.createFileAbsolute(path, .{}) catch {
            return StateError.FileWriteError;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        try self.writeJson(&writer.interface);
        writer.interface.flush() catch return StateError.FileWriteError;
    }

    pub fn clear(path: []const u8) !void {
        fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return StateError.FileWriteError,
        };
    }

    pub fn setTask(self: *State, task_id: []const u8, output_file: []const u8) !void {
        if (self.current_task_id) |old_id| {
            self.allocator.free(old_id);
        }
        if (self.output_file) |old_file| {
            self.allocator.free(old_file);
        }

        self.current_task_id = try self.allocator.dupe(u8, task_id);
        self.output_file = try self.allocator.dupe(u8, output_file);
        self.started_at = std.time.timestamp();
        self.phase = .executing;
    }

    pub fn clearTask(self: *State) void {
        if (self.current_task_id) |id| {
            self.allocator.free(id);
            self.current_task_id = null;
        }
        if (self.output_file) |file| {
            self.allocator.free(file);
            self.output_file = null;
        }
        self.started_at = null;
        self.phase = .idle;
    }

    pub fn incrementTaskCount(self: *State) void {
        self.tasks_since_introspection += 1;
    }

    pub fn resetTaskCount(self: *State) void {
        self.tasks_since_introspection = 0;
    }

    fn parseJson(allocator: mem.Allocator, content: []const u8) !State {
        const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        var state = State.init(allocator);

        if (root.get("current_task_id")) |val| {
            if (val != .null) {
                state.current_task_id = try allocator.dupe(u8, val.string);
            }
        }

        if (root.get("phase")) |val| {
            state.phase = Phase.fromString(val.string) orelse return StateError.InvalidPhase;
        }

        if (root.get("output_file")) |val| {
            if (val != .null) {
                state.output_file = try allocator.dupe(u8, val.string);
            }
        }

        if (root.get("started_at")) |val| {
            if (val != .null) {
                state.started_at = val.integer;
            }
        }

        if (root.get("tasks_since_introspection")) |val| {
            state.tasks_since_introspection = @intCast(val.integer);
        }

        return state;
    }

    fn writeJson(self: *const State, writer: anytype) !void {
        try writer.writeAll("{\n");

        try writer.writeAll("    \"current_task_id\": ");
        if (self.current_task_id) |id| {
            try writer.print("\"{s}\"", .{id});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");

        try writer.print("    \"phase\": \"{s}\",\n", .{self.phase.toString()});

        try writer.writeAll("    \"output_file\": ");
        if (self.output_file) |file| {
            try writer.print("\"{s}\"", .{file});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");

        try writer.writeAll("    \"started_at\": ");
        if (self.started_at) |ts| {
            try writer.print("{d}", .{ts});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");

        try writer.print("    \"tasks_since_introspection\": {d}\n", .{self.tasks_since_introspection});

        try writer.writeAll("}\n");
    }
};

test "State - init and deinit" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.current_task_id == null);
    try std.testing.expect(state.phase == .idle);
    try std.testing.expect(state.output_file == null);
    try std.testing.expect(state.started_at == null);
    try std.testing.expect(state.tasks_since_introspection == 0);
}

test "State - setTask and clearTask" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    try state.setTask("task123", "/tmp/output.md");

    try std.testing.expectEqualStrings("task123", state.current_task_id.?);
    try std.testing.expectEqualStrings("/tmp/output.md", state.output_file.?);
    try std.testing.expect(state.phase == .executing);
    try std.testing.expect(state.started_at != null);

    state.clearTask();

    try std.testing.expect(state.current_task_id == null);
    try std.testing.expect(state.output_file == null);
    try std.testing.expect(state.phase == .idle);
}

test "Phase - toString and fromString" {
    try std.testing.expectEqualStrings("idle", Phase.idle.toString());
    try std.testing.expectEqualStrings("executing", Phase.executing.toString());
    try std.testing.expectEqualStrings("awaiting_confirmation", Phase.awaiting_confirmation.toString());
    try std.testing.expectEqualStrings("simplifying", Phase.simplifying.toString());

    try std.testing.expect(Phase.fromString("idle") == .idle);
    try std.testing.expect(Phase.fromString("executing") == .executing);
    try std.testing.expect(Phase.fromString("invalid") == null);
}

test "State - JSON round trip" {
    const allocator = std.testing.allocator;

    var original = State.init(allocator);
    defer original.deinit();

    try original.setTask("abc123", "/path/to/output.md");
    original.tasks_since_introspection = 3;
    original.phase = .awaiting_confirmation;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try original.writeJson(buffer.writer(allocator));

    var parsed = try State.parseJson(allocator, buffer.items);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("abc123", parsed.current_task_id.?);
    try std.testing.expectEqualStrings("/path/to/output.md", parsed.output_file.?);
    try std.testing.expect(parsed.phase == .awaiting_confirmation);
    try std.testing.expect(parsed.tasks_since_introspection == 3);
}
