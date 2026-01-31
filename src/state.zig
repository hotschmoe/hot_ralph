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

pub const PlanPhase = enum {
    none,
    planning,
    executing,
    complete,

    pub fn toString(self: PlanPhase) []const u8 {
        return switch (self) {
            .none => "none",
            .planning => "planning",
            .executing => "executing",
            .complete => "complete",
        };
    }

    pub fn fromString(s: []const u8) ?PlanPhase {
        if (mem.eql(u8, s, "none")) return .none;
        if (mem.eql(u8, s, "planning")) return .planning;
        if (mem.eql(u8, s, "executing")) return .executing;
        if (mem.eql(u8, s, "complete")) return .complete;
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
    plan_mode: bool,
    planned_beads: ?[][]const u8,
    plan_phase: PlanPhase,
    current_plan_index: usize,

    pub fn init(allocator: mem.Allocator) State {
        return State{
            .allocator = allocator,
            .current_task_id = null,
            .phase = .idle,
            .output_file = null,
            .started_at = null,
            .tasks_since_introspection = 0,
            .plan_mode = false,
            .planned_beads = null,
            .plan_phase = .none,
            .current_plan_index = 0,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.current_task_id) |id| {
            self.allocator.free(id);
        }
        if (self.output_file) |file| {
            self.allocator.free(file);
        }
        if (self.planned_beads) |beads| {
            for (beads) |bead| {
                self.allocator.free(bead);
            }
            self.allocator.free(beads);
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

    pub fn setPlanMode(self: *State, task_ids: []const []const u8) !void {
        // Clear any existing planned beads
        if (self.planned_beads) |beads| {
            for (beads) |bead| {
                self.allocator.free(bead);
            }
            self.allocator.free(beads);
        }

        // Copy task IDs
        var new_beads = try self.allocator.alloc([]const u8, task_ids.len);
        errdefer self.allocator.free(new_beads);

        for (task_ids, 0..) |id, i| {
            new_beads[i] = try self.allocator.dupe(u8, id);
        }

        self.planned_beads = new_beads;
        self.plan_mode = true;
        self.plan_phase = .planning;
        self.current_plan_index = 0;
    }

    pub fn clearPlanMode(self: *State) void {
        if (self.planned_beads) |beads| {
            for (beads) |bead| {
                self.allocator.free(bead);
            }
            self.allocator.free(beads);
            self.planned_beads = null;
        }
        self.plan_mode = false;
        self.plan_phase = .none;
        self.current_plan_index = 0;
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

        if (root.get("plan_mode")) |val| {
            state.plan_mode = switch (val) {
                .bool => |b| b,
                else => false,
            };
        }

        if (root.get("plan_phase")) |val| {
            if (val == .string) {
                state.plan_phase = PlanPhase.fromString(val.string) orelse .none;
            }
        }

        if (root.get("current_plan_index")) |val| {
            if (val == .integer) {
                state.current_plan_index = @intCast(val.integer);
            }
        }

        if (root.get("planned_beads")) |val| {
            if (val == .array) {
                var beads_list: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (beads_list.items) |b| allocator.free(b);
                    beads_list.deinit(allocator);
                }

                for (val.array.items) |item| {
                    if (item == .string) {
                        try beads_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }

                if (beads_list.items.len > 0) {
                    state.planned_beads = try beads_list.toOwnedSlice(allocator);
                } else {
                    beads_list.deinit(allocator);
                }
            }
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

        try writer.print("    \"tasks_since_introspection\": {d},\n", .{self.tasks_since_introspection});

        try writer.print("    \"plan_mode\": {s},\n", .{if (self.plan_mode) "true" else "false"});
        try writer.print("    \"plan_phase\": \"{s}\",\n", .{self.plan_phase.toString()});
        try writer.print("    \"current_plan_index\": {d},\n", .{self.current_plan_index});

        try writer.writeAll("    \"planned_beads\": ");
        if (self.planned_beads) |beads| {
            try writer.writeAll("[");
            for (beads, 0..) |bead, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{bead});
            }
            try writer.writeAll("]\n");
        } else {
            try writer.writeAll("null\n");
        }

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
    try std.testing.expect(!state.plan_mode);
    try std.testing.expect(state.planned_beads == null);
    try std.testing.expect(state.plan_phase == .none);
    try std.testing.expect(state.current_plan_index == 0);
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

test "PlanPhase - toString and fromString" {
    try std.testing.expectEqualStrings("none", PlanPhase.none.toString());
    try std.testing.expectEqualStrings("planning", PlanPhase.planning.toString());
    try std.testing.expectEqualStrings("executing", PlanPhase.executing.toString());
    try std.testing.expectEqualStrings("complete", PlanPhase.complete.toString());

    try std.testing.expect(PlanPhase.fromString("none") == .none);
    try std.testing.expect(PlanPhase.fromString("planning") == .planning);
    try std.testing.expect(PlanPhase.fromString("invalid") == null);
}

test "State - setPlanMode and clearPlanMode" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    const task_ids = &[_][]const u8{ "task1", "task2", "task3" };
    try state.setPlanMode(task_ids);

    try std.testing.expect(state.plan_mode);
    try std.testing.expect(state.plan_phase == .planning);
    try std.testing.expect(state.planned_beads != null);
    try std.testing.expect(state.planned_beads.?.len == 3);
    try std.testing.expectEqualStrings("task1", state.planned_beads.?[0]);

    state.clearPlanMode();

    try std.testing.expect(!state.plan_mode);
    try std.testing.expect(state.plan_phase == .none);
    try std.testing.expect(state.planned_beads == null);
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
