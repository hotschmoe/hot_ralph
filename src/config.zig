const std = @import("std");
const fs = std.fs;
const mem = std.mem;

pub const ConfigError = error{
    MissingSpecMd,
    MissingVisionMd,
    MissingTestingMd,
    MissingBeadsDir,
    NotGitRepo,
    ClaudeNotInstalled,
    BeadsNotInstalled,
    InvalidProjectDir,
    OutputDirCreateFailed,
};

pub const Config = struct {
    allocator: mem.Allocator,
    project_dir: []const u8,
    output_dir: []const u8,
    auto_mode: bool,
    help_requested: bool,
    version_requested: bool,
    dry_run: bool,
    silent: bool,
    quiet: bool,
    introspection_enabled: bool,
    plan_mode: bool,
    plan_mode_count: usize,

    const OUTPUT_DIR_NAME = ".hot_ralph";

    pub fn init(allocator: mem.Allocator, args: Args) !Config {
        const project_dir = if (args.project_dir) |dir|
            try allocator.dupe(u8, dir)
        else
            try std.fs.cwd().realpathAlloc(allocator, ".");

        const output_dir = try fs.path.join(allocator, &.{ project_dir, OUTPUT_DIR_NAME });

        return Config{
            .allocator = allocator,
            .project_dir = project_dir,
            .output_dir = output_dir,
            .auto_mode = args.auto_mode,
            .help_requested = args.help_requested,
            .version_requested = args.version_requested,
            .dry_run = args.dry_run,
            .silent = args.silent,
            .quiet = args.quiet,
            .introspection_enabled = args.introspection_enabled,
            .plan_mode = args.plan_mode,
            .plan_mode_count = args.plan_mode_count,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.output_dir);
        self.allocator.free(self.project_dir);
    }

    pub fn statePath(self: *const Config) ![]const u8 {
        return try fs.path.join(self.allocator, &.{ self.output_dir, "state.json" });
    }
};

pub const Args = struct {
    project_dir: ?[]const u8,
    auto_mode: bool,
    help_requested: bool,
    version_requested: bool,
    dry_run: bool,
    silent: bool,
    quiet: bool,
    introspection_enabled: bool,
    plan_mode: bool,
    plan_mode_count: usize,

    const DEFAULT_PLAN_MODE_COUNT: usize = 5;

    pub fn parse(allocator: mem.Allocator) !Args {
        var args_iter = try std.process.argsWithAllocator(allocator);
        defer args_iter.deinit();

        _ = args_iter.next(); // skip program name

        // Collect remaining args for two-pass parsing
        var collected: std.ArrayList([]const u8) = .empty;
        defer collected.deinit(allocator);

        while (args_iter.next()) |arg| {
            try collected.append(allocator, arg);
        }

        var result = Args{
            .project_dir = null,
            .auto_mode = false,
            .help_requested = false,
            .version_requested = false,
            .dry_run = false,
            .silent = false,
            .quiet = false,
            .introspection_enabled = false,
            .plan_mode = false,
            .plan_mode_count = DEFAULT_PLAN_MODE_COUNT,
        };

        var i: usize = 0;
        while (i < collected.items.len) : (i += 1) {
            const arg = collected.items[i];
            if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
                result.help_requested = true;
            } else if (mem.eql(u8, arg, "--version") or mem.eql(u8, arg, "-V")) {
                result.version_requested = true;
            } else if (mem.eql(u8, arg, "--auto") or mem.eql(u8, arg, "-a")) {
                result.auto_mode = true;
            } else if (mem.eql(u8, arg, "--dry-run")) {
                result.dry_run = true;
            } else if (mem.eql(u8, arg, "--silent") or mem.eql(u8, arg, "-s")) {
                result.silent = true;
            } else if (mem.eql(u8, arg, "--quiet") or mem.eql(u8, arg, "-q")) {
                result.quiet = true;
            } else if (mem.eql(u8, arg, "--introspection") or mem.eql(u8, arg, "-i")) {
                result.introspection_enabled = true;
            } else if (mem.eql(u8, arg, "--planmode") or mem.eql(u8, arg, "-p")) {
                result.plan_mode = true;
                // Check if next arg is a number for plan_mode_count
                if (i + 1 < collected.items.len) {
                    const next = collected.items[i + 1];
                    if (!mem.startsWith(u8, next, "-")) {
                        if (std.fmt.parseInt(usize, next, 10)) |count| {
                            result.plan_mode_count = count;
                            i += 1; // consume the count arg
                        } else |_| {
                            // Not a number, leave for project_dir handling
                        }
                    }
                }
            } else if (!mem.startsWith(u8, arg, "-")) {
                result.project_dir = arg;
            }
        }

        return result;
    }
};

pub fn checkRequirements(config: *const Config) !void {
    const project_dir = config.project_dir;

    // Check required files exist
    try checkFileExists(config.allocator, project_dir, "SPEC.md", ConfigError.MissingSpecMd);
    try checkFileExists(config.allocator, project_dir, "VISION.md", ConfigError.MissingVisionMd);
    try checkFileExists(config.allocator, project_dir, "TESTING.md", ConfigError.MissingTestingMd);

    // Check .beads/ directory exists
    try checkDirExists(config.allocator, project_dir, ".beads", ConfigError.MissingBeadsDir);

    // Check .git/ directory exists
    try checkDirExists(config.allocator, project_dir, ".git", ConfigError.NotGitRepo);

    // Check external commands are available
    try checkCommandExists(config.allocator, "claude", ConfigError.ClaudeNotInstalled);
    try checkCommandExists(config.allocator, "br", ConfigError.BeadsNotInstalled);
}

pub fn ensureOutputDir(config: *const Config) !void {
    fs.makeDirAbsolute(config.output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return ConfigError.OutputDirCreateFailed,
    };
}

fn checkFileExists(allocator: mem.Allocator, base_dir: []const u8, filename: []const u8, err_val: ConfigError) !void {
    const path = try fs.path.join(allocator, &.{ base_dir, filename });
    defer allocator.free(path);

    fs.accessAbsolute(path, .{}) catch {
        return err_val;
    };
}

fn checkDirExists(allocator: mem.Allocator, base_dir: []const u8, dirname: []const u8, err_val: ConfigError) !void {
    const path = try fs.path.join(allocator, &.{ base_dir, dirname });
    defer allocator.free(path);

    var dir = fs.openDirAbsolute(path, .{}) catch {
        return err_val;
    };
    dir.close();
}

fn checkCommandExists(allocator: mem.Allocator, command: []const u8, err_val: ConfigError) !void {
    const builtin = @import("builtin");
    const which_cmd = if (builtin.os.tag == .windows) "where" else "which";

    var child = std.process.Child.init(&.{ which_cmd, command }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    const result = child.spawnAndWait() catch return err_val;

    if (result.Exited != 0) {
        return err_val;
    }
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\hot_ralph - Atomic task execution with Claude and Beads
        \\
        \\USAGE:
        \\    hot_ralph [OPTIONS] [PROJECT_DIR]
        \\
        \\ARGS:
        \\    PROJECT_DIR    Path to project directory (default: current directory)
        \\
        \\OPTIONS:
        \\    -a, --auto          Auto mode: skip all prompts, assume yes
        \\    -h, --help          Show this help message
        \\    -V, --version       Show version information
        \\    --dry-run           Preview mode: show what would be done without executing
        \\    -s, --silent        Silent mode: don't stream Claude responses to terminal
        \\    -q, --quiet         Quiet mode: minimal output
        \\    -i, --introspection Enable periodic introspection after every 5 tasks
        \\    -p, --planmode [N]  Plan mode: batch N related tasks into single session (default: 5)
        \\
        \\REQUIREMENTS:
        \\    Project directory must contain:
        \\      - SPEC.md     Project specification
        \\      - VISION.md   Project vision
        \\      - TESTING.md  Testing requirements
        \\      - .beads/     Beads task tracking directory
        \\      - .git/       Git repository
        \\
        \\    External commands (must be in PATH):
        \\      - claude      Anthropic Claude CLI
        \\      - br          Beads Rust CLI
        \\      - git         Version control
        \\
        \\EXIT CODES:
        \\    0    Success - all tasks complete
        \\    1    Error - missing requirements
        \\    2    Error - Beads operation failed
        \\    3    Error - Claude operation failed (unknown)
        \\    4    Error - Git operation failed
        \\    5    Error - Claude subscription/quota limit
        \\    6    Error - Claude authentication error
        \\    7    Error - Claude rate limit exceeded
        \\    8    Error - Claude network failure
        \\    9    Error - Claude malformed response
        \\    130  Interrupted (Ctrl+C)
        \\
    );
}

pub fn printVersion(writer: anytype) !void {
    try writer.writeAll("hot_ralph 0.4.0\n");
}

test "Args.parse - default values" {
    const args = Args{
        .project_dir = null,
        .auto_mode = false,
        .help_requested = false,
        .version_requested = false,
        .dry_run = false,
        .silent = false,
        .quiet = false,
        .introspection_enabled = false,
        .plan_mode = false,
        .plan_mode_count = Args.DEFAULT_PLAN_MODE_COUNT,
    };
    try std.testing.expect(args.project_dir == null);
    try std.testing.expect(!args.auto_mode);
    try std.testing.expect(!args.help_requested);
    try std.testing.expect(!args.version_requested);
    try std.testing.expect(!args.dry_run);
    try std.testing.expect(!args.silent);
    try std.testing.expect(!args.quiet);
    try std.testing.expect(!args.introspection_enabled);
    try std.testing.expect(!args.plan_mode);
    try std.testing.expectEqual(@as(usize, 5), args.plan_mode_count);
}

test "Config.init - with project dir" {
    const allocator = std.testing.allocator;
    const args = Args{
        .project_dir = "/tmp/test",
        .auto_mode = true,
        .help_requested = false,
        .version_requested = false,
        .dry_run = true,
        .silent = false,
        .quiet = true,
        .introspection_enabled = false,
        .plan_mode = false,
        .plan_mode_count = 7,
    };

    var config = try Config.init(allocator, args);
    defer config.deinit();

    try std.testing.expectEqualStrings("/tmp/test", config.project_dir);
    try std.testing.expect(config.auto_mode);
    try std.testing.expect(config.dry_run);
    try std.testing.expect(config.quiet);
    try std.testing.expect(mem.endsWith(u8, config.output_dir, ".hot_ralph"));
    try std.testing.expectEqual(@as(usize, 7), config.plan_mode_count);
}
