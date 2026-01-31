const std = @import("std");
const mem = std.mem;
const json = std.json;
const process = std.process;

pub const BeadsError = error{
    NotInitialized,
    NoReadyTasks,
    TaskNotFound,
    InvalidJson,
    CommandFailed,
    OutOfMemory,
};

pub const TaskStatus = enum {
    open,
    in_progress,
    closed,
    deferred,

    pub fn fromString(s: []const u8) ?TaskStatus {
        if (mem.eql(u8, s, "open")) return .open;
        if (mem.eql(u8, s, "in_progress")) return .in_progress;
        if (mem.eql(u8, s, "closed")) return .closed;
        if (mem.eql(u8, s, "deferred")) return .deferred;
        return null;
    }

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .in_progress => "in_progress",
            .closed => "closed",
            .deferred => "deferred",
        };
    }
};

pub const Task = struct {
    allocator: mem.Allocator,
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    priority: i32,
    tags: []const []const u8,
    status: TaskStatus,
    created_at: ?[]const u8,
    blocks: []const []const u8,

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.id);
        self.allocator.free(self.title);
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
        for (self.tags) |tag| {
            self.allocator.free(tag);
        }
        self.allocator.free(self.tags);
        if (self.created_at) |ca| {
            self.allocator.free(ca);
        }
        for (self.blocks) |b| {
            self.allocator.free(b);
        }
        self.allocator.free(self.blocks);
    }

    pub fn clone(self: *const Task, allocator: mem.Allocator) !Task {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);

        const title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title);

        const description = if (self.description) |d| try allocator.dupe(u8, d) else null;
        errdefer if (description) |d| allocator.free(d);

        var tags = try allocator.alloc([]const u8, self.tags.len);
        errdefer allocator.free(tags);
        for (self.tags, 0..) |tag, i| {
            tags[i] = try allocator.dupe(u8, tag);
        }

        const created_at = if (self.created_at) |ca| try allocator.dupe(u8, ca) else null;
        errdefer if (created_at) |ca| allocator.free(ca);

        var blocks = try allocator.alloc([]const u8, self.blocks.len);
        errdefer allocator.free(blocks);
        for (self.blocks, 0..) |b, i| {
            blocks[i] = try allocator.dupe(u8, b);
        }

        return Task{
            .allocator = allocator,
            .id = id,
            .title = title,
            .description = description,
            .priority = self.priority,
            .tags = tags,
            .status = self.status,
            .created_at = created_at,
            .blocks = blocks,
        };
    }
};

pub const Beads = struct {
    allocator: mem.Allocator,
    project_dir: []const u8,

    pub fn init(allocator: mem.Allocator, project_dir: []const u8) Beads {
        return Beads{
            .allocator = allocator,
            .project_dir = project_dir,
        };
    }

    pub fn readyCount(self: *Beads) !usize {
        return self.countTasks(&.{ "br", "ready", "--json" });
    }

    pub fn blockedCount(self: *Beads) !usize {
        return self.countTasks(&.{ "br", "blocked", "--json" });
    }

    fn countTasks(self: *Beads, args: []const []const u8) !usize {
        const output = try self.runCommand(args);
        defer self.allocator.free(output);

        const tasks = try parseTaskList(self.allocator, output);
        defer freeTasks(self.allocator, tasks);

        return tasks.len;
    }

    pub fn getNextReady(self: *Beads) !?Task {
        const output = try self.runCommand(&.{ "br", "ready", "--json" });
        defer self.allocator.free(output);

        var tasks = try parseTaskList(self.allocator, output);
        defer self.allocator.free(tasks);

        if (tasks.len == 0) {
            return null;
        }

        std.sort.insertion(Task, tasks, {}, taskPriorityLessThan);

        const result = tasks[0];
        for (tasks[1..]) |*task| {
            task.deinit();
        }

        return result;
    }

    pub fn taskPriorityLessThan(_: void, a: Task, b: Task) bool {
        if (a.priority != b.priority) {
            return a.priority < b.priority;
        }
        const a_created = a.created_at orelse "";
        const b_created = b.created_at orelse "";
        return mem.lessThan(u8, a_created, b_created);
    }

    pub fn getAllReady(self: *Beads) ![]Task {
        const output = try self.runCommand(&.{ "br", "ready", "--json" });
        defer self.allocator.free(output);

        return try parseTaskList(self.allocator, output);
    }

    pub fn claim(self: *Beads, task_id: []const u8) !void {
        _ = try self.runCommand(&.{ "br", "update", task_id, "--status", "in_progress" });
    }

    pub fn complete(self: *Beads, task_id: []const u8, reason: []const u8) !void {
        _ = try self.runCommand(&.{ "br", "close", task_id, "--reason", reason });
    }

    pub fn sync(self: *Beads) !void {
        _ = try self.runCommand(&.{ "br", "sync", "--flush-only" });
    }

    pub fn getRelatedBeads(self: *Beads, anchor: *const Task, limit: usize) ![]Task {
        const all_ready = try self.getAllReady();
        defer {
            for (all_ready) |*t| t.deinit();
            self.allocator.free(all_ready);
        }

        if (all_ready.len == 0) {
            return self.allocator.alloc(Task, 0);
        }

        var related: std.ArrayList(Task) = .empty;
        errdefer {
            for (related.items) |*t| t.deinit();
            related.deinit(self.allocator);
        }

        // Always include the anchor first
        try related.append(self.allocator, try anchor.clone(self.allocator));

        // Sort all tasks by priority for consistent ordering
        std.sort.insertion(Task, all_ready, {}, taskPriorityLessThan);

        // First pass: collect related tasks (shared tags or dependency chain)
        for (all_ready) |task| {
            if (related.items.len >= limit) break;
            if (isTaskInList(task.id, related.items)) continue;

            const is_related = sharesAnyTag(task.tags, anchor.tags) or
                containsId(anchor.blocks, task.id) or
                containsId(task.blocks, anchor.id);

            if (is_related) {
                try related.append(self.allocator, try task.clone(self.allocator));
            }
        }

        // Second pass: fill remaining slots with priority-sorted tasks
        for (all_ready) |task| {
            if (related.items.len >= limit) break;
            if (isTaskInList(task.id, related.items)) continue;

            try related.append(self.allocator, try task.clone(self.allocator));
        }

        std.sort.insertion(Task, related.items, {}, taskPriorityLessThan);
        return related.toOwnedSlice(self.allocator);
    }

    fn sharesAnyTag(tags_a: []const []const u8, tags_b: []const []const u8) bool {
        for (tags_a) |a| {
            for (tags_b) |b| {
                if (mem.eql(u8, a, b)) return true;
            }
        }
        return false;
    }

    fn containsId(ids: []const []const u8, target: []const u8) bool {
        for (ids) |id| {
            if (mem.eql(u8, id, target)) return true;
        }
        return false;
    }

    fn isTaskInList(task_id: []const u8, tasks: []const Task) bool {
        for (tasks) |t| {
            if (mem.eql(u8, t.id, task_id)) return true;
        }
        return false;
    }

    fn runCommand(self: *Beads, args: []const []const u8) ![]const u8 {
        var child = process.Child.init(args, self.allocator);
        child.cwd = self.project_dir;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();

        const stdout = child.stdout orelse return BeadsError.CommandFailed;
        const output = stdout.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            return BeadsError.CommandFailed;
        };
        errdefer self.allocator.free(output);

        const result = child.wait() catch {
            return BeadsError.CommandFailed;
        };

        if (result.Exited != 0) {
            self.allocator.free(output);
            return BeadsError.CommandFailed;
        }

        return output;
    }
};

fn freeTasks(allocator: mem.Allocator, tasks: []Task) void {
    for (tasks) |*task| {
        var t = task.*;
        t.deinit();
    }
    allocator.free(tasks);
}

fn freeStringSlice(allocator: mem.Allocator, slice: []const []const u8) void {
    for (slice) |s| allocator.free(s);
    if (slice.len > 0) allocator.free(slice);
}

fn parseStringArray(allocator: mem.Allocator, maybe_val: ?json.Value) ![]const []const u8 {
    const val = maybe_val orelse return &.{};
    if (val != .array) return &.{};

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    for (val.array.items) |item| {
        if (item == .string) {
            try list.append(allocator, try allocator.dupe(u8, item.string));
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseTaskList(allocator: mem.Allocator, json_str: []const u8) ![]Task {
    // Handle empty output
    const trimmed = mem.trim(u8, json_str, &std.ascii.whitespace);
    if (trimmed.len == 0 or mem.eql(u8, trimmed, "[]")) {
        return allocator.alloc(Task, 0);
    }

    const parsed = json.parseFromSlice(json.Value, allocator, json_str, .{}) catch {
        return BeadsError.InvalidJson;
    };
    defer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |arr| arr,
        else => return BeadsError.InvalidJson,
    };

    var tasks = try allocator.alloc(Task, array.items.len);
    errdefer allocator.free(tasks);

    var valid_count: usize = 0;
    for (array.items) |item| {
        if (parseTask(allocator, item)) |task| {
            tasks[valid_count] = task;
            valid_count += 1;
        } else |_| {
            // Skip invalid tasks
            continue;
        }
    }

    // Shrink to actual size
    if (valid_count < tasks.len) {
        tasks = try allocator.realloc(tasks, valid_count);
    }

    return tasks;
}

fn parseTask(allocator: mem.Allocator, value: json.Value) !Task {
    const obj = switch (value) {
        .object => |o| o,
        else => return BeadsError.InvalidJson,
    };

    const id_val = obj.get("id") orelse return BeadsError.InvalidJson;
    const id = switch (id_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return BeadsError.InvalidJson,
    };
    errdefer allocator.free(id);

    const title_val = obj.get("title") orelse obj.get("subject") orelse return BeadsError.InvalidJson;
    const title = switch (title_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return BeadsError.InvalidJson,
    };
    errdefer allocator.free(title);

    var description: ?[]const u8 = null;
    if (obj.get("description")) |desc_val| {
        description = switch (desc_val) {
            .string => |s| try allocator.dupe(u8, s),
            .null => null,
            else => null,
        };
    }
    errdefer if (description) |d| allocator.free(d);

    var priority: i32 = 2; // default medium
    if (obj.get("priority")) |prio_val| {
        priority = switch (prio_val) {
            .integer => |i| @intCast(i),
            else => 2,
        };
    }

    const tags = try parseStringArray(allocator, obj.get("tags"));
    errdefer freeStringSlice(allocator, tags);

    const status: TaskStatus = if (obj.get("status")) |status_val|
        if (status_val == .string) TaskStatus.fromString(status_val.string) orelse .open else .open
    else
        .open;

    const created_at: ?[]const u8 = if (obj.get("created_at")) |ca_val|
        switch (ca_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        }
    else
        null;
    errdefer if (created_at) |ca| allocator.free(ca);

    const blocks = try parseStringArray(allocator, obj.get("blocks"));

    return Task{
        .allocator = allocator,
        .id = id,
        .title = title,
        .description = description,
        .priority = priority,
        .tags = tags,
        .status = status,
        .created_at = created_at,
        .blocks = blocks,
    };
}

test "TaskStatus - fromString and toString" {
    try std.testing.expect(TaskStatus.fromString("open") == .open);
    try std.testing.expect(TaskStatus.fromString("in_progress") == .in_progress);
    try std.testing.expect(TaskStatus.fromString("closed") == .closed);
    try std.testing.expect(TaskStatus.fromString("invalid") == null);

    try std.testing.expectEqualStrings("open", TaskStatus.open.toString());
    try std.testing.expectEqualStrings("in_progress", TaskStatus.in_progress.toString());
}

test "parseTaskList - empty array" {
    const allocator = std.testing.allocator;

    const tasks = try parseTaskList(allocator, "[]");
    defer allocator.free(tasks);

    try std.testing.expect(tasks.len == 0);
}

test "parseTaskList - single task" {
    const allocator = std.testing.allocator;

    const json_str =
        \\[{
        \\  "id": "abc123",
        \\  "title": "Test Task",
        \\  "description": "A test description",
        \\  "priority": 1,
        \\  "status": "open",
        \\  "tags": ["test", "unit"],
        \\  "created_at": "2025-01-30T12:00:00Z"
        \\}]
    ;

    const tasks = try parseTaskList(allocator, json_str);
    defer {
        for (tasks) |*task| {
            task.deinit();
        }
        allocator.free(tasks);
    }

    try std.testing.expect(tasks.len == 1);
    try std.testing.expectEqualStrings("abc123", tasks[0].id);
    try std.testing.expectEqualStrings("Test Task", tasks[0].title);
    try std.testing.expectEqualStrings("A test description", tasks[0].description.?);
    try std.testing.expect(tasks[0].priority == 1);
    try std.testing.expect(tasks[0].status == .open);
    try std.testing.expect(tasks[0].tags.len == 2);
}

test "Task - clone" {
    const allocator = std.testing.allocator;

    var tags = try allocator.alloc([]const u8, 1);
    tags[0] = try allocator.dupe(u8, "test");

    var original = Task{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "orig123"),
        .title = try allocator.dupe(u8, "Original"),
        .description = try allocator.dupe(u8, "Desc"),
        .priority = 1,
        .tags = tags,
        .status = .open,
        .created_at = null,
        .blocks = &.{},
    };
    defer original.deinit();

    var cloned = try original.clone(allocator);
    defer cloned.deinit();

    try std.testing.expectEqualStrings("orig123", cloned.id);
    try std.testing.expectEqualStrings("Original", cloned.title);
    try std.testing.expect(cloned.id.ptr != original.id.ptr);
}

test "taskPriorityLessThan - sorts by priority" {
    const allocator = std.testing.allocator;

    const task_low = Task{
        .allocator = allocator,
        .id = "low",
        .title = "Low",
        .description = null,
        .priority = 3,
        .tags = &.{},
        .status = .open,
        .created_at = null,
        .blocks = &.{},
    };

    const task_high = Task{
        .allocator = allocator,
        .id = "high",
        .title = "High",
        .description = null,
        .priority = 1,
        .tags = &.{},
        .status = .open,
        .created_at = null,
        .blocks = &.{},
    };

    // Higher priority (lower number) should come first
    try std.testing.expect(Beads.taskPriorityLessThan({}, task_high, task_low));
    try std.testing.expect(!Beads.taskPriorityLessThan({}, task_low, task_high));
}
