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

    pub fn parse(allocator: mem.Allocator) !Args {
        var args_iter = try std.process.argsWithAllocator(allocator);
        defer args_iter.deinit();

        _ = args_iter.next(); // skip program name

        var result = Args{
            .project_dir = null,
            .auto_mode = false,
            .help_requested = false,
            .version_requested = false,
        };

        while (args_iter.next()) |arg| {
            if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
                result.help_requested = true;
            } else if (mem.eql(u8, arg, "--version") or mem.eql(u8, arg, "-V")) {
                result.version_requested = true;
            } else if (mem.eql(u8, arg, "--auto") or mem.eql(u8, arg, "-a")) {
                result.auto_mode = true;
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
    // On Windows, append .exe if not present and check common locations
    const cmd = if (@import("builtin").os.tag == .windows and !mem.endsWith(u8, command, ".exe"))
        try std.fmt.allocPrint(allocator, "{s}.exe", .{command})
    else
        try allocator.dupe(u8, command);
    defer allocator.free(cmd);

    // Try to find command in PATH using 'where' on Windows, 'which' on Unix
    const which_cmd = if (@import("builtin").os.tag == .windows) "where" else "which";

    var child = std.process.Child.init(&.{ which_cmd, cmd }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    _ = child.spawnAndWait() catch {
        return err_val;
    };
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\ralph - Atomic task execution with Claude and Beads
        \\
        \\USAGE:
        \\    ralph [OPTIONS] [PROJECT_DIR]
        \\
        \\ARGS:
        \\    PROJECT_DIR    Path to project directory (default: current directory)
        \\
        \\OPTIONS:
        \\    -a, --auto     Auto mode: skip all prompts, assume yes
        \\    -h, --help     Show this help message
        \\    -V, --version  Show version information
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
        \\    3    Error - Claude operation failed
        \\    130  Interrupted (Ctrl+C)
        \\
    );
}

pub fn printVersion(writer: anytype) !void {
    try writer.writeAll("ralph 0.1.0\n");
}

test "Args.parse - default values" {
    const allocator = std.testing.allocator;
    // Note: In actual usage, this would parse real process args
    // This test verifies the struct defaults
    const args = Args{
        .project_dir = null,
        .auto_mode = false,
        .help_requested = false,
        .version_requested = false,
    };
    try std.testing.expect(args.project_dir == null);
    try std.testing.expect(!args.auto_mode);
    try std.testing.expect(!args.help_requested);
    try std.testing.expect(!args.version_requested);
    _ = allocator;
}

test "Config.init - with project dir" {
    const allocator = std.testing.allocator;
    const args = Args{
        .project_dir = "/tmp/test",
        .auto_mode = true,
        .help_requested = false,
        .version_requested = false,
    };

    var config = try Config.init(allocator, args);
    defer config.deinit();

    try std.testing.expectEqualStrings("/tmp/test", config.project_dir);
    try std.testing.expect(config.auto_mode);
    try std.testing.expect(mem.endsWith(u8, config.output_dir, ".hot_ralph"));
}
