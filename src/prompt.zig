const std = @import("std");
const mem = std.mem;

pub const Task = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    priority: i32,
    tags: []const []const u8,
};

pub const TaskPrompt = struct {
    task: Task,
    context_files: []const []const u8,

    const DEFAULT_CONTEXT_FILES = &[_][]const u8{ "SPEC.md", "VISION.md", "TESTING.md" };

    pub fn init(task: Task) TaskPrompt {
        return TaskPrompt{
            .task = task,
            .context_files = DEFAULT_CONTEXT_FILES,
        };
    }

    pub fn withContextFiles(self: TaskPrompt, files: []const []const u8) TaskPrompt {
        var result = self;
        result.context_files = files;
        return result;
    }

    pub fn render(self: *const TaskPrompt, writer: anytype) !void {
        try writer.writeAll("You are implementing a single atomic task.\n\n");

        try writer.writeAll("## Task\n");
        try writer.print("**{s}**\n\n", .{self.task.title});

        if (self.task.description) |desc| {
            try writer.print("{s}\n\n", .{desc});
        }

        try writer.writeAll("## Context Files\n");
        for (self.context_files) |file| {
            try writer.print("- @{s}\n", .{file});
        }
        try writer.writeAll("\n");

        try writer.writeAll(
            \\## Instructions
            \\1. Implement ONLY what this task specifies - no more, no less
            \\2. Run any validation criteria specified in the description
            \\3. If validation passes, commit with message based on task title
            \\4. Report success or failure clearly
            \\
            \\This is an ATOMIC task. Stay focused.
            \\
        );
    }

    pub fn renderToString(self: *const TaskPrompt, allocator: mem.Allocator) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        try self.render(buffer.writer(allocator));
        return buffer.toOwnedSlice(allocator);
    }
};

pub const SimplificationPrompt = struct {
    task_title: []const u8,

    pub fn init(task_title: []const u8) SimplificationPrompt {
        return SimplificationPrompt{
            .task_title = task_title,
        };
    }

    pub fn render(self: *const SimplificationPrompt, writer: anytype) !void {
        try writer.print("Review the code changes made for task: {s}\n\n", .{self.task_title});

        try writer.writeAll(
            \\Use the code-simplifier approach:
            \\1. Find recently modified files (check git status and git diff)
            \\2. Simplify and refine code for clarity, consistency, and maintainability
            \\3. Preserve all functionality - no behavior changes
            \\4. Run tests to verify nothing broke
            \\5. If tests pass, commit any simplification changes
            \\
            \\Focus on the code that was just modified. Keep changes minimal and safe.
            \\
        );
    }

    pub fn renderToString(self: *const SimplificationPrompt, allocator: mem.Allocator) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        try self.render(buffer.writer(allocator));
        return buffer.toOwnedSlice(allocator);
    }
};

pub const FinalReviewPrompt = struct {
    pub fn render(writer: anytype) !void {
        try writer.writeAll(
            \\All tasks have been completed. Perform a final review.
            \\
            \\## Context Files
            \\- @SPEC.md - Project specification
            \\- @VISION.md - Project vision
            \\- @TESTING.md - Testing requirements
            \\
            \\## Instructions
            \\1. Review the overall state of the project
            \\2. Verify all specifications in SPEC.md are met
            \\3. Ensure the implementation aligns with VISION.md
            \\4. Confirm testing requirements from TESTING.md are satisfied
            \\5. Report any gaps or issues found
            \\
            \\Provide a concise summary of the project state.
            \\
        );
    }

    pub fn renderToString(allocator: mem.Allocator) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        try render(buffer.writer(allocator));
        return buffer.toOwnedSlice(allocator);
    }
};

pub const IntrospectionPrompt = struct {
    task_logs: []const []const u8,
    claude_md_content: ?[]const u8,
    existing_skills: []const []const u8,
    existing_agents: []const []const u8,

    pub fn render(self: *const IntrospectionPrompt, writer: anytype) !void {
        try writer.writeAll("Review the last task logs from this development session.\n\n");

        try writer.writeAll("## Task Logs\n");
        for (self.task_logs) |log| {
            try writer.print("{s}\n\n---\n\n", .{log});
        }

        try writer.writeAll("## Current CLAUDE.md\n");
        if (self.claude_md_content) |content| {
            try writer.print("{s}\n\n", .{content});
        } else {
            try writer.writeAll("(No CLAUDE.md found)\n\n");
        }

        try writer.writeAll("## Existing Skills\n");
        if (self.existing_skills.len == 0) {
            try writer.writeAll("(None)\n");
        } else {
            for (self.existing_skills) |skill| {
                try writer.print("- {s}\n", .{skill});
            }
        }
        try writer.writeAll("\n");

        try writer.writeAll("## Existing Agents\n");
        if (self.existing_agents.len == 0) {
            try writer.writeAll("(None)\n");
        } else {
            for (self.existing_agents) |agent| {
                try writer.print("- {s}\n", .{agent});
            }
        }
        try writer.writeAll("\n");

        try writer.writeAll(
            \\Analyze for:
            \\1. Patterns that should be documented in CLAUDE.md
            \\2. Repeated multi-step operations that could become a skill
            \\3. Specialized task types that could benefit from a dedicated agent
            \\
            \\For each suggestion, provide:
            \\- What to add/create
            \\- Why (evidence from logs)
            \\- Exact content to add
            \\
            \\Be conservative - only suggest high-value additions.
            \\
        );
    }

    pub fn renderToString(self: *const IntrospectionPrompt, allocator: mem.Allocator) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        try self.render(buffer.writer(allocator));
        return buffer.toOwnedSlice(allocator);
    }
};

test "TaskPrompt - render" {
    const allocator = std.testing.allocator;

    const task = Task{
        .id = "abc123",
        .title = "Implement feature X",
        .description = "Add the X feature to the system.",
        .priority = 1,
        .tags = &.{},
    };

    const prompt = TaskPrompt.init(task);
    const result = try prompt.renderToString(allocator);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Implement feature X") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Add the X feature") != null);
    try std.testing.expect(mem.indexOf(u8, result, "@SPEC.md") != null);
    try std.testing.expect(mem.indexOf(u8, result, "ATOMIC task") != null);
}

test "SimplificationPrompt - render" {
    const allocator = std.testing.allocator;

    const prompt = SimplificationPrompt.init("Implement feature X");
    const result = try prompt.renderToString(allocator);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Implement feature X") != null);
    try std.testing.expect(mem.indexOf(u8, result, "code-simplifier") != null);
    try std.testing.expect(mem.indexOf(u8, result, "git diff") != null);
}

pub const PlanModePrompt = struct {
    tasks: []const Task,
    context_files: []const []const u8,

    const DEFAULT_CONTEXT_FILES = &[_][]const u8{ "SPEC.md", "VISION.md", "TESTING.md" };

    pub fn init(tasks: []const Task) PlanModePrompt {
        return PlanModePrompt{
            .tasks = tasks,
            .context_files = DEFAULT_CONTEXT_FILES,
        };
    }

    pub fn withContextFiles(self: PlanModePrompt, files: []const []const u8) PlanModePrompt {
        var result = self;
        result.context_files = files;
        return result;
    }

    pub fn render(self: *const PlanModePrompt, writer: anytype) !void {
        try writer.writeAll("You are implementing a batch of related atomic tasks.\n\n");

        try writer.writeAll("## Task Batch\n\n");
        try writer.print("Execute the following {d} tasks in order:\n\n", .{self.tasks.len});

        for (self.tasks, 0..) |task, i| {
            try writer.print("### Task {d}: {s}\n", .{ i + 1, task.title });
            try writer.print("**ID**: {s}\n", .{task.id});
            try writer.print("**Priority**: {d}\n", .{task.priority});
            if (task.tags.len > 0) {
                try writer.writeAll("**Tags**: ");
                for (task.tags, 0..) |tag, j| {
                    if (j > 0) try writer.writeAll(", ");
                    try writer.writeAll(tag);
                }
                try writer.writeAll("\n");
            }
            if (task.description) |desc| {
                try writer.print("\n{s}\n", .{desc});
            }
            try writer.writeAll("\n---\n\n");
        }

        try writer.writeAll("## Context Files\n");
        for (self.context_files) |file| {
            try writer.print("- @{s}\n", .{file});
        }
        try writer.writeAll("\n");

        try writer.writeAll(
            \\## Execution Instructions
            \\
            \\1. Execute each task in the order listed above
            \\2. For each task:
            \\   - Implement ONLY what the task specifies
            \\   - Run any validation criteria from the description
            \\   - Verify the implementation before moving to the next task
            \\3. After all tasks complete:
            \\   - Run `git add` for all changed files
            \\   - Create a single commit summarizing all changes
            \\4. Report the status of each task: SUCCESS or FAILED with reason
            \\
            \\IMPORTANT: These are ATOMIC tasks. Implement each one completely before
            \\moving to the next. If a task fails, note the failure and continue
            \\with remaining tasks.
            \\
        );
    }

    pub fn renderToString(self: *const PlanModePrompt, allocator: mem.Allocator) ![]const u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        try self.render(buffer.writer(allocator));
        return buffer.toOwnedSlice(allocator);
    }
};

test "FinalReviewPrompt - render" {
    const allocator = std.testing.allocator;

    const result = try FinalReviewPrompt.renderToString(allocator);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "final review") != null);
    try std.testing.expect(mem.indexOf(u8, result, "@SPEC.md") != null);
    try std.testing.expect(mem.indexOf(u8, result, "@VISION.md") != null);
}

test "PlanModePrompt - render" {
    const allocator = std.testing.allocator;

    const tasks = &[_]Task{
        .{
            .id = "task1",
            .title = "First Task",
            .description = "Do the first thing",
            .priority = 1,
            .tags = &.{},
        },
        .{
            .id = "task2",
            .title = "Second Task",
            .description = "Do the second thing",
            .priority = 2,
            .tags = &.{},
        },
    };

    const prompt = PlanModePrompt.init(tasks);
    const result = try prompt.renderToString(allocator);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Task Batch") != null);
    try std.testing.expect(mem.indexOf(u8, result, "First Task") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Second Task") != null);
    try std.testing.expect(mem.indexOf(u8, result, "task1") != null);
    try std.testing.expect(mem.indexOf(u8, result, "ATOMIC") != null);
}
