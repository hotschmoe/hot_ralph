const std = @import("std");
const rich = @import("rich_zig");

fn renderSegments(segments: []const rich.Segment, writer: anytype) !void {
    for (segments) |seg| {
        try seg.render(writer, .truecolor);
    }
}

pub fn main() !void {
    // Enable UTF-8 output on Windows
    _ = rich.terminal.enableUtf8();
    _ = rich.terminal.enableVirtualTerminal();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout.writeAll("rich_zig v1.0.0 - Full Demo\n");
    try stdout.writeAll("============================\n\n");

    // Phase 1: Color, Style, Segment
    try stdout.writeAll("Phase 1: Core Foundation\n");
    try stdout.writeAll("------------------------\n");

    // Color examples
    try stdout.writeAll("Colors:\n");
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try rich.Color.red.getAnsiCodes(true, stream.writer());
    try stdout.print("  \x1b[{s}mRed text\x1b[0m\n", .{stream.getWritten()});

    stream.reset();
    try rich.Color.fromRgb(255, 128, 64).getAnsiCodes(true, stream.writer());
    try stdout.print("  \x1b[{s}mRGB(255,128,64)\x1b[0m\n", .{stream.getWritten()});

    // Style examples
    try stdout.writeAll("\nStyles:\n");
    const bold_red = rich.Style.empty.bold().foreground(rich.Color.red);
    try bold_red.renderAnsi(.truecolor, stdout);
    try stdout.writeAll("  Bold red");
    try rich.Style.renderReset(stdout);
    try stdout.writeAll("\n");

    const parsed = try rich.Style.parse("bold underline blue");
    try parsed.renderAnsi(.truecolor, stdout);
    try stdout.writeAll("  Parsed: bold underline blue");
    try rich.Style.renderReset(stdout);
    try stdout.writeAll("\n");

    // Cell width
    try stdout.writeAll("\nCell widths:\n");
    try stdout.print("  \"Hello\" = {d} cells\n", .{rich.cells.cellLen("Hello")});
    try stdout.print("  CJK = {d} cells\n", .{rich.cells.cellLen("\u{4E2D}\u{6587}")});

    // Phase 2: Text and Markup
    try stdout.writeAll("\nPhase 2: Text and Markup\n");
    try stdout.writeAll("------------------------\n");

    var text = try rich.Text.fromMarkup(allocator, "[bold red]Hello[/] [italic green]World[/]!");
    defer text.deinit();

    const segments = try text.render(allocator);
    defer allocator.free(segments);

    try stdout.writeAll("Markup: ");
    try renderSegments(segments, stdout);
    try stdout.writeAll("\n");

    // Box styles
    try stdout.writeAll("\nBox styles:\n");
    const box_styles = [_]struct { name: []const u8, style: rich.BoxStyle }{
        .{ .name = "rounded", .style = rich.BoxStyle.rounded },
        .{ .name = "square", .style = rich.BoxStyle.square },
        .{ .name = "heavy", .style = rich.BoxStyle.heavy },
        .{ .name = "double", .style = rich.BoxStyle.double },
        .{ .name = "ascii", .style = rich.BoxStyle.ascii },
    };

    for (box_styles) |bs| {
        try stdout.print("  {s}: {s}{s}{s}{s}{s}\n", .{
            bs.name,
            bs.style.top_left,
            bs.style.horizontal,
            bs.style.horizontal,
            bs.style.horizontal,
            bs.style.top_right,
        });
    }

    // Phase 3: Terminal and Console
    try stdout.writeAll("\nPhase 3: Terminal and Console\n");
    try stdout.writeAll("-----------------------------\n");

    const term_info = rich.terminal.detect();
    try stdout.print("Terminal: {d}x{d}, color={s}, tty={}\n", .{
        term_info.width,
        term_info.height,
        @tagName(term_info.color_system),
        term_info.is_tty,
    });

    // Console
    var console = rich.Console.init(allocator);
    defer console.deinit();
    try stdout.print("Console width: {d}\n", .{console.width()});

    // Phase 4: Renderables
    try stdout.writeAll("\nPhase 4: Renderables\n");
    try stdout.writeAll("--------------------\n");

    // Panel
    try stdout.writeAll("\nPanel:\n");
    const panel = rich.Panel.fromText(allocator, "Panel content").withTitle("Title").withWidth(30);
    const panel_segs = try panel.render(80, allocator);
    defer allocator.free(panel_segs);
    try renderSegments(panel_segs, stdout);

    // Rule
    try stdout.writeAll("\nRule:\n");
    const rule = rich.Rule.init().withTitle("Section");
    const rule_segs = try rule.render(30, allocator);
    defer allocator.free(rule_segs);
    try renderSegments(rule_segs, stdout);

    // Progress bar
    try stdout.writeAll("\nProgress bar (50%):\n");
    const bar = rich.ProgressBar.init().withCompleted(50).withTotal(100).withWidth(30);
    const bar_segs = try bar.render(80, allocator);
    defer allocator.free(bar_segs);
    try renderSegments(bar_segs, stdout);
    try stdout.writeAll("\n");

    // Spinner
    try stdout.writeAll("\nSpinner frames: ");
    var spinner = rich.Spinner.init();
    for (0..5) |_| {
        const spin_segs = try spinner.render(allocator);
        defer allocator.free(spin_segs);
        try renderSegments(spin_segs, stdout);
        try stdout.writeAll(" ");
        spinner.advance();
    }
    try stdout.writeAll("\n");

    // Tree
    try stdout.writeAll("\nTree:\n");
    var root = rich.TreeNode.init(allocator, "root");
    defer root.deinit();
    const child1 = try root.addChildLabel("child1");
    _ = try child1.addChildLabel("grandchild");
    _ = try root.addChildLabel("child2");

    const tree = rich.Tree.init(root);
    const tree_segs = try tree.render(80, allocator);
    defer allocator.free(tree_segs);
    try renderSegments(tree_segs, stdout);

    // Table
    try stdout.writeAll("\nTable:\n");
    var table = rich.Table.init(allocator);
    defer table.deinit();
    _ = table.addColumn("Name").addColumn("Value");
    try table.addRow(&.{ "foo", "123" });
    try table.addRow(&.{ "bar", "456" });

    const table_segs = try table.render(40, allocator);
    defer allocator.free(table_segs);
    try renderSegments(table_segs, stdout);

    // v0.7.0 Features
    try stdout.writeAll("\nv0.7.0 New Features\n");
    try stdout.writeAll("-------------------\n");

    // Panel with title alignment
    try stdout.writeAll("\nPanel with left-aligned title:\n");
    const panel_left = rich.Panel.fromText(allocator, "Left title").withTitle("Left").withTitleAlignment(.left).withWidth(30);
    const panel_left_segs = try panel_left.render(80, allocator);
    defer allocator.free(panel_left_segs);
    try renderSegments(panel_left_segs, stdout);

    try stdout.writeAll("\nPanel with right-aligned title:\n");
    const panel_right = rich.Panel.fromText(allocator, "Right title").withTitle("Right").withTitleAlignment(.right).withWidth(30);
    const panel_right_segs = try panel_right.render(80, allocator);
    defer allocator.free(panel_right_segs);
    try renderSegments(panel_right_segs, stdout);

    // Table with caption
    try stdout.writeAll("\nTable with caption:\n");
    var table2 = rich.Table.init(allocator);
    defer table2.deinit();
    _ = table2.addColumn("Item").addColumn("Price").withCaption("Shopping List");
    try table2.addRow(&.{ "Apple", "$1.50" });
    try table2.addRow(&.{ "Bread", "$2.00" });

    const table2_segs = try table2.render(40, allocator);
    defer allocator.free(table2_segs);
    try renderSegments(table2_segs, stdout);

    // Padding - wrap content in a styled background to show padding
    try stdout.writeAll("\nPadding (uniform=1, with background):\n");
    const pad_content = [_]rich.Segment{rich.Segment.plain("Padded")};
    const bg_style = rich.Style.empty.background(rich.Color.fromRgb(60, 60, 80));
    const padding = rich.Padding.init(&pad_content).uniform(1).withStyle(bg_style);
    const pad_segs = try padding.render(20, allocator);
    defer allocator.free(pad_segs);
    try renderSegments(pad_segs, stdout);

    // Align - horizontal alignment within a width
    try stdout.writeAll("\nAlign (width=20, showing left/center/right):\n");
    const align_content = [_]rich.Segment{rich.Segment.plain("Text")};
    const alignments = [_]struct { alignment: rich.Align, label: []const u8 }{
        .{ .alignment = rich.Align.init(&align_content).left().withWidth(20), .label = "left" },
        .{ .alignment = rich.Align.init(&align_content).center().withWidth(20), .label = "center" },
        .{ .alignment = rich.Align.init(&align_content).right().withWidth(20), .label = "right" },
    };
    for (alignments) |item| {
        try stdout.writeAll("|");
        const segs = try item.alignment.render(80, allocator);
        defer allocator.free(segs);
        for (segs) |seg| {
            if (!std.mem.eql(u8, seg.text, "\n")) try seg.render(stdout, .truecolor);
        }
        try stdout.print("| {s}\n", .{item.label});
    }

    // Console log methods - flush our buffer first so log output appears in order
    try stdout.writeAll("\nConsole logging:\n");
    try stdout.flush();
    try console.logDebug("This is a debug message", .{});
    try console.logInfo("This is an info message", .{});
    try console.logWarn("This is a warning message", .{});
    try console.logErr("This is an error message", .{});

    // v0.8.0 Features
    try stdout.writeAll("\nv0.8.0 New Features\n");
    try stdout.writeAll("-------------------\n");

    // Columns layout
    try stdout.writeAll("\nColumns layout (3 items, equal width):\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const col_texts = [_][]const u8{ "Column 1", "Column 2", "Column 3" };
        const columns = (try rich.Columns.fromText(arena.allocator(), &col_texts))
            .withColumnCount(3)
            .withEqualWidth(true);
        const col_segs = try columns.render(60, arena.allocator());
        try renderSegments(col_segs, stdout);
    }

    // Table with alternating row styles
    try stdout.writeAll("\nTable with alternating rows:\n");
    var alt_table = rich.Table.init(allocator);
    defer alt_table.deinit();
    _ = alt_table.addColumn("ID").addColumn("Name").addColumn("Status");
    _ = alt_table.withAlternatingStyles(rich.Style.empty, rich.Style.empty.dim());
    try alt_table.addRow(&.{ "1", "Alice", "Active" });
    try alt_table.addRow(&.{ "2", "Bob", "Pending" });
    try alt_table.addRow(&.{ "3", "Carol", "Active" });
    const alt_table_segs = try alt_table.render(40, allocator);
    defer allocator.free(alt_table_segs);
    try renderSegments(alt_table_segs, stdout);

    // Panel with height constraint
    try stdout.writeAll("\nPanel with height constraint (4 lines max):\n");
    const constrained_panel = rich.Panel.fromText(allocator, "Line 1\nLine 2\nLine 3\nLine 4")
        .withTitle("Clipped")
        .withHeight(4)
        .withVerticalOverflow(.ellipsis);
    const cp_segs = try constrained_panel.render(30, allocator);
    defer allocator.free(cp_segs);
    try renderSegments(cp_segs, stdout);

    // v0.9.0 Features
    try stdout.writeAll("\nv0.9.0 New Features\n");
    try stdout.writeAll("-------------------\n");

    // Custom Box - demonstrate custom box characters
    try stdout.writeAll("\nCustom box style:\n");
    const custom_box = rich.BoxStyle.custom(.{
        .top_left = "*",
        .top_right = "*",
        .bottom_left = "*",
        .bottom_right = "*",
        .horizontal = "=",
        .vertical = "!",
    });
    const horiz = try custom_box.getHorizontal(8, allocator);
    defer allocator.free(horiz);
    try stdout.print("  {s}{s}{s}\n", .{ custom_box.top_left, horiz, custom_box.top_right });
    try stdout.print("  {s} Custom {s}\n", .{ custom_box.vertical, custom_box.vertical });
    try stdout.print("  {s}{s}{s}\n", .{ custom_box.bottom_left, horiz, custom_box.bottom_right });

    // Table with footer
    try stdout.writeAll("\nTable with footer:\n");
    var table3 = rich.Table.init(allocator);
    defer table3.deinit();
    _ = table3.addColumn("Item").addColumn("Price");
    try table3.addRow(&.{ "Apple", "$1.00" });
    try table3.addRow(&.{ "Banana", "$0.50" });
    _ = table3.withFooter(&.{ "Total", "$1.50" });

    const table3_segs = try table3.render(30, allocator);
    defer allocator.free(table3_segs);
    try renderSegments(table3_segs, stdout);

    // Progress with timing
    try stdout.writeAll("\nProgress with timing info:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const timed_bar = rich.ProgressBar.init()
            .withDescription("Loading")
            .withCompleted(75)
            .withTotal(100)
            .withWidth(20)
            .withTiming();
        const timed_segs = try timed_bar.render(80, arena.allocator());
        try renderSegments(timed_segs, stdout);
    }
    try stdout.writeAll("\n");

    // Indeterminate progress
    try stdout.writeAll("\nIndeterminate progress:\n");
    const indet_bar = rich.ProgressBar.init()
        .withDescription("Working")
        .asIndeterminate()
        .withWidth(20);
    const indet_segs = try indet_bar.render(80, allocator);
    defer allocator.free(indet_segs);
    try renderSegments(indet_segs, stdout);
    try stdout.writeAll("\n");

    // Progress Group
    try stdout.writeAll("\nProgress group (multiple bars):\n");
    var group = rich.ProgressGroup.init(allocator);
    defer group.deinit();
    _ = try group.addTask("Download", 100);
    _ = try group.addTask("Extract", 100);
    group.bars.items[0].completed = 80;
    group.bars.items[1].completed = 30;

    const group_segs = try group.render(60, allocator);
    defer allocator.free(group_segs);
    try renderSegments(group_segs, stdout);
    try stdout.writeAll("\n");

    // Tree with styled label
    try stdout.writeAll("\nTree with styled labels:\n");
    const styled_segs = [_]rich.Segment{
        rich.Segment.styled("bold", rich.Style.empty.bold()),
        rich.Segment.plain(" root"),
    };
    var styled_root = rich.TreeNode.initWithSegments(allocator, &styled_segs);
    defer styled_root.deinit();
    _ = try styled_root.addChildLabel("child node");

    const styled_tree = rich.Tree.init(styled_root);
    const styled_tree_segs = try styled_tree.render(80, allocator);
    defer allocator.free(styled_tree_segs);
    try renderSegments(styled_tree_segs, stdout);

    // Layout Split - show vertical split stacking two regions
    try stdout.writeAll("\nLayout split (vertical):\n");
    const top_content = [_]rich.Segment{
        rich.Segment.styled("[ Top Region ]", rich.Style.empty.bold()),
    };
    const bottom_content = [_]rich.Segment{
        rich.Segment.styled("[ Bottom Region ]", rich.Style.empty.dim()),
    };
    var split = rich.Split.vertical(allocator);
    defer split.deinit();
    _ = split.add(&top_content).add(&bottom_content);

    const split_segs = try split.render(40, allocator);
    defer allocator.free(split_segs);
    try renderSegments(split_segs, stdout);

    // JSON pretty-print
    try stdout.writeAll("\nJSON pretty-printing:\n");
    var json = try rich.Json.fromString(allocator, "{\"name\": \"rich_zig\", \"version\": \"1.0.0\", \"awesome\": true}");
    defer json.deinit();

    const json_segs = try json.render(80, allocator);
    defer allocator.free(json_segs);
    try renderSegments(json_segs, stdout);
    try stdout.writeAll("\n");

    // v0.10.0 Features
    try stdout.writeAll("\nv0.10.0 New Features\n");
    try stdout.writeAll("--------------------\n");

    // Markdown with headers
    try stdout.writeAll("\nMarkdown headers:\n");
    const md_headers = rich.Markdown.init("# Heading 1\n## Heading 2\n### Heading 3");
    const md_header_segs = try md_headers.render(60, allocator);
    defer allocator.free(md_header_segs);
    try renderSegments(md_header_segs, stdout);

    // Markdown with bold and italic inline styles
    try stdout.writeAll("\nMarkdown inline styles:\n");
    const md_styles = rich.Markdown.init("This has **bold**, *italic*, and ***bold italic*** text.");
    const md_style_segs = try md_styles.render(80, allocator);
    defer allocator.free(md_style_segs);
    try renderSegments(md_style_segs, stdout);

    // Markdown with underscore syntax
    try stdout.writeAll("\nMarkdown underscore syntax:\n");
    const md_under = rich.Markdown.init("Also works with __bold__ and _italic_ using underscores.");
    const md_under_segs = try md_under.render(80, allocator);
    defer allocator.free(md_under_segs);
    try renderSegments(md_under_segs, stdout);

    // Combined: header with inline styles
    try stdout.writeAll("\nMarkdown combined:\n");
    const md_combined = rich.Markdown.init("## Features\n\nSupports **bold** and *italic* in paragraphs.");
    const md_combined_segs = try md_combined.render(60, allocator);
    defer allocator.free(md_combined_segs);
    try renderSegments(md_combined_segs, stdout);

    // Markdown lists (uses arena due to internal allocations)
    try stdout.writeAll("\nMarkdown lists:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const md_lists = rich.Markdown.init("- First item\n- Second item\n- Third item\n\n1. Numbered one\n2. Numbered two");
        const md_lists_segs = try md_lists.render(60, arena.allocator());
        try renderSegments(md_lists_segs, stdout);
    }

    // Markdown blockquotes (uses arena due to internal allocations)
    try stdout.writeAll("\nMarkdown blockquotes:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const md_quote = rich.Markdown.init("> This is a quote\n> with multiple lines\n>> Nested quote");
        const md_quote_segs = try md_quote.render(60, arena.allocator());
        try renderSegments(md_quote_segs, stdout);
    }

    // Markdown inline code
    try stdout.writeAll("\nMarkdown inline code:\n");
    const md_code = rich.Markdown.init("Use `std.debug.print` for debugging.");
    const md_code_segs = try md_code.render(60, allocator);
    defer allocator.free(md_code_segs);
    try renderSegments(md_code_segs, stdout);

    // Markdown links
    try stdout.writeAll("\nMarkdown links:\n");
    const md_link = rich.Markdown.init("Check out [rich_zig](https://github.com/example/rich_zig) for more.");
    const md_link_segs = try md_link.render(70, allocator);
    defer allocator.free(md_link_segs);
    try renderSegments(md_link_segs, stdout);

    // Markdown horizontal rule
    try stdout.writeAll("\nMarkdown horizontal rule:\n");
    const md_hr = rich.Markdown.init("Above the line\n\n---\n\nBelow the line");
    const md_hr_segs = try md_hr.render(40, allocator);
    defer allocator.free(md_hr_segs);
    try renderSegments(md_hr_segs, stdout);

    // Markdown fenced code block (uses arena due to renderDuped allocations)
    try stdout.writeAll("\nMarkdown fenced code block:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const md_fenced = rich.Markdown.init("```zig\nconst x: u32 = 42;\nstd.debug.print(\"{}\", .{x});\n```");
        const md_fenced_segs = try md_fenced.render(60, arena.allocator());
        try renderSegments(md_fenced_segs, stdout);
    }

    // v0.11.0 Features
    try stdout.writeAll("\nv0.11.0 New Features\n");
    try stdout.writeAll("--------------------\n");

    // Syntax highlighting
    try stdout.writeAll("\nSyntax highlighting (Zig):\n");
    const zig_code =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    const x: u32 = 42;
        \\    std.debug.print("{}\n", .{x});
        \\}
    ;
    const syntax = rich.Syntax.init(allocator, zig_code).withLanguage(.zig);
    const syntax_segs = try syntax.render(60, allocator);
    defer allocator.free(syntax_segs);
    try renderSegments(syntax_segs, stdout);

    // Syntax auto-detection
    try stdout.writeAll("\nSyntax auto-detection (from extension):\n");
    for ([_][]const u8{ ".py", ".rs", ".zig" }) |ext| {
        const lang = rich.SyntaxLanguage.fromExtension(ext);
        try stdout.print("  {s} -> {s}\n", .{ ext, @tagName(lang) });
    }

    // Logging module
    try stdout.writeAll("\nLogging module (RichHandler):\n");
    try stdout.flush();
    var log_handler = rich.logging.RichHandler.init(allocator);
    defer log_handler.deinit();
    try log_handler.emit(rich.logging.LogRecord.init(.debug, "Debug level message"));
    try log_handler.emit(rich.logging.LogRecord.init(.info, "Info level message"));
    try log_handler.emit(rich.logging.LogRecord.init(.warn, "Warning level message"));
    try log_handler.emit(rich.logging.LogRecord.init(.err, "Error level message"));

    // v0.12.0 Features
    try stdout.writeAll("\nv0.12.0 New Features\n");
    try stdout.writeAll("--------------------\n");

    // Table with row/column spanning
    try stdout.writeAll("\nTable with row/column spanning:\n");
    var span_table = rich.Table.init(allocator);
    defer span_table.deinit();
    _ = span_table.addColumn("A").addColumn("B").addColumn("C");
    try span_table.addSpannedRow(&.{
        rich.Cell.text("Spans 2 cols").withColspan(2),
        rich.Cell.text("C1"),
    });
    try span_table.addSpannedRow(&.{
        rich.Cell.text("Spans 2 rows").withRowspan(2),
        rich.Cell.text("B2"),
        rich.Cell.text("C2"),
    });
    try span_table.addSpannedRow(&.{
        rich.Cell.text("B3"),
        rich.Cell.text("C3"),
    });
    const span_table_segs = try span_table.render(40, allocator);
    defer allocator.free(span_table_segs);
    try renderSegments(span_table_segs, stdout);

    // Markdown strikethrough
    try stdout.writeAll("\nMarkdown strikethrough:\n");
    const md_strike = rich.Markdown.init("This text has ~~strikethrough~~ formatting.");
    const md_strike_segs = try md_strike.render(60, allocator);
    defer allocator.free(md_strike_segs);
    try renderSegments(md_strike_segs, stdout);

    // Markdown task lists
    try stdout.writeAll("\nMarkdown task lists:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const md_tasks = rich.Markdown.init("- [x] Completed task\n- [ ] Pending task\n- [x] Another done");
        const md_tasks_segs = try md_tasks.render(60, arena.allocator());
        try renderSegments(md_tasks_segs, stdout);
    }

    // Markdown GFM table
    try stdout.writeAll("\nMarkdown GFM table:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const md_table = rich.Markdown.init("| Name | Value |\n|------|-------|\n| foo  | 123   |\n| bar  | 456   |");
        const md_table_segs = try md_table.render(60, arena.allocator());
        try renderSegments(md_table_segs, stdout);
    }

    // Markdown images (alt text display)
    try stdout.writeAll("\nMarkdown images (alt text):\n");
    const md_img = rich.Markdown.init("Here's an image: ![Logo](https://example.com/logo.png)");
    const md_img_segs = try md_img.render(60, allocator);
    defer allocator.free(md_img_segs);
    try renderSegments(md_img_segs, stdout);

    // Syntax highlighting with word wrap
    try stdout.writeAll("\nSyntax with word wrap (width=40):\n");
    const long_code = "const very_long_variable_name: u32 = some_function_call(arg1, arg2, arg3);";
    const wrap_syntax = rich.Syntax.init(allocator, long_code).withLanguage(.zig).withWordWrap();
    const wrap_segs = try wrap_syntax.render(40, allocator);
    defer allocator.free(wrap_segs);
    try renderSegments(wrap_segs, stdout);

    // Console input prompts (API documentation - interactive features)
    try stdout.writeAll(
        \\
        \\Console input prompts (API available):
        \\  console.input("Enter name: ")     -> Read line of text
        \\  console.prompt("[bold]Name:[/] ") -> Styled prompt
        \\  rich.Prompt, IntPrompt, FloatPrompt, Confirm
        \\
    );

    // v0.13.0 Features (arenas used for syntax/traceback internal allocations)
    try stdout.writeAll("\nv0.13.0 New Features\n");
    try stdout.writeAll("--------------------\n");

    // Syntax with theme (background color)
    try stdout.writeAll("\nSyntax with Monokai theme (includes background):\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const themed_code = "const x = 42;";
        const themed_syntax = rich.Syntax.init(arena.allocator(), themed_code)
            .withLanguage(.zig)
            .withTheme(rich.SyntaxTheme.monokai);
        const themed_segs = try themed_syntax.render(60, arena.allocator());
        try renderSegments(themed_segs, stdout);
    }

    // Syntax with custom tab size
    try stdout.writeAll("\nSyntax with custom tab size (2 spaces):\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const tabbed_code = "fn foo() void {\n\tbar();\n}";
        const tabbed_syntax = rich.Syntax.init(arena.allocator(), tabbed_code)
            .withLanguage(.zig)
            .withTabSize(2);
        const tabbed_segs = try tabbed_syntax.render(60, arena.allocator());
        try renderSegments(tabbed_segs, stdout);
    }

    // Syntax with indent guides
    try stdout.writeAll("\nSyntax with indent guides:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const indented_code =
            \\pub fn main() void {
            \\    if (true) {
            \\        doSomething();
            \\    }
            \\}
        ;
        const guided_syntax = rich.Syntax.init(arena.allocator(), indented_code)
            .withLanguage(.zig)
            .withIndentGuides();
        const guided_segs = try guided_syntax.render(60, arena.allocator());
        try renderSegments(guided_segs, stdout);
    }

    // Syntax with highlighted lines
    try stdout.writeAll("\nSyntax with highlighted lines (line 2):\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const highlight_code =
            \\const a = 1;
            \\const b = 2;  // This line is highlighted
            \\const c = 3;
        ;
        const highlight_lines = [_]usize{2};
        const hl_syntax = rich.Syntax.init(arena.allocator(), highlight_code)
            .withLanguage(.zig)
            .withLineNumbers()
            .withHighlightLines(&highlight_lines);
        const hl_segs = try hl_syntax.render(60, arena.allocator());
        try renderSegments(hl_segs, stdout);
    }

    // Traceback support
    try stdout.writeAll("\nTraceback rendering:\n");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var tb = rich.Traceback.init(arena.allocator());
        tb = tb.withMessage("Example error occurred")
            .withErrorName("DemoError");
        try tb.addFrame(rich.StackFrame{
            .function = "innerFunction",
            .file = "src/module.zig",
            .line = 42,
            .column = 5,
        });
        try tb.addFrame(rich.StackFrame{
            .function = "outerFunction",
            .file = "src/main.zig",
            .line = 100,
            .column = 10,
        });
        const tb_segs = try tb.render(70, arena.allocator());
        try renderSegments(tb_segs, stdout);
    }

    try stdout.writeAll("\nAll phases complete!\n");
    try stdout.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
