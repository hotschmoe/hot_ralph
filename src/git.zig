const std = @import("std");
const mem = std.mem;
const process = std.process;

pub const GitError = error{
    NotGitRepo,
    CommandFailed,
    NothingToCommit,
    OutOfMemory,
};

pub const Git = struct {
    allocator: mem.Allocator,
    project_dir: []const u8,

    pub fn init(allocator: mem.Allocator, project_dir: []const u8) Git {
        return Git{
            .allocator = allocator,
            .project_dir = project_dir,
        };
    }

    pub fn addAll(self: *Git) !void {
        _ = try self.runCommand(&.{ "git", "add", "-A" });
    }

    pub fn add(self: *Git, paths: []const []const u8) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "git");
        try args.append(self.allocator, "add");
        for (paths) |path| {
            try args.append(self.allocator, path);
        }

        _ = try self.runCommand(args.items);
    }

    pub fn commit(self: *Git, message: []const u8) !void {
        const result = self.runCommand(&.{ "git", "commit", "-m", message }) catch |err| {
            if (err == GitError.CommandFailed) {
                // Check if nothing to commit
                const git_status = try self.status();
                defer self.allocator.free(git_status);
                if (mem.indexOf(u8, git_status, "nothing to commit") != null) {
                    return GitError.NothingToCommit;
                }
            }
            return err;
        };
        self.allocator.free(result);
    }

    pub fn push(self: *Git) !void {
        _ = try self.runCommand(&.{ "git", "push" });
    }

    pub fn pushBackground(self: *Git) !std.Thread {
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(git: *Git) void {
                git.push() catch {};
            }
        }.run, .{self});
        return thread;
    }

    pub fn status(self: *Git) ![]const u8 {
        return try self.runCommand(&.{ "git", "status" });
    }

    pub fn isClean(self: *Git) !bool {
        const output = try self.runCommand(&.{ "git", "status", "--porcelain" });
        defer self.allocator.free(output);

        const trimmed = mem.trim(u8, output, &std.ascii.whitespace);
        return trimmed.len == 0;
    }

    pub fn diff(self: *Git) ![]const u8 {
        return try self.runCommand(&.{ "git", "diff" });
    }

    pub fn diffStaged(self: *Git) ![]const u8 {
        return try self.runCommand(&.{ "git", "diff", "--staged" });
    }

    pub fn currentBranch(self: *Git) ![]const u8 {
        const output = try self.runCommand(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        // Trim trailing newline
        return mem.trim(u8, output, "\n\r");
    }

    pub fn hasUncommittedChanges(self: *Git) !bool {
        return !(try self.isClean());
    }

    fn runCommand(self: *Git, args: []const []const u8) ![]const u8 {
        var child = process.Child.init(args, self.allocator);
        child.cwd = self.project_dir;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();

        const stdout = child.stdout orelse return GitError.CommandFailed;
        const output = stdout.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            return GitError.CommandFailed;
        };
        errdefer self.allocator.free(output);

        const result = child.wait() catch {
            return GitError.CommandFailed;
        };

        if (result.Exited != 0) {
            self.allocator.free(output);
            return GitError.CommandFailed;
        }

        return output;
    }
};

pub fn generateCommitMessage(task_title: []const u8, allocator: mem.Allocator) ![]const u8 {
    // Convert task title to commit message format
    // "Implement feature X" -> "Implement feature X"
    // Keep it simple - just use the task title directly

    return try std.fmt.allocPrint(allocator, "{s}\n\nCompleted via hot_ralph automation.", .{task_title});
}

pub fn generateBeadsCommitMessage(task_id: []const u8, allocator: mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "beads: Complete task {s}", .{task_id});
}

test "Git - init" {
    const allocator = std.testing.allocator;
    const git = Git.init(allocator, "/tmp/test");
    try std.testing.expectEqualStrings("/tmp/test", git.project_dir);
}

test "generateCommitMessage" {
    const allocator = std.testing.allocator;

    const msg = try generateCommitMessage("Implement feature X", allocator);
    defer allocator.free(msg);

    try std.testing.expect(mem.indexOf(u8, msg, "Implement feature X") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "hot_ralph automation") != null);
}

test "generateBeadsCommitMessage" {
    const allocator = std.testing.allocator;

    const msg = try generateBeadsCommitMessage("abc123", allocator);
    defer allocator.free(msg);

    try std.testing.expectEqualStrings("beads: Complete task abc123", msg);
}
