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
const EXIT_INTERRUPTED: u8 = 130;

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
    var ui = ralph.UI.init(allocator, config.auto_mode);

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

    // Main loop
    var tasks_completed: usize = 0;
    var push_probability: u8 = 0;

    while (true) {
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

        // Claim the task
        beads.claim(task.id) catch |err| {
            try ui.errFmt("Failed to claim task: {s}", .{@errorName(err)});
            return EXIT_BEADS;
        };

        // Update state
        const output_filename = try ralph.ui.generateOutputFilename(
            allocator,
            config.output_dir,
            try std.fmt.allocPrint(allocator, "task_{s}", .{task.id}),
        );
        defer allocator.free(output_filename);

        try state.setTask(task.id, output_filename);
        try state.save(state_path);

        try ui.statusFmt("Executing task {s}...", .{task.id});

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

        // Run Claude
        const result = claude.run(prompt_text, .{
            .output_file = output_filename,
            .stream_to_terminal = true,
            .working_dir = config.project_dir,
        }) catch |err| {
            try ui.errFmt("Claude execution failed: {s}", .{@errorName(err)});
            return EXIT_CLAUDE;
        };

        switch (result) {
            .interrupted => {
                try ui.info("\nInterrupted.");
                try syncBeadsAndExit(&beads, &state, state_path, &ui);
                return EXIT_INTERRUPTED;
            },
            .failure => |f| {
                try ui.errFmt("Claude failed: {s}", .{f.message});
                allocator.free(f.message);
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
        beads.complete(task.id, "Completed via ralph") catch |err| {
            try ui.errFmt("Failed to complete task: {s}", .{@errorName(err)});
            return EXIT_BEADS;
        };

        try ui.statusFmt("Task {s} completed.", .{task.id});

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

        // Periodic push (20% chance)
        push_probability += 20;
        if (push_probability >= 100) {
            push_probability = 0;
            try ui.status("Pushing to remote...");
            git.push() catch {
                // Ignore push failures
            };
        }

        // Update counters
        tasks_completed += 1;
        state.incrementTaskCount();
        state.clearTask();
        try state.save(state_path);

        // Countdown between tasks (if not in auto mode)
        if (!config.auto_mode) {
            const should_continue = try ui.countdown(5);
            if (!should_continue) {
                break;
            }
        }
    }

    // Final sync
    try syncBeadsAndExit(&beads, &state, state_path, &ui);

    // Display summary
    try ui.displayComplete(tasks_completed);

    return EXIT_SUCCESS;
}

fn syncBeadsAndExit(
    beads: *ralph.Beads,
    state: *ralph.State,
    state_path: []const u8,
    ui: *ralph.UI,
) !void {
    try ui.status("Syncing beads...");
    beads.sync() catch |err| {
        try ui.errFmt("Warning: Beads sync failed: {s}", .{@errorName(err)});
    };

    // Clear state
    ralph.State.clear(state_path) catch {};
    _ = state;
}

test "main module compiles" {
    // Simple test to ensure module compiles
    _ = ralph;
}
