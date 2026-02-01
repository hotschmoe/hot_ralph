const std = @import("std");
const ralph = @import("hot_ralph");
const mem = std.mem;
const fs = std.fs;
const io = std.io;

// Exit codes
const EXIT_SUCCESS: u8 = 0;
const EXIT_REQUIREMENTS: u8 = 1;
const EXIT_BEADS: u8 = 2;
const EXIT_CLAUDE: u8 = 3;
const EXIT_GIT: u8 = 4;
const EXIT_SUBSCRIPTION: u8 = 5;
const EXIT_AUTH: u8 = 6;
const EXIT_RATE_LIMIT: u8 = 7;
const EXIT_NETWORK: u8 = 8;
const EXIT_MALFORMED: u8 = 9;
const EXIT_INTERRUPTED: u8 = 130;

fn logFatalError(
    allocator: mem.Allocator,
    output_dir: []const u8,
    error_type: ralph.claude.FatalErrorType,
    message: []const u8,
) void {
    const ts = std.time.timestamp();
    const filename = std.fmt.allocPrint(allocator, "{d}_error.md", .{ts}) catch return;
    defer allocator.free(filename);

    const path = fs.path.join(allocator, &.{ output_dir, filename }) catch return;
    defer allocator.free(path);

    const file = fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);

    writer.interface.print(
        \\# Fatal Error Log
        \\
        \\**Type**: {s}
        \\**Exit Code**: {d}
        \\**Timestamp**: {d}
        \\
        \\## Message
        \\
        \\{s}
        \\
    , .{
        error_type.toString(),
        error_type.toExitCode(),
        ts,
        message,
    }) catch {};
    writer.interface.flush() catch {};
}

fn handleFatalClaudeError(
    allocator: mem.Allocator,
    config: *const ralph.Config,
    beads: *ralph.Beads,
    state_path: []const u8,
    ui: *ralph.UI,
    error_type: ralph.claude.FatalErrorType,
    message: []const u8,
) u8 {
    // Log the error
    logFatalError(allocator, config.output_dir, error_type, message);

    // Display error to user
    ui.errFmt("Fatal Claude error: {s}", .{error_type.toString()}) catch {};
    ui.errFmt("Details: {s}", .{message}) catch {};

    // Sync beads before exiting
    syncBeadsAndExit(beads, state_path, ui) catch {};

    return error_type.toExitCode();
}

fn shouldRetry(error_type: ralph.claude.FatalErrorType) bool {
    return error_type == .network_failure or error_type == .rate_limit;
}

pub fn main() u8 {
    return run() catch |err| {
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer = fs.File.stderr().writer(&stderr_buf);
        stderr_writer.interface.print("Fatal error: {s}\n", .{@errorName(err)}) catch {};
        stderr_writer.interface.flush() catch {};
        return EXIT_REQUIREMENTS;
    };
}

fn run() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    const args = try ralph.Args.parse(allocator);

    // Handle --help
    if (args.help_requested) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = fs.File.stdout().writer(&stdout_buf);
        ralph.config.printHelp(&stdout_writer.interface) catch {};
        stdout_writer.interface.flush() catch {};
        return EXIT_SUCCESS;
    }

    // Handle --version
    if (args.version_requested) {
        var stdout_buf: [256]u8 = undefined;
        var stdout_writer = fs.File.stdout().writer(&stdout_buf);
        ralph.config.printVersion(&stdout_writer.interface) catch {};
        stdout_writer.interface.flush() catch {};
        return EXIT_SUCCESS;
    }

    // Initialize config
    var config = try ralph.Config.init(allocator, args);
    defer config.deinit();

    // Initialize UI
    var ui = ralph.UI.init(allocator, config.auto_mode, !config.silent, config.quiet);

    // Check requirements
    ralph.config.checkRequirements(&config) catch |err| {
        try ui.errFmt("Missing requirement: {s}", .{@errorName(err)});
        try ui.info("");
        try ui.info("Required files: SPEC.md, VISION.md, TESTING.md");
        try ui.info("Required directories: .beads/, .git/");
        try ui.info("Required commands: claude, br");
        return EXIT_REQUIREMENTS;
    };

    // Ensure output directory exists
    try ralph.config.ensureOutputDir(&config);

    // Construct stop file path for graceful exit detection
    const stop_file_path = try fs.path.join(allocator, &.{ config.output_dir, "stop" });
    defer allocator.free(stop_file_path);

    // Clear any stale stop file from previous run
    clearStopFile(stop_file_path, &ui);

    // Load existing state (if any)
    const state_path = try config.statePath();
    defer allocator.free(state_path);

    var state = if (try ralph.State.load(allocator, state_path)) |existing_state| blk: {
        // Found existing state - offer to resume
        if (existing_state.current_task_id) |task_id| {
            const should_resume = try ui.promptResume(task_id);
            if (should_resume) {
                try ui.statusFmt("Resuming task {s}", .{task_id});
                break :blk existing_state;
            }
        }
        // Clear old state
        var s = existing_state;
        s.deinit();
        break :blk ralph.State.init(allocator);
    } else ralph.State.init(allocator);
    defer state.deinit();

    // Initialize Beads
    var beads = ralph.Beads.init(allocator, config.project_dir);

    // Initialize Git
    var git = ralph.Git.init(allocator, config.project_dir);

    // Initialize Claude
    var claude = ralph.Claude.init(allocator);

    // Verify claude is installed
    claude.checkInstalled() catch {
        try ui.err("Claude CLI not found. Please install: https://claude.ai/download");
        return EXIT_REQUIREMENTS;
    };

    // Initialize exit monitor for graceful 'e' key exit
    var exit_monitor = ralph.ExitMonitor.init(allocator);
    defer exit_monitor.deinit();

    // Start monitoring in background (always, for both auto and non-auto mode)
    exit_monitor.start() catch {
        // Non-fatal: continue without exit monitoring
    };

    // Plan mode: batch execute related tasks
    if (config.plan_mode) {
        return runPlanMode(
            allocator,
            &config,
            &beads,
            &git,
            &claude,
            &state,
            state_path,
            &ui,
        );
    }

    // Main loop
    var tasks_completed: usize = 0;
    var push_probability: u8 = 0;

    while (!exit_monitor.shouldExit()) {
        // Get ready count
        const ready_count = beads.readyCount() catch |err| {
            try ui.errFmt("Failed to get ready tasks: {s}", .{@errorName(err)});
            return EXIT_BEADS;
        };

        if (ready_count == 0) {
            try ui.info("\nNo ready tasks remaining.");
            break;
        }

        const blocked_count = beads.blockedCount() catch 0;

        // Get next task
        var task = beads.getNextReady() catch |err| {
            try ui.errFmt("Failed to get next task: {s}", .{@errorName(err)});
            return EXIT_BEADS;
        } orelse {
            try ui.info("\nNo ready tasks remaining.");
            break;
        };
        defer task.deinit();

        // Display task
        try ui.displayTask(.{
            .id = task.id,
            .title = task.title,
            .description = task.description,
            .priority = task.priority,
            .tags = task.tags,
            .blocks = task.blocks,
        }, ready_count, blocked_count);

        // Prompt for execution
        const exec_choice = try ui.promptExecute();

        switch (exec_choice) {
            .quit => {
                try ui.info("\nExiting...");
                break;
            },
            .skip => {
                try ui.info("Skipping task.");
                continue;
            },
            .view_all => {
                const all_tasks = beads.getAllReady() catch {
                    try ui.err("Failed to get all tasks");
                    continue;
                };
                defer {
                    for (all_tasks) |*t| {
                        t.deinit();
                    }
                    allocator.free(all_tasks);
                }

                // Convert to UI task format
                var ui_tasks = try allocator.alloc(ralph.ui.Task, all_tasks.len);
                defer allocator.free(ui_tasks);

                for (all_tasks, 0..) |t, i| {
                    ui_tasks[i] = .{
                        .id = t.id,
                        .title = t.title,
                        .description = t.description,
                        .priority = t.priority,
                        .tags = t.tags,
                        .blocks = t.blocks,
                    };
                }

                try ui.displayAllTasks(ui_tasks);
                continue;
            },
            .no => {
                try ui.info("Task declined.");
                continue;
            },
            .yes => {},
        }

        // Dry-run mode: show what would be done without executing
        if (config.dry_run) {
            try ui.statusFmt("DRY-RUN: Would execute task {s}", .{task.id});
            // Break instead of continue - we can't claim tasks in dry-run,
            // so continuing would loop on the same task forever
            break;
        }

        // Claim the task
        beads.claim(task.id) catch |err| {
            try ui.errFmt("Failed to claim task: {s}", .{@errorName(err)});
            return EXIT_BEADS;
        };

        // Update state
        const task_label = try std.fmt.allocPrint(allocator, "task_{s}", .{task.id});
        defer allocator.free(task_label);

        const output_filename = try ralph.ui.generateOutputFilename(
            allocator,
            config.output_dir,
            task_label,
        );
        defer allocator.free(output_filename);

        try state.setTask(task.id, output_filename);
        try state.save(state_path);

        try ui.statusFmt("Executing task {s}...", .{task.id});
        try ui.statusFmt("Output: {s}", .{output_filename});

        // Generate prompt
        const prompt_task = ralph.prompt.Task{
            .id = task.id,
            .title = task.title,
            .description = task.description,
            .priority = task.priority,
            .tags = task.tags,
        };
        const task_prompt = ralph.TaskPrompt.init(prompt_task);
        const prompt_text = try task_prompt.renderToString(allocator);
        defer allocator.free(prompt_text);

        // Run Claude with retry logic for transient errors
        const result = try runClaudeWithRetry(allocator, &claude, prompt_text, .{
            .output_file = output_filename,
            .stream_to_terminal = !config.silent,
            .working_dir = config.project_dir,
        }, &ui);

        switch (result) {
            .interrupted => {
                try ui.info("\nInterrupted.");
                try syncBeadsAndExit(&beads, state_path, &ui);
                return EXIT_INTERRUPTED;
            },
            .failure => |f| {
                defer allocator.free(f.message);
                if (f.error_type != .unknown) {
                    return handleFatalClaudeError(
                        allocator,
                        &config,
                        &beads,
                        state_path,
                        &ui,
                        f.error_type,
                        f.message,
                    );
                }
                try ui.errFmt("Claude failed: {s}", .{f.message});
                state.phase = .idle;
                try state.save(state_path);
                continue;
            },
            .success => |s| {
                allocator.free(s.response_text);
                try ui.statusFmt("Output saved to: {s}", .{s.output_file});
            },
        }

        // Prompt for success confirmation
        state.phase = .awaiting_confirmation;
        try state.save(state_path);

        const success_choice = try ui.promptSuccess();

        switch (success_choice) {
            .no => {
                try ui.info("Task marked as failed. Continuing...");
                state.clearTask();
                try state.save(state_path);
                continue;
            },
            .retry => {
                try ui.info("Retrying task...");
                // Don't clear task, loop will re-run
                continue;
            },
            .yes => {},
        }

        // Complete the task
        beads.complete(task.id, "Completed via hot_ralph") catch |err| {
            try ui.errFmt("Failed to complete task: {s}", .{@errorName(err)});
            return EXIT_BEADS;
        };

        try ui.statusFmt("Task {s} completed.", .{task.id});

        // Simplification pass
        simplify: {
            state.phase = .simplifying;
            try state.save(state_path);

            try ui.status("Running simplification pass...");
            const simplify_prompt = ralph.SimplificationPrompt.init(task.title);
            const simplify_text = simplify_prompt.renderToString(allocator) catch {
                try ui.info("Simplification pass skipped (prompt error)");
                state.phase = .idle;
                break :simplify;
            };
            defer allocator.free(simplify_text);

            const label = std.fmt.allocPrint(allocator, "simplify_{s}", .{task.id}) catch {
                try ui.info("Simplification pass skipped (format error)");
                state.phase = .idle;
                break :simplify;
            };
            defer allocator.free(label);

            const simplify_output = ralph.ui.generateOutputFilename(allocator, config.output_dir, label) catch {
                try ui.info("Simplification pass skipped (output path error)");
                state.phase = .idle;
                break :simplify;
            };
            defer allocator.free(simplify_output);

            if (claude.run(simplify_text, .{
                .output_file = simplify_output,
                .stream_to_terminal = !config.silent,
                .working_dir = config.project_dir,
            })) |simplify_result| {
                freeRunResult(allocator, simplify_result);
                try ui.status("Simplification complete.");
            } else |_| {
                try ui.info("Simplification pass skipped (Claude error)");
            }
            state.phase = .idle;
        }

        // Git commit
        git.addAll() catch |err| {
            try ui.errFmt("Git add failed: {s}", .{@errorName(err)});
        };

        const commit_msg = try ralph.git.generateCommitMessage(task.title, allocator);
        defer allocator.free(commit_msg);

        git.commit(commit_msg) catch |err| {
            if (err == ralph.GitError.NothingToCommit) {
                try ui.info("No changes to commit.");
            } else {
                try ui.errFmt("Git commit failed: {s}", .{@errorName(err)});
            }
        };

        // Periodic background push (20% chance)
        push_probability += 20;
        if (push_probability >= 100) {
            push_probability = 0;
            try ui.status("Pushing to remote (background)...");
            _ = git.pushBackground() catch {};
        }

        // Update counters
        tasks_completed += 1;
        state.incrementTaskCount();
        state.clearTask();
        try state.save(state_path);

        // Periodic introspection (every 5 tasks when enabled)
        const INTROSPECTION_INTERVAL: u32 = 5;
        if (config.introspection_enabled and state.tasks_since_introspection >= INTROSPECTION_INTERVAL) {
            try runIntrospection(allocator, &config, &claude, &state, state_path, &ui);
        }

        // Countdown between tasks (allows graceful exit in auto mode)
        const should_continue = try ui.countdownWithExitCheck(5, &exit_monitor, stop_file_path);
        if (!should_continue) {
            clearStopFile(stop_file_path, &ui);
            break;
        }
    }

    // Check if exit was requested via 'e' key
    if (exit_monitor.shouldExit()) {
        try ui.info("\nExit requested. Finishing up...");
    }

    // Final sync
    try syncBeadsAndExit(&beads, state_path, &ui);

    // Final review (if tasks were completed and not in dry-run mode)
    review: {
        if (tasks_completed == 0 or config.dry_run) break :review;
        try ui.status("Running final review...");

        const review_text = try ralph.FinalReviewPrompt.renderToString(allocator);
        defer allocator.free(review_text);

        const review_output = try ralph.ui.generateOutputFilename(allocator, config.output_dir, "final_review");
        defer allocator.free(review_output);

        if (claude.run(review_text, .{
            .output_file = review_output,
            .stream_to_terminal = !config.silent,
            .working_dir = config.project_dir,
        })) |review_result| {
            freeRunResult(allocator, review_result);
            try ui.status("Final review complete.");
        } else |_| {
            try ui.info("Final review skipped (Claude error)");
        }
    }

    // Display summary
    try ui.displayComplete(tasks_completed);

    return EXIT_SUCCESS;
}

const PLAN_MODE_LIMIT: usize = 10;
const MAX_RETRIES: u8 = 3;

fn runClaudeWithRetry(
    allocator: mem.Allocator,
    claude: *ralph.Claude,
    prompt: []const u8,
    opts: ralph.claude.RunOptions,
    ui: *ralph.UI,
) !ralph.RunResult {
    var retry_count: u8 = 0;
    while (retry_count < MAX_RETRIES) : (retry_count += 1) {
        const result = claude.run(prompt, opts) catch |err| {
            try ui.errFmt("Claude execution failed: {s}", .{@errorName(err)});
            return ralph.RunResult{
                .failure = .{
                    .message = allocator.dupe(u8, @errorName(err)) catch "",
                    .error_type = .unknown,
                },
            };
        };

        switch (result) {
            .failure => |f| {
                if (shouldRetry(f.error_type) and retry_count + 1 < MAX_RETRIES) {
                    const wait_seconds: u64 = @as(u64, 1) << @as(u6, @intCast(retry_count));
                    try ui.statusFmt("Transient error ({s}), retrying in {d}s...", .{
                        f.error_type.toString(),
                        wait_seconds,
                    });
                    allocator.free(f.message);
                    std.Thread.sleep(wait_seconds * std.time.ns_per_s);
                    continue;
                }
                return result;
            },
            else => return result,
        }
    }

    return ralph.RunResult{
        .failure = .{
            .message = allocator.dupe(u8, "Max retries exceeded") catch "",
            .error_type = .network_failure,
        },
    };
}

fn freeRunResult(allocator: mem.Allocator, result: ralph.RunResult) void {
    switch (result) {
        .success => |s| allocator.free(s.response_text),
        .failure => |f| allocator.free(f.message),
        .interrupted => {},
    }
}

fn runPlanMode(
    allocator: mem.Allocator,
    config: *const ralph.Config,
    beads: *ralph.Beads,
    git: *ralph.Git,
    claude: *ralph.Claude,
    state: *ralph.State,
    state_path: []const u8,
    ui: *ralph.UI,
) !u8 {
    // Get anchor task (highest priority ready)
    var anchor = beads.getNextReady() catch |err| {
        try ui.errFmt("Failed to get anchor task: {s}", .{@errorName(err)});
        return EXIT_BEADS;
    } orelse {
        try ui.info("\nNo ready tasks for plan mode.");
        return EXIT_SUCCESS;
    };
    defer anchor.deinit();

    // Get related beads (5-10 tasks)
    const related_tasks = beads.getRelatedBeads(&anchor, PLAN_MODE_LIMIT) catch |err| {
        try ui.errFmt("Failed to get related tasks: {s}", .{@errorName(err)});
        return EXIT_BEADS;
    };
    defer {
        for (related_tasks) |*t| t.deinit();
        allocator.free(related_tasks);
    }

    if (related_tasks.len == 0) {
        try ui.info("\nNo tasks available for plan mode.");
        return EXIT_SUCCESS;
    }

    // Convert to UI task format for display
    var ui_tasks = try allocator.alloc(ralph.ui.Task, related_tasks.len);
    defer allocator.free(ui_tasks);

    for (related_tasks, 0..) |t, i| {
        ui_tasks[i] = .{
            .id = t.id,
            .title = t.title,
            .description = t.description,
            .priority = t.priority,
            .tags = t.tags,
            .blocks = t.blocks,
        };
    }

    // Display plan overview
    try ui.displayPlanOverview(ui_tasks);

    // Dry-run mode: show what would be done without executing
    if (config.dry_run) {
        try ui.status("DRY-RUN: Would execute the above plan");
        return EXIT_SUCCESS;
    }

    // Prompt for approval
    const approved = try ui.promptPlanApproval();
    if (!approved) {
        try ui.info("Plan rejected.");
        return EXIT_SUCCESS;
    }

    // Store task IDs for state tracking
    var task_ids = try allocator.alloc([]const u8, related_tasks.len);
    defer allocator.free(task_ids);
    for (related_tasks, 0..) |t, i| {
        task_ids[i] = t.id;
    }

    // Update state with planned beads
    try state.setPlanMode(task_ids);
    state.plan_phase = .executing;
    try state.save(state_path);

    // Claim all tasks
    for (related_tasks) |t| {
        beads.claim(t.id) catch |err| {
            try ui.errFmt("Failed to claim task {s}: {s}", .{ t.id, @errorName(err) });
        };
    }

    // Generate plan mode output filename
    const output_filename = try ralph.ui.generateOutputFilename(
        allocator,
        config.output_dir,
        "plan_mode",
    );
    defer allocator.free(output_filename);

    // Convert to prompt Task format
    var prompt_tasks = try allocator.alloc(ralph.prompt.Task, related_tasks.len);
    defer allocator.free(prompt_tasks);

    for (related_tasks, 0..) |t, i| {
        prompt_tasks[i] = .{
            .id = t.id,
            .title = t.title,
            .description = t.description,
            .priority = t.priority,
            .tags = t.tags,
        };
    }

    // Generate plan mode prompt
    const plan_prompt = ralph.prompt.PlanModePrompt.init(prompt_tasks);
    const prompt_text = try plan_prompt.renderToString(allocator);
    defer allocator.free(prompt_text);

    try ui.statusFmt("Executing plan with {d} tasks...", .{related_tasks.len});
    try ui.statusFmt("Output: {s}", .{output_filename});

    // Run Claude with retry logic
    const result = try runClaudeWithRetry(allocator, claude, prompt_text, .{
        .output_file = output_filename,
        .stream_to_terminal = !config.silent,
        .working_dir = config.project_dir,
    }, ui);

    switch (result) {
        .interrupted => {
            try ui.info("\nPlan execution interrupted.");
            try syncBeadsAndExit(beads, state_path, ui);
            return EXIT_INTERRUPTED;
        },
        .failure => |f| {
            defer allocator.free(f.message);
            if (f.error_type != .unknown) {
                return handleFatalClaudeError(
                    allocator,
                    config,
                    beads,
                    state_path,
                    ui,
                    f.error_type,
                    f.message,
                );
            }
            try ui.errFmt("Plan execution failed: {s}", .{f.message});
            state.clearPlanMode();
            try state.save(state_path);
            return EXIT_CLAUDE;
        },
        .success => |s| {
            allocator.free(s.response_text);
            try ui.statusFmt("Plan output saved to: {s}", .{s.output_file});
        },
    }

    // Mark all beads as complete
    for (related_tasks) |t| {
        beads.complete(t.id, "Completed via hot_ralph plan mode") catch |err| {
            try ui.errFmt("Failed to complete task {s}: {s}", .{ t.id, @errorName(err) });
        };
    }

    try ui.statusFmt("Plan completed: {d} tasks", .{related_tasks.len});

    // Run simplification pass
    state.phase = .simplifying;
    try state.save(state_path);

    try ui.status("Running simplification pass...");
    const simplify_prompt = ralph.SimplificationPrompt.init("Plan mode batch");
    const simplify_text = simplify_prompt.renderToString(allocator) catch {
        try ui.info("Simplification pass skipped (prompt error)");
        state.phase = .idle;
        state.clearPlanMode();
        try state.save(state_path);
        return EXIT_SUCCESS;
    };
    defer allocator.free(simplify_text);

    const simplify_output = ralph.ui.generateOutputFilename(allocator, config.output_dir, "plan_simplify") catch {
        try ui.info("Simplification pass skipped (output path error)");
        state.phase = .idle;
        state.clearPlanMode();
        try state.save(state_path);
        return EXIT_SUCCESS;
    };
    defer allocator.free(simplify_output);

    if (claude.run(simplify_text, .{
        .output_file = simplify_output,
        .stream_to_terminal = !config.silent,
        .working_dir = config.project_dir,
    })) |simplify_result| {
        freeRunResult(allocator, simplify_result);
        try ui.status("Simplification complete.");
    } else |_| {
        try ui.info("Simplification pass skipped (Claude error)");
    }

    // Git commit for all changes
    git.addAll() catch |err| {
        try ui.errFmt("Git add failed: {s}", .{@errorName(err)});
    };

    const commit_msg = try std.fmt.allocPrint(allocator, "Plan mode: complete {d} tasks", .{related_tasks.len});
    defer allocator.free(commit_msg);

    git.commit(commit_msg) catch |err| {
        if (err == ralph.GitError.NothingToCommit) {
            try ui.info("No changes to commit.");
        } else {
            try ui.errFmt("Git commit failed: {s}", .{@errorName(err)});
        }
    };

    // Clear plan state
    state.phase = .idle;
    state.plan_phase = .complete;
    state.clearPlanMode();
    try state.save(state_path);

    // Sync and cleanup
    try syncBeadsAndExit(beads, state_path, ui);

    try ui.displayComplete(related_tasks.len);

    return EXIT_SUCCESS;
}

fn syncBeadsAndExit(
    beads: *ralph.Beads,
    state_path: []const u8,
    ui: *ralph.UI,
) !void {
    try ui.status("Syncing beads...");
    beads.sync() catch |err| {
        try ui.errFmt("Warning: Beads sync failed: {s}", .{@errorName(err)});
    };

    ralph.State.clear(state_path) catch {};
}

fn clearStopFile(stop_file_path: []const u8, ui: *ralph.UI) void {
    fs.deleteFileAbsolute(stop_file_path) catch |err| {
        if (err != error.FileNotFound) {
            ui.info("Warning: Could not clear stop file") catch {};
        }
    };
}

fn runIntrospection(
    allocator: mem.Allocator,
    config: *const ralph.Config,
    claude: *ralph.Claude,
    state: *ralph.State,
    state_path: []const u8,
    ui: *ralph.UI,
) !void {
    try ui.status("Running introspection...");

    // Initialize scanner
    var scanner = ralph.Scanner.init(allocator, config.project_dir);

    // Scan for recent task logs
    const task_logs = scanner.scanTaskLogs(10) catch &.{};
    defer scanner.freeTaskLogs(@constCast(task_logs));

    // Scan for existing skills
    const skills = scanner.scanSkills() catch &.{};
    defer scanner.freeStringList(@constCast(skills));

    // Scan for existing agents
    const agents = scanner.scanAgents() catch &.{};
    defer scanner.freeStringList(@constCast(agents));

    // Read CLAUDE.md if it exists
    const claude_md_path = try fs.path.join(allocator, &.{ config.project_dir, "CLAUDE.md" });
    defer allocator.free(claude_md_path);

    const claude_md_content: ?[]const u8 = blk: {
        const file = fs.openFileAbsolute(claude_md_path, .{}) catch break :blk null;
        defer file.close();
        break :blk file.readToEndAlloc(allocator, 1024 * 1024) catch null;
    };
    defer if (claude_md_content) |c| allocator.free(c);

    const introspection = ralph.IntrospectionPrompt{
        .task_logs = task_logs,
        .claude_md_content = claude_md_content,
        .existing_skills = skills,
        .existing_agents = agents,
    };

    const intro_text = try introspection.renderToString(allocator);
    defer allocator.free(intro_text);

    const intro_output = try ralph.ui.generateOutputFilename(allocator, config.output_dir, "introspection");
    defer allocator.free(intro_output);

    if (claude.run(intro_text, .{
        .output_file = intro_output,
        .stream_to_terminal = !config.silent,
        .working_dir = config.project_dir,
    })) |intro_result| {
        freeRunResult(allocator, intro_result);
        state.resetTaskCount();
        try state.save(state_path);
        try ui.status("Introspection complete.");
    } else |_| {
        try ui.info("Introspection skipped (Claude error)");
    }
}

test "main module compiles" {
    // Simple test to ensure module compiles
    _ = ralph;
}
