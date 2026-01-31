//! hot_ralph - Atomic task execution with Claude and Beads
//!
//! A CLI tool that orchestrates atomic development tasks by integrating
//! Claude AI with the Beads task tracking system.

const std = @import("std");

pub const config = @import("config.zig");
pub const state = @import("state.zig");
pub const prompt = @import("prompt.zig");
pub const ui = @import("ui.zig");
pub const beads = @import("beads.zig");
pub const claude = @import("claude.zig");
pub const git = @import("git.zig");
pub const scanner = @import("scanner.zig");
pub const exit_monitor = @import("exit_monitor.zig");

// Re-export commonly used types
pub const Config = config.Config;
pub const Args = config.Args;
pub const ConfigError = config.ConfigError;

pub const State = state.State;
pub const Phase = state.Phase;
pub const PlanPhase = state.PlanPhase;
pub const StateError = state.StateError;

pub const Task = beads.Task;
pub const TaskStatus = beads.TaskStatus;
pub const Beads = beads.Beads;
pub const BeadsError = beads.BeadsError;

pub const Claude = claude.Claude;
pub const ClaudeError = claude.ClaudeError;
pub const FatalErrorType = claude.FatalErrorType;
pub const RunResult = claude.RunResult;
pub const RunOptions = claude.RunOptions;
pub const StreamParser = claude.StreamParser;

pub const Git = git.Git;
pub const GitError = git.GitError;

pub const Scanner = scanner.Scanner;
pub const ExitMonitor = exit_monitor.ExitMonitor;

pub const UI = ui.UI;
pub const ExecuteChoice = ui.ExecuteChoice;
pub const SuccessChoice = ui.SuccessChoice;

pub const TaskPrompt = prompt.TaskPrompt;
pub const SimplificationPrompt = prompt.SimplificationPrompt;
pub const FinalReviewPrompt = prompt.FinalReviewPrompt;
pub const IntrospectionPrompt = prompt.IntrospectionPrompt;
pub const PlanModePrompt = prompt.PlanModePrompt;

// Version info
pub const version = "0.3.0";
pub const version_string = "hot_ralph " ++ version;

test {
    // Run all module tests
    std.testing.refAllDecls(@This());
}

test "rich_zig integration" {
    const rich = @import("rich_zig");
    const allocator = std.testing.allocator;

    // Test basic style creation
    const style = rich.Style.empty.bold().foreground(rich.Color.red);
    try std.testing.expect(style.hasAttribute(.bold));
    try std.testing.expect(style.color != null);

    // Test Text creation from markup
    var text = try rich.Text.fromMarkup(allocator, "[bold]Hello, rich_zig![/]");
    defer text.deinit();
    try std.testing.expectEqualStrings("Hello, rich_zig!", text.plain);

    // Test cell width calculation
    try std.testing.expectEqual(@as(usize, 5), rich.cells.cellLen("Hello"));
}
