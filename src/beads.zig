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
        const output = try self.runCommand(&.{ "br", "ready", "--json" });
        defer self.allocator.free(output);

        const tasks = try parseTaskList(self.allocator, output);
        defer {
            for (tasks) |*task| {
                var t = task.*;
                t.deinit();
            }
            self.allocator.free(tasks);
        }

        return tasks.len;
    }

    pub fn blockedCount(self: *Beads) !usize {
        const output = try self.runCommand(&.{ "br", "blocked", "--json" });
        defer self.allocator.free(output);

        const tasks = try parseTaskList(self.allocator, output);
        defer {
            for (tasks) |*task| {
                var t = task.*;
                t.deinit();
            }
            self.allocator.free(tasks);
        }

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

        // Sort by priority (lower is higher priority), then by created_at
        std.sort.insertion(Task, tasks, {}, struct {
            fn lessThan(_: void, a: Task, b: Task) bool {
                if (a.priority != b.priority) {
                    return a.priority < b.priority;
                }
                // If priorities equal, compare created_at (earlier first)
                const a_created = a.created_at orelse "";
                const b_created = b.created_at orelse "";
                return mem.lessThan(u8, a_created, b_created);
            }
        }.lessThan);

        // Return the first task (highest priority), free the rest
        const result = tasks[0];
        for (tasks[1..]) |*task| {
            task.deinit();
        }

        return result;
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

    var tags: []const []const u8 = &.{};
    if (obj.get("tags")) |tags_val| {
        if (tags_val == .array) {
            var tag_list: std.ArrayList([]const u8) = .empty;
            errdefer tag_list.deinit(allocator);
            for (tags_val.array.items) |tag_item| {
                if (tag_item == .string) {
                    try tag_list.append(allocator, try allocator.dupe(u8, tag_item.string));
                }
            }
            tags = try tag_list.toOwnedSlice(allocator);
        }
    }
    errdefer {
        for (tags) |tag| allocator.free(tag);
        allocator.free(tags);
    }

    var status: TaskStatus = .open;
    if (obj.get("status")) |status_val| {
        if (status_val == .string) {
            status = TaskStatus.fromString(status_val.string) orelse .open;
        }
    }

    var created_at: ?[]const u8 = null;
    if (obj.get("created_at")) |ca_val| {
        created_at = switch (ca_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }
    errdefer if (created_at) |ca| allocator.free(ca);

    var blocks: []const []const u8 = &.{};
    if (obj.get("blocks")) |blocks_val| {
        if (blocks_val == .array) {
            var block_list: std.ArrayList([]const u8) = .empty;
            errdefer block_list.deinit(allocator);
            for (blocks_val.array.items) |block_item| {
                if (block_item == .string) {
                    try block_list.append(allocator, try allocator.dupe(u8, block_item.string));
                }
            }
            blocks = try block_list.toOwnedSlice(allocator);
        }
    }

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
