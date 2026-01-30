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
    verbose: bool,
    quiet: bool,
    introspection_enabled: bool,

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
            .verbose = args.verbose,
            .quiet = args.quiet,
            .introspection_enabled = args.introspection_enabled,
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
    verbose: bool,
    quiet: bool,
    introspection_enabled: bool,

    pub fn parse(allocator: mem.Allocator) !Args {
        var args_iter = try std.process.argsWithAllocator(allocator);
        defer args_iter.deinit();

        _ = args_iter.next(); // skip program name

        var result = Args{
            .project_dir = null,
            .auto_mode = false,
            .help_requested = false,
            .version_requested = false,
            .dry_run = false,
            .verbose = false,
            .quiet = false,
            .introspection_enabled = false,
        };

        while (args_iter.next()) |arg| {
            if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
                result.help_requested = true;
            } else if (mem.eql(u8, arg, "--version") or mem.eql(u8, arg, "-V")) {
                result.version_requested = true;
            } else if (mem.eql(u8, arg, "--auto") or mem.eql(u8, arg, "-a")) {
                result.auto_mode = true;
            } else if (mem.eql(u8, arg, "--dry-run")) {
                result.dry_run = true;
            } else if (mem.eql(u8, arg, "--verbose") or mem.eql(u8, arg, "-v")) {
                result.verbose = true;
            } else if (mem.eql(u8, arg, "--quiet") or mem.eql(u8, arg, "-q")) {
                result.quiet = true;
            } else if (mem.eql(u8, arg, "--introspection") or mem.eql(u8, arg, "-i")) {
                result.introspection_enabled = true;
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
        \\    -v, --verbose       Verbose output: stream Claude responses to terminal
        \\    -q, --quiet         Quiet mode: minimal output
        \\    -i, --introspection Enable periodic introspection after every 5 tasks
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
    try writer.writeAll("hot_ralph 0.2.0\n");
}

test "Args.parse - default values" {
    const args = Args{
        .project_dir = null,
        .auto_mode = false,
        .help_requested = false,
        .version_requested = false,
        .dry_run = false,
        .verbose = false,
        .quiet = false,
        .introspection_enabled = false,
    };
    try std.testing.expect(args.project_dir == null);
    try std.testing.expect(!args.auto_mode);
    try std.testing.expect(!args.help_requested);
    try std.testing.expect(!args.version_requested);
    try std.testing.expect(!args.dry_run);
    try std.testing.expect(!args.verbose);
    try std.testing.expect(!args.quiet);
    try std.testing.expect(!args.introspection_enabled);
}

test "Config.init - with project dir" {
    const allocator = std.testing.allocator;
    const args = Args{
        .project_dir = "/tmp/test",
        .auto_mode = true,
        .help_requested = false,
        .version_requested = false,
        .dry_run = true,
        .verbose = false,
        .quiet = true,
        .introspection_enabled = false,
    };

    var config = try Config.init(allocator, args);
    defer config.deinit();

    try std.testing.expectEqualStrings("/tmp/test", config.project_dir);
    try std.testing.expect(config.auto_mode);
    try std.testing.expect(config.dry_run);
    try std.testing.expect(config.quiet);
    try std.testing.expect(mem.endsWith(u8, config.output_dir, ".hot_ralph"));
}
