const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const segment_mod = @import("../segment.zig");
const Style = @import("../style.zig").Style;
const cells = @import("../cells.zig");
const BoxStyle = @import("../box.zig").BoxStyle;

pub const CellContent = union(enum) {
    text: []const u8,
    segments: []const Segment,

    pub fn getText(self: CellContent) []const u8 {
        return switch (self) {
            .text => |t| t,
            .segments => |segs| if (segs.len > 0) segs[0].text else "",
        };
    }

    pub fn getCellWidth(self: CellContent) usize {
        return switch (self) {
            .text => |t| cells.cellLen(t),
            .segments => |segs| segment_mod.totalCellLength(segs),
        };
    }
};

/// A cell with optional column and row spanning
pub const Cell = struct {
    content: CellContent,
    colspan: u8 = 1,
    rowspan: u8 = 1,
    style: ?Style = null,
    justify: ?JustifyMethod = null,

    pub fn text(t: []const u8) Cell {
        return .{ .content = .{ .text = t } };
    }

    pub fn segments(segs: []const Segment) Cell {
        return .{ .content = .{ .segments = segs } };
    }

    pub fn withColspan(self: Cell, span: u8) Cell {
        var c = self;
        c.colspan = if (span == 0) 1 else span;
        return c;
    }

    pub fn withRowspan(self: Cell, span: u8) Cell {
        var c = self;
        c.rowspan = if (span == 0) 1 else span;
        return c;
    }

    pub fn withStyle(self: Cell, s: Style) Cell {
        var c = self;
        c.style = s;
        return c;
    }

    pub fn withJustify(self: Cell, j: JustifyMethod) Cell {
        var c = self;
        c.justify = j;
        return c;
    }

    pub fn getCellWidth(self: Cell) usize {
        return self.content.getCellWidth();
    }
};

pub const JustifyMethod = enum {
    left,
    center,
    right,
};

/// Tracks active row spans across rows during rendering
const RowSpanTracker = struct {
    /// For each column, how many more rows the current span should occupy (0 = no span active)
    remaining: []u8,
    /// For each column, the cell content that is spanning (for rendering continuation cells)
    span_cells: []?Cell,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, num_columns: usize) !RowSpanTracker {
        const remaining = try allocator.alloc(u8, num_columns);
        @memset(remaining, 0);
        const span_cells = try allocator.alloc(?Cell, num_columns);
        @memset(span_cells, null);
        return .{
            .remaining = remaining,
            .span_cells = span_cells,
            .allocator = allocator,
        };
    }

    fn deinit(self: *RowSpanTracker) void {
        self.allocator.free(self.remaining);
        self.allocator.free(self.span_cells);
    }

    /// Check if column is blocked by a row span from a previous row
    fn isBlocked(self: RowSpanTracker, col_idx: usize) bool {
        return col_idx < self.remaining.len and self.remaining[col_idx] > 0;
    }

    /// Get the cell that is spanning into this position (if any)
    fn getSpanningCell(self: RowSpanTracker, col_idx: usize) ?Cell {
        if (col_idx < self.span_cells.len) {
            return self.span_cells[col_idx];
        }
        return null;
    }

    /// Register a new cell with a row span
    fn registerSpan(self: *RowSpanTracker, col_idx: usize, cell: Cell) void {
        if (col_idx >= self.remaining.len) return;

        const span = cell.colspan;
        const end_col = @min(col_idx + span, self.remaining.len);

        for (col_idx..end_col) |j| {
            if (cell.rowspan > 1) {
                self.remaining[j] = cell.rowspan;
                self.span_cells[j] = cell;
            }
        }
    }

    /// Decrement all active spans (called after rendering a row)
    fn advanceRow(self: *RowSpanTracker) void {
        for (0..self.remaining.len) |i| {
            if (self.remaining[i] > 0) {
                self.remaining[i] -= 1;
                if (self.remaining[i] == 0) {
                    self.span_cells[i] = null;
                }
            }
        }
    }

    /// Check if any column in range has an active row span (for border rendering)
    fn hasActiveSpanInRange(self: RowSpanTracker, start: usize, end: usize) bool {
        for (start..@min(end, self.remaining.len)) |i| {
            if (self.remaining[i] > 0) return true;
        }
        return false;
    }
};

pub const Overflow = enum {
    fold,
    ellipsis,
    crop,
};

pub const AlternatingStyles = struct {
    even: Style,
    odd: Style,
};

pub const Column = struct {
    header: []const u8,
    justify: JustifyMethod = .left,
    style: Style = Style.empty,
    header_style: Style = Style.empty,
    width: ?usize = null,
    min_width: ?usize = null,
    max_width: ?usize = null,
    no_wrap: bool = false,
    ratio: ?u8 = null,
    overflow: Overflow = .fold,
    ellipsis: []const u8 = "...",

    pub fn init(header: []const u8) Column {
        return .{ .header = header };
    }

    pub fn withJustify(self: Column, j: JustifyMethod) Column {
        var c = self;
        c.justify = j;
        return c;
    }

    pub fn withWidth(self: Column, w: usize) Column {
        var c = self;
        c.width = w;
        return c;
    }

    pub fn withMinWidth(self: Column, w: usize) Column {
        var c = self;
        c.min_width = w;
        return c;
    }

    pub fn withMaxWidth(self: Column, w: usize) Column {
        var c = self;
        c.max_width = w;
        return c;
    }

    pub fn withStyle(self: Column, s: Style) Column {
        var c = self;
        c.style = s;
        return c;
    }

    pub fn withHeaderStyle(self: Column, s: Style) Column {
        var c = self;
        c.header_style = s;
        return c;
    }

    pub fn withRatio(self: Column, r: u8) Column {
        var c = self;
        c.ratio = r;
        return c;
    }

    pub fn withOverflow(self: Column, o: Overflow) Column {
        var c = self;
        c.overflow = o;
        return c;
    }

    pub fn withEllipsis(self: Column, e: []const u8) Column {
        var c = self;
        c.ellipsis = e;
        return c;
    }

    pub fn withNoWrap(self: Column, nw: bool) Column {
        var c = self;
        c.no_wrap = nw;
        return c;
    }
};

pub const Table = struct {
    columns: std.ArrayList(Column),
    rows: std.ArrayList([]const []const u8),
    rich_rows: std.ArrayList([]const CellContent),
    spanned_rows: std.ArrayList([]const Cell),
    title: ?[]const u8 = null,
    title_style: Style = Style.empty,
    caption: ?[]const u8 = null,
    caption_style: Style = Style.empty,
    caption_justify: JustifyMethod = .center,
    header_style: Style = Style.empty,
    border_style: Style = Style.empty,
    box_style: BoxStyle = BoxStyle.square,
    show_header: bool = true,
    show_edge: bool = true,
    show_lines: bool = false,
    padding: struct { left: u8, right: u8 } = .{ .left = 1, .right = 1 },
    collapse_padding: bool = false,
    row_styles: std.ArrayList(?Style),
    spanned_row_styles: std.ArrayList(?Style),
    alternating_styles: ?AlternatingStyles = null,
    footer: ?[]const []const u8 = null,
    footer_style: Style = Style.empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .columns = std.ArrayList(Column).empty,
            .rows = std.ArrayList([]const []const u8).empty,
            .rich_rows = std.ArrayList([]const CellContent).empty,
            .spanned_rows = std.ArrayList([]const Cell).empty,
            .row_styles = std.ArrayList(?Style).empty,
            .spanned_row_styles = std.ArrayList(?Style).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.columns.deinit(self.allocator);
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
        for (self.rich_rows.items) |row| {
            self.allocator.free(row);
        }
        self.rich_rows.deinit(self.allocator);
        for (self.spanned_rows.items) |row| {
            self.allocator.free(row);
        }
        self.spanned_rows.deinit(self.allocator);
        self.row_styles.deinit(self.allocator);
        self.spanned_row_styles.deinit(self.allocator);
    }

    pub fn withTitle(self: *Table, title: []const u8) *Table {
        self.title = title;
        return self;
    }

    pub fn withColumn(self: *Table, col: Column) *Table {
        self.columns.append(self.allocator, col) catch {};
        return self;
    }

    pub fn addColumn(self: *Table, header: []const u8) *Table {
        return self.withColumn(Column.init(header));
    }

    pub fn addRow(self: *Table, row: []const []const u8) !void {
        const row_copy = try self.allocator.alloc([]const u8, row.len);
        @memcpy(row_copy, row);
        try self.rows.append(self.allocator, row_copy);
        try self.row_styles.append(self.allocator, null);
    }

    pub fn addRowStyled(self: *Table, row: []const []const u8, style: Style) !void {
        const row_copy = try self.allocator.alloc([]const u8, row.len);
        @memcpy(row_copy, row);
        try self.rows.append(self.allocator, row_copy);
        try self.row_styles.append(self.allocator, style);
    }

    pub fn addRowRich(self: *Table, row: []const CellContent) !void {
        const row_copy = try self.allocator.alloc(CellContent, row.len);
        @memcpy(row_copy, row);
        try self.rich_rows.append(self.allocator, row_copy);
        try self.row_styles.append(self.allocator, null);
    }

    pub fn addRowRichStyled(self: *Table, row: []const CellContent, style: Style) !void {
        const row_copy = try self.allocator.alloc(CellContent, row.len);
        @memcpy(row_copy, row);
        try self.rich_rows.append(self.allocator, row_copy);
        try self.row_styles.append(self.allocator, style);
    }

    /// Add a row with cells that may have column/row spanning
    pub fn addSpannedRow(self: *Table, row: []const Cell) !void {
        const row_copy = try self.allocator.alloc(Cell, row.len);
        @memcpy(row_copy, row);
        try self.spanned_rows.append(self.allocator, row_copy);
        try self.spanned_row_styles.append(self.allocator, null);
    }

    /// Add a row with cells that may have column/row spanning, with a row style
    pub fn addSpannedRowStyled(self: *Table, row: []const Cell, style: Style) !void {
        const row_copy = try self.allocator.alloc(Cell, row.len);
        @memcpy(row_copy, row);
        try self.spanned_rows.append(self.allocator, row_copy);
        try self.spanned_row_styles.append(self.allocator, style);
    }

    pub fn withRowStyle(self: *Table, row_index: usize, style: Style) *Table {
        if (row_index < self.row_styles.items.len) {
            self.row_styles.items[row_index] = style;
        }
        return self;
    }

    pub fn withAlternatingStyles(self: *Table, even: Style, odd: Style) *Table {
        self.alternating_styles = .{ .even = even, .odd = odd };
        return self;
    }

    pub fn withBoxStyle(self: *Table, style: BoxStyle) *Table {
        self.box_style = style;
        return self;
    }

    pub fn withHeaderStyle(self: *Table, style: Style) *Table {
        self.header_style = style;
        return self;
    }

    pub fn withBorderStyle(self: *Table, style: Style) *Table {
        self.border_style = style;
        return self;
    }

    pub fn withCaption(self: *Table, caption_text: []const u8) *Table {
        self.caption = caption_text;
        return self;
    }

    pub fn withCaptionStyle(self: *Table, style: Style) *Table {
        self.caption_style = style;
        return self;
    }

    pub fn withCaptionJustify(self: *Table, justify: JustifyMethod) *Table {
        self.caption_justify = justify;
        return self;
    }

    pub fn withCollapsePadding(self: *Table, collapse: bool) *Table {
        self.collapse_padding = collapse;
        return self;
    }

    pub fn withFooter(self: *Table, footer_row: []const []const u8) *Table {
        self.footer = footer_row;
        return self;
    }

    pub fn withFooterStyle(self: *Table, style: Style) *Table {
        self.footer_style = style;
        return self;
    }

    pub fn render(self: Table, max_width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments: std.ArrayList(Segment) = .empty;

        if (self.columns.items.len == 0) {
            return segments.toOwnedSlice(allocator);
        }

        const col_widths = try self.calculateColumnWidths(max_width, allocator);
        defer allocator.free(col_widths);

        const b = self.box_style;

        if (self.show_edge) {
            try self.renderHorizontalBorder(&segments, allocator, col_widths, b.top_left, b.horizontal, b.top_right, b.top_tee);
        }

        if (self.show_header) {
            try self.renderHeaderRow(&segments, allocator, col_widths, b);
            try self.renderHorizontalBorder(&segments, allocator, col_widths, b.left_tee, b.horizontal, b.right_tee, b.cross);
        }

        const total_text_rows = self.rows.items.len;
        const total_rich_rows = self.rich_rows.items.len;
        const total_spanned_rows = self.spanned_rows.items.len;
        const total_rows = total_text_rows + total_rich_rows + total_spanned_rows;

        for (self.rows.items, 0..) |row, idx| {
            try self.renderDataRow(&segments, allocator, row, col_widths, b, idx);
            if (self.show_lines and idx < total_rows - 1) {
                try self.renderHorizontalBorder(&segments, allocator, col_widths, b.left_tee, b.horizontal, b.right_tee, b.cross);
            }
        }

        for (self.rich_rows.items, 0..) |row, idx| {
            const row_idx = total_text_rows + idx;
            try self.renderRichDataRow(&segments, allocator, row, col_widths, b, row_idx);
            if (self.show_lines and row_idx < total_rows - 1) {
                try self.renderHorizontalBorder(&segments, allocator, col_widths, b.left_tee, b.horizontal, b.right_tee, b.cross);
            }
        }

        // Render spanned rows with row span tracking
        if (self.spanned_rows.items.len > 0) {
            var span_tracker = try RowSpanTracker.init(allocator, self.columns.items.len);
            defer span_tracker.deinit();

            for (self.spanned_rows.items, 0..) |row, idx| {
                const row_idx = total_text_rows + total_rich_rows + idx;
                try self.renderSpannedDataRowWithTracker(&segments, allocator, row, col_widths, b, row_idx, &span_tracker);
                span_tracker.advanceRow();

                if (self.show_lines and row_idx < total_rows - 1) {
                    // Render horizontal border, accounting for row spans
                    try self.renderHorizontalBorderWithSpans(&segments, allocator, col_widths, b.left_tee, b.horizontal, b.right_tee, b.cross, b.vertical, &span_tracker);
                }
            }
        }

        if (self.footer) |footer_row| {
            try self.renderHorizontalBorder(&segments, allocator, col_widths, b.left_tee, b.horizontal, b.right_tee, b.cross);
            try self.renderFooterRow(&segments, allocator, footer_row, col_widths, b);
        }

        if (self.show_edge) {
            try self.renderHorizontalBorder(&segments, allocator, col_widths, b.bottom_left, b.horizontal, b.bottom_right, b.bottom_tee);
        }

        if (self.caption) |caption_text| {
            try self.renderCaption(&segments, allocator, col_widths, caption_text);
        }

        return segments.toOwnedSlice(allocator);
    }

    fn calculateColumnWidths(self: Table, max_width: usize, allocator: std.mem.Allocator) ![]usize {
        var widths = try allocator.alloc(usize, self.columns.items.len);

        for (self.columns.items, 0..) |col, i| {
            widths[i] = cells.cellLen(col.header);
        }

        for (self.rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < widths.len) {
                    const cell_width = cells.cellLen(cell);
                    if (cell_width > widths[i]) {
                        widths[i] = cell_width;
                    }
                }
            }
        }

        for (self.rich_rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < widths.len) {
                    const cell_width = cell.getCellWidth();
                    if (cell_width > widths[i]) {
                        widths[i] = cell_width;
                    }
                }
            }
        }

        // Process spanned rows - cells with colspan=1 contribute directly,
        // spanning cells are handled after initial widths are set
        for (self.spanned_rows.items) |row| {
            var col_idx: usize = 0;
            for (row) |cell| {
                if (col_idx >= widths.len) break;
                const span = @min(cell.colspan, @as(u8, @intCast(widths.len - col_idx)));
                if (span == 1) {
                    const cell_width = cell.getCellWidth();
                    if (cell_width > widths[col_idx]) {
                        widths[col_idx] = cell_width;
                    }
                }
                col_idx += span;
            }
        }

        for (self.columns.items, 0..) |col, i| {
            if (col.width) |w| {
                widths[i] = w;
            } else {
                if (col.min_width) |min| {
                    if (widths[i] < min) widths[i] = min;
                }
                if (col.max_width) |max| {
                    if (widths[i] > max) widths[i] = max;
                }
            }
        }

        var has_ratio = false;
        var total_ratio: usize = 0;
        for (self.columns.items) |col| {
            if (col.ratio) |r| {
                has_ratio = true;
                total_ratio += r;
            }
        }

        if (has_ratio and total_ratio > 0) {
            const borders_width: usize = if (self.show_edge) 2 else 0;
            const separators_width: usize = if (self.columns.items.len > 1) self.columns.items.len - 1 else 0;
            const overhead = borders_width + separators_width;

            var fixed_width: usize = 0;
            for (self.columns.items, 0..) |col, i| {
                if (col.ratio == null) {
                    fixed_width += widths[i] + self.padding.left + self.padding.right;
                }
            }

            const available = if (max_width > overhead + fixed_width) max_width - overhead - fixed_width else 0;

            for (self.columns.items, 0..) |col, i| {
                if (col.ratio) |r| {
                    const ratio_width = (available * r) / total_ratio;
                    const content_width = if (ratio_width > self.padding.left + self.padding.right)
                        ratio_width - self.padding.left - self.padding.right
                    else
                        0;
                    widths[i] = content_width;
                }
            }
        }

        // Second pass: handle spanning cells that need more width than available
        // Distribute extra width evenly across spanned columns
        for (self.spanned_rows.items) |row| {
            var col_idx: usize = 0;
            for (row) |cell| {
                if (col_idx >= widths.len) break;
                const span = @min(cell.colspan, @as(u8, @intCast(widths.len - col_idx)));
                if (span > 1) {
                    const cell_width = cell.getCellWidth();
                    // Calculate current combined width of spanned columns
                    var combined_width: usize = 0;
                    for (col_idx..col_idx + span) |j| {
                        combined_width += widths[j];
                    }
                    // Add separators between spanned columns
                    combined_width += span - 1;

                    if (cell_width > combined_width) {
                        // Distribute the extra width evenly
                        const extra = cell_width - combined_width;
                        const per_col = extra / span;
                        const remainder = extra % span;
                        for (col_idx..col_idx + span) |j| {
                            widths[j] += per_col;
                            if (j - col_idx < remainder) {
                                widths[j] += 1;
                            }
                        }
                    }
                }
                col_idx += span;
            }
        }

        if (!self.collapse_padding) {
            for (widths) |*w| {
                w.* += self.padding.left + self.padding.right;
            }
        }

        return widths;
    }

    fn renderHorizontalBorder(
        self: Table,
        segments: *std.ArrayList(Segment),
        allocator: std.mem.Allocator,
        widths: []usize,
        left: []const u8,
        horizontal: []const u8,
        right: []const u8,
        cross: []const u8,
    ) !void {
        try segments.append(allocator, Segment.styled(left, self.border_style));

        for (widths, 0..) |w, i| {
            for (0..w) |_| {
                try segments.append(allocator, Segment.styled(horizontal, self.border_style));
            }
            if (i < widths.len - 1) {
                try segments.append(allocator, Segment.styled(cross, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn renderHeaderRow(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, widths: []usize, b: BoxStyle) !void {
        try segments.append(allocator, Segment.styled(b.left, self.border_style));

        for (self.columns.items, 0..) |col, i| {
            const combined_style = self.header_style.combine(col.header_style);
            try self.renderCell(segments, allocator, col.header, widths[i], col.justify, combined_style, col);
            if (i < self.columns.items.len - 1) {
                try segments.append(allocator, Segment.styled(b.vertical, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(b.right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn renderDataRow(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, row: []const []const u8, widths: []usize, b: BoxStyle, row_idx: usize) !void {
        try segments.append(allocator, Segment.styled(b.left, self.border_style));

        const row_style = self.getRowStyle(row_idx);

        for (self.columns.items, 0..) |col, i| {
            const cell = if (i < row.len) row[i] else "";

            var effective_style = col.style;
            if (row_style) |rs| {
                effective_style = rs.combine(col.style);
            }

            try self.renderCell(segments, allocator, cell, widths[i], col.justify, effective_style, col);
            if (i < self.columns.items.len - 1) {
                try segments.append(allocator, Segment.styled(b.vertical, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(b.right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn renderRichDataRow(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, row: []const CellContent, widths: []usize, b: BoxStyle, row_idx: usize) !void {
        try segments.append(allocator, Segment.styled(b.left, self.border_style));

        const row_style = self.getRowStyle(row_idx);

        for (self.columns.items, 0..) |col, i| {
            const cell = if (i < row.len) row[i] else CellContent{ .text = "" };

            var effective_style = col.style;
            if (row_style) |rs| {
                effective_style = rs.combine(col.style);
            }

            try self.renderRichCell(segments, allocator, cell, widths[i], col.justify, effective_style, col);
            if (i < self.columns.items.len - 1) {
                try segments.append(allocator, Segment.styled(b.vertical, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(b.right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn renderSpannedDataRowWithTracker(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, row: []const Cell, widths: []usize, b: BoxStyle, row_idx: usize, tracker: *RowSpanTracker) !void {
        try segments.append(allocator, Segment.styled(b.left, self.border_style));

        const row_style = self.getSpannedRowStyle(row_idx);
        var col_idx: usize = 0;
        var cell_idx: usize = 0;

        while (col_idx < self.columns.items.len) {
            // Check if this column is blocked by a row span from a previous row
            if (tracker.isBlocked(col_idx)) {
                // Render empty cell (the spanning cell continues from above)
                try self.renderSpaces(segments, allocator, widths[col_idx]);
                col_idx += 1;

                if (col_idx < self.columns.items.len) {
                    try segments.append(allocator, Segment.styled(b.vertical, self.border_style));
                }
                continue;
            }

            const cell = if (cell_idx < row.len) row[cell_idx] else Cell.text("");
            const span = @min(cell.colspan, @as(u8, @intCast(self.columns.items.len - col_idx)));

            // Register row span in tracker
            if (cell.rowspan > 1) {
                tracker.registerSpan(col_idx, cell);
            }

            // Calculate the total width for this spanning cell
            var total_width: usize = 0;
            for (col_idx..col_idx + span) |j| {
                total_width += widths[j];
            }
            // Add separator widths for spanned columns
            if (span > 1) {
                total_width += span - 1;
            }

            // Get the column for styling (use the first column in the span)
            const col = self.columns.items[col_idx];

            // Determine effective style: cell style > row style > column style
            var effective_style = col.style;
            if (row_style) |rs| {
                effective_style = rs.combine(col.style);
            }
            if (cell.style) |cs| {
                effective_style = effective_style.combine(cs);
            }

            // Determine justify: cell justify > column justify
            const justify = cell.justify orelse col.justify;

            try self.renderSpannedCell(segments, allocator, cell, total_width, justify, effective_style, col);

            // Move past the spanned columns
            col_idx += span;
            cell_idx += 1;

            // Add separator if not at the end
            if (col_idx < self.columns.items.len) {
                try segments.append(allocator, Segment.styled(b.vertical, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(b.right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn renderHorizontalBorderWithSpans(
        self: Table,
        segments: *std.ArrayList(Segment),
        allocator: std.mem.Allocator,
        widths: []usize,
        left: []const u8,
        horizontal: []const u8,
        right: []const u8,
        cross: []const u8,
        vertical: []const u8,
        tracker: *RowSpanTracker,
    ) !void {
        try segments.append(allocator, Segment.styled(left, self.border_style));

        for (widths, 0..) |w, i| {
            // If there's an active row span at this column, use vertical continuation
            if (tracker.isBlocked(i)) {
                // Row span continues: render spaces instead of horizontal line
                for (0..w) |_| {
                    try segments.append(allocator, Segment.plain(" "));
                }
            } else {
                for (0..w) |_| {
                    try segments.append(allocator, Segment.styled(horizontal, self.border_style));
                }
            }

            if (i < widths.len - 1) {
                const both_blocked = tracker.isBlocked(i) and tracker.isBlocked(i + 1);
                const char = if (both_blocked) vertical else cross;
                try segments.append(allocator, Segment.styled(char, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn getRowStyle(self: Table, row_idx: usize) ?Style {
        if (row_idx < self.row_styles.items.len and self.row_styles.items[row_idx] != null) {
            return self.row_styles.items[row_idx];
        }

        if (self.alternating_styles) |alt| {
            return if (row_idx % 2 == 0) alt.even else alt.odd;
        }

        return null;
    }

    fn getSpannedRowStyle(self: Table, row_idx: usize) ?Style {
        const base_idx = self.rows.items.len + self.rich_rows.items.len;
        if (row_idx >= base_idx) {
            const spanned_idx = row_idx - base_idx;
            if (spanned_idx < self.spanned_row_styles.items.len) {
                if (self.spanned_row_styles.items[spanned_idx]) |style| {
                    return style;
                }
            }
        }

        if (self.alternating_styles) |alt| {
            return if (row_idx % 2 == 0) alt.even else alt.odd;
        }

        return null;
    }

    fn renderCell(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, text: []const u8, width: usize, justify: JustifyMethod, style: Style, col: Column) !void {
        const pad_left: usize = if (self.collapse_padding) 0 else self.padding.left;
        const pad_right: usize = if (self.collapse_padding) 0 else self.padding.right;
        const content_width = if (width > pad_left + pad_right)
            width - pad_left - pad_right
        else
            width;

        var display_text = text;
        const text_width = cells.cellLen(text);

        if (col.no_wrap and text_width > content_width) {
            switch (col.overflow) {
                .fold => {},
                .ellipsis => {
                    const ellipsis_len = cells.cellLen(col.ellipsis);
                    if (content_width > ellipsis_len) {
                        const truncate_width = content_width - ellipsis_len;
                        const byte_pos = cells.cellToByteIndex(text, truncate_width);
                        display_text = text[0..byte_pos];
                    } else {
                        display_text = col.ellipsis;
                    }
                },
                .crop => {
                    const byte_pos = cells.cellToByteIndex(text, content_width);
                    display_text = text[0..byte_pos];
                },
            }
        }

        const display_width = cells.cellLen(display_text);
        const padding_total = if (content_width > display_width) content_width - display_width else 0;

        const needs_ellipsis = col.no_wrap and col.overflow == .ellipsis and text_width > content_width;
        const ellipsis_width = if (needs_ellipsis) cells.cellLen(col.ellipsis) else 0;

        var adjusted_padding: usize = padding_total;
        if (needs_ellipsis) {
            adjusted_padding = if (padding_total >= ellipsis_width) padding_total - ellipsis_width else 0;
        }

        const left_pad: usize = switch (justify) {
            .left => pad_left,
            .right => pad_left + adjusted_padding,
            .center => pad_left + adjusted_padding / 2,
        };
        const right_pad = if (width > left_pad + display_width + (if (needs_ellipsis) ellipsis_width else 0))
            width - left_pad - display_width - (if (needs_ellipsis) ellipsis_width else 0)
        else
            0;

        try self.renderSpaces(segments, allocator, left_pad);
        try segments.append(allocator, Segment.styledOptional(display_text, if (style.isEmpty()) null else style));

        if (needs_ellipsis) {
            try segments.append(allocator, Segment.styledOptional(col.ellipsis, if (style.isEmpty()) null else style));
        }

        try self.renderSpaces(segments, allocator, right_pad);
    }

    fn renderRichCell(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, content: CellContent, width: usize, justify: JustifyMethod, style: Style, _: Column) !void {
        const pad_left: usize = if (self.collapse_padding) 0 else self.padding.left;
        const pad_right: usize = if (self.collapse_padding) 0 else self.padding.right;
        const content_width = if (width > pad_left + pad_right)
            width - pad_left - pad_right
        else
            width;

        const cell_width = content.getCellWidth();
        const padding_total = if (content_width > cell_width) content_width - cell_width else 0;

        const left_pad: usize = switch (justify) {
            .left => pad_left,
            .right => pad_left + padding_total,
            .center => pad_left + padding_total / 2,
        };
        const right_pad = if (width > left_pad + cell_width)
            width - left_pad - cell_width
        else
            0;

        try self.renderSpaces(segments, allocator, left_pad);

        switch (content) {
            .text => |text| {
                try segments.append(allocator, Segment.styledOptional(text, if (style.isEmpty()) null else style));
            },
            .segments => |segs| {
                for (segs) |seg| {
                    const combined_style = if (seg.style) |s| style.combine(s) else style;
                    try segments.append(allocator, Segment.styledOptional(seg.text, if (combined_style.isEmpty()) null else combined_style));
                }
            },
        }

        try self.renderSpaces(segments, allocator, right_pad);
    }

    fn renderSpannedCell(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, cell: Cell, width: usize, justify: JustifyMethod, style: Style, _: Column) !void {
        const pad_left: usize = if (self.collapse_padding) 0 else self.padding.left;
        const pad_right: usize = if (self.collapse_padding) 0 else self.padding.right;
        const content_width = if (width > pad_left + pad_right)
            width - pad_left - pad_right
        else
            width;

        const cell_width = cell.getCellWidth();
        const padding_total = if (content_width > cell_width) content_width - cell_width else 0;

        const left_pad: usize = switch (justify) {
            .left => pad_left,
            .right => pad_left + padding_total,
            .center => pad_left + padding_total / 2,
        };
        const right_pad = if (width > left_pad + cell_width)
            width - left_pad - cell_width
        else
            0;

        try self.renderSpaces(segments, allocator, left_pad);

        switch (cell.content) {
            .text => |text| {
                try segments.append(allocator, Segment.styledOptional(text, if (style.isEmpty()) null else style));
            },
            .segments => |segs| {
                for (segs) |seg| {
                    const combined_style = if (seg.style) |s| style.combine(s) else style;
                    try segments.append(allocator, Segment.styledOptional(seg.text, if (combined_style.isEmpty()) null else combined_style));
                }
            },
        }

        try self.renderSpaces(segments, allocator, right_pad);
    }

    fn renderSpaces(_: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, count: usize) !void {
        for (0..count) |_| {
            try segments.append(allocator, Segment.plain(" "));
        }
    }

    fn renderFooterRow(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, footer_row: []const []const u8, widths: []usize, b: BoxStyle) !void {
        try segments.append(allocator, Segment.styled(b.left, self.border_style));

        for (self.columns.items, 0..) |col, i| {
            const cell = if (i < footer_row.len) footer_row[i] else "";
            const effective_style = self.footer_style.combine(col.style);

            try self.renderCell(segments, allocator, cell, widths[i], col.justify, effective_style, col);
            if (i < self.columns.items.len - 1) {
                try segments.append(allocator, Segment.styled(b.vertical, self.border_style));
            }
        }

        try segments.append(allocator, Segment.styled(b.right, self.border_style));
        try segments.append(allocator, Segment.line());
    }

    fn renderCaption(self: Table, segments: *std.ArrayList(Segment), allocator: std.mem.Allocator, widths: []usize, caption_text: []const u8) !void {
        var total_width: usize = 0;
        for (widths) |w| {
            total_width += w;
        }
        if (widths.len > 1) {
            total_width += widths.len - 1;
        }
        if (self.show_edge) {
            total_width += 2;
        }

        const caption_len = cells.cellLen(caption_text);
        const padding_total = if (total_width > caption_len) total_width - caption_len else 0;

        const left_pad: usize = switch (self.caption_justify) {
            .left => 0,
            .center => padding_total / 2,
            .right => padding_total,
        };
        const right_pad = padding_total - left_pad;

        try self.renderSpaces(segments, allocator, left_pad);
        try segments.append(allocator, Segment.styledOptional(caption_text, if (self.caption_style.isEmpty()) null else self.caption_style));
        try self.renderSpaces(segments, allocator, right_pad);
        try segments.append(allocator, Segment.line());
    }
};

test "Table.init" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.columns.items.len);
}

test "Table.addColumn" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("Name").addColumn("Value");

    try std.testing.expectEqual(@as(usize, 2), table.columns.items.len);
    try std.testing.expectEqualStrings("Name", table.columns.items[0].header);
}

test "Table.addRow" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B");
    try table.addRow(&.{ "1", "2" });
    try table.addRow(&.{ "3", "4" });

    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
}

test "Table.render basic" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("Name").addColumn("Value");
    try table.addRow(&.{ "foo", "bar" });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);
}

test "Column justify methods" {
    const col = Column.init("Test").withJustify(.center).withWidth(10);
    try std.testing.expectEqual(JustifyMethod.center, col.justify);
    try std.testing.expectEqual(@as(?usize, 10), col.width);
}

test "Table.withCaption" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withCaption("Table Caption");

    try std.testing.expectEqualStrings("Table Caption", table.caption.?);
}

test "Table.withCaptionStyle" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withCaptionStyle(Style.empty.italic());

    try std.testing.expect(table.caption_style.hasAttribute(.italic));
}

test "Table.withCaptionJustify" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withCaptionJustify(.right);

    try std.testing.expectEqual(JustifyMethod.right, table.caption_justify);
}

test "Table.render with caption" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B").withCaption("My Caption");
    try table.addRow(&.{ "1", "2" });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    var found_caption = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "My Caption") != null) {
            found_caption = true;
            break;
        }
    }
    try std.testing.expect(found_caption);
}

test "Column.withRatio" {
    const col = Column.init("Test").withRatio(2);
    try std.testing.expectEqual(@as(?u8, 2), col.ratio);
}

test "Column.withOverflow" {
    const col = Column.init("Test").withOverflow(.ellipsis);
    try std.testing.expectEqual(Overflow.ellipsis, col.overflow);
}

test "Column.withEllipsis" {
    const col = Column.init("Test").withEllipsis("..");
    try std.testing.expectEqualStrings("..", col.ellipsis);
}

test "Table.withAlternatingStyles" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withAlternatingStyles(Style.empty.dim(), Style.empty.bold());

    try std.testing.expect(table.alternating_styles != null);
    try std.testing.expect(table.alternating_styles.?.even.hasAttribute(.dim));
    try std.testing.expect(table.alternating_styles.?.odd.hasAttribute(.bold));
}

test "Table.addRowStyled" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A");
    try table.addRowStyled(&.{"1"}, Style.empty.bold());

    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expect(table.row_styles.items[0] != null);
    try std.testing.expect(table.row_styles.items[0].?.hasAttribute(.bold));
}

test "Table.withRowStyle" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A");
    try table.addRow(&.{"1"});
    _ = table.withRowStyle(0, Style.empty.italic());

    try std.testing.expect(table.row_styles.items[0] != null);
    try std.testing.expect(table.row_styles.items[0].?.hasAttribute(.italic));
}

test "Table.render with alternating styles" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A");
    _ = table.withAlternatingStyles(Style.empty.dim(), Style.empty.bold());
    try table.addRow(&.{"row0"});
    try table.addRow(&.{"row1"});
    try table.addRow(&.{"row2"});

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);
}

test "Table.render with ratio columns" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withColumn(Column.init("A").withRatio(1));
    _ = table.withColumn(Column.init("B").withRatio(2));
    _ = table.withColumn(Column.init("C").withRatio(1));
    try table.addRow(&.{ "one", "two", "three" });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);
}

test "Table.render with overflow ellipsis" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withColumn(Column.init("Col").withWidth(8).withNoWrap(true).withOverflow(.ellipsis));
    try table.addRow(&.{"This is a very long text"});

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);

    var found_ellipsis = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "...") != null) {
            found_ellipsis = true;
            break;
        }
    }
    try std.testing.expect(found_ellipsis);
}

test "Table.withCollapsePadding" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withCollapsePadding(true);
    try std.testing.expect(table.collapse_padding);
}

test "Table.render with collapse padding" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B").withCollapsePadding(true);
    try table.addRow(&.{ "1", "2" });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);
}

test "Table.withFooter" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withFooter(&.{ "Total", "100" });
    try std.testing.expect(table.footer != null);
}

test "Table.withFooterStyle" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.withFooterStyle(Style.empty.bold());
    try std.testing.expect(table.footer_style.hasAttribute(.bold));
}

test "Table.render with footer" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("Item").addColumn("Price");
    try table.addRow(&.{ "Apple", "1.00" });
    try table.addRow(&.{ "Banana", "0.50" });
    _ = table.withFooter(&.{ "Total", "1.50" });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);

    var found_total = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "Total") != null) {
            found_total = true;
            break;
        }
    }
    try std.testing.expect(found_total);
}

test "CellContent.text" {
    const content = CellContent{ .text = "hello" };
    try std.testing.expectEqualStrings("hello", content.getText());
    try std.testing.expectEqual(@as(usize, 5), content.getCellWidth());
}

test "CellContent.segments" {
    const segs = [_]Segment{
        Segment.plain("hello"),
        Segment.plain(" "),
        Segment.plain("world"),
    };
    const content = CellContent{ .segments = &segs };
    try std.testing.expectEqualStrings("hello", content.getText());
    try std.testing.expectEqual(@as(usize, 11), content.getCellWidth());
}

test "Table.addRowRich" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B");
    const segs = [_]Segment{Segment.styled("styled", Style.empty.bold())};
    try table.addRowRich(&.{
        CellContent{ .text = "plain" },
        CellContent{ .segments = &segs },
    });

    try std.testing.expectEqual(@as(usize, 1), table.rich_rows.items.len);
}

test "Table.render with rich rows" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("Name").addColumn("Status");
    const status_segs = [_]Segment{Segment.styled("OK", Style.empty.bold())};
    try table.addRowRich(&.{
        CellContent{ .text = "Server" },
        CellContent{ .segments = &status_segs },
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);

    var found_server = false;
    var found_ok = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "Server") != null) found_server = true;
        if (std.mem.indexOf(u8, seg.text, "OK") != null) found_ok = true;
    }
    try std.testing.expect(found_server);
    try std.testing.expect(found_ok);
}

test "Table.render mixed text and rich rows" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("Col");
    try table.addRow(&.{"text row"});

    const rich_segs = [_]Segment{Segment.plain("rich row")};
    try table.addRowRich(&.{CellContent{ .segments = &rich_segs }});

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    var found_text = false;
    var found_rich = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "text row") != null) found_text = true;
        if (std.mem.indexOf(u8, seg.text, "rich row") != null) found_rich = true;
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_rich);
}

// Cell type tests

test "Cell.text creates text cell" {
    const cell = Cell.text("hello");
    try std.testing.expectEqualStrings("hello", cell.content.getText());
    try std.testing.expectEqual(@as(u8, 1), cell.colspan);
    try std.testing.expectEqual(@as(u8, 1), cell.rowspan);
}

test "Cell.withColspan sets column span" {
    const cell = Cell.text("hello").withColspan(3);
    try std.testing.expectEqual(@as(u8, 3), cell.colspan);
}

test "Cell.withRowspan sets row span" {
    const cell = Cell.text("hello").withRowspan(2);
    try std.testing.expectEqual(@as(u8, 2), cell.rowspan);
}

test "Cell.withColspan zero defaults to 1" {
    const cell = Cell.text("hello").withColspan(0);
    try std.testing.expectEqual(@as(u8, 1), cell.colspan);
}

test "Cell.withRowspan zero defaults to 1" {
    const cell = Cell.text("hello").withRowspan(0);
    try std.testing.expectEqual(@as(u8, 1), cell.rowspan);
}

test "Cell.withStyle sets cell style" {
    const cell = Cell.text("hello").withStyle(Style.empty.bold());
    try std.testing.expect(cell.style != null);
    try std.testing.expect(cell.style.?.hasAttribute(.bold));
}

test "Cell.withJustify sets cell justification" {
    const cell = Cell.text("hello").withJustify(.center);
    try std.testing.expectEqual(JustifyMethod.center, cell.justify.?);
}

test "Cell.getCellWidth returns content width" {
    const cell = Cell.text("hello");
    try std.testing.expectEqual(@as(usize, 5), cell.getCellWidth());
}

// Spanned row tests

test "Table.addSpannedRow adds row with cells" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B").addColumn("C");
    try table.addSpannedRow(&.{
        Cell.text("spanning").withColspan(2),
        Cell.text("single"),
    });

    try std.testing.expectEqual(@as(usize, 1), table.spanned_rows.items.len);
}

test "Table.addSpannedRowStyled adds row with style" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A");
    try table.addSpannedRowStyled(&.{Cell.text("test")}, Style.empty.bold());

    try std.testing.expectEqual(@as(usize, 1), table.spanned_rows.items.len);
    try std.testing.expect(table.spanned_row_styles.items[0] != null);
    try std.testing.expect(table.spanned_row_styles.items[0].?.hasAttribute(.bold));
}

test "Table.render with colspan cells" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B").addColumn("C");
    try table.addSpannedRow(&.{
        Cell.text("spans two").withColspan(2),
        Cell.text("single"),
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);

    var found_spanning = false;
    var found_single = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "spans two") != null) found_spanning = true;
        if (std.mem.indexOf(u8, seg.text, "single") != null) found_single = true;
    }
    try std.testing.expect(found_spanning);
    try std.testing.expect(found_single);
}

test "Table.render with full row colspan" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B").addColumn("C");
    try table.addSpannedRow(&.{
        Cell.text("spans all three").withColspan(3),
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    var found_text = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "spans all three") != null) {
            found_text = true;
            break;
        }
    }
    try std.testing.expect(found_text);
}

test "Table.render with rowspan cells" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B");
    try table.addSpannedRow(&.{
        Cell.text("spans 2 rows").withRowspan(2),
        Cell.text("row1 col2"),
    });
    try table.addSpannedRow(&.{
        Cell.text("row2 col2"),
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    var found_spanning = false;
    var found_row1 = false;
    var found_row2 = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "spans 2 rows") != null) found_spanning = true;
        if (std.mem.indexOf(u8, seg.text, "row1 col2") != null) found_row1 = true;
        if (std.mem.indexOf(u8, seg.text, "row2 col2") != null) found_row2 = true;
    }
    try std.testing.expect(found_spanning);
    try std.testing.expect(found_row1);
    try std.testing.expect(found_row2);
}

test "Table.render with combined colspan and rowspan" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B").addColumn("C");
    try table.addSpannedRow(&.{
        Cell.text("2x2").withColspan(2).withRowspan(2),
        Cell.text("r1c3"),
    });
    try table.addSpannedRow(&.{
        Cell.text("r2c3"),
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    var found_2x2 = false;
    var found_r1c3 = false;
    var found_r2c3 = false;
    for (segments) |seg| {
        if (std.mem.indexOf(u8, seg.text, "2x2") != null) found_2x2 = true;
        if (std.mem.indexOf(u8, seg.text, "r1c3") != null) found_r1c3 = true;
        if (std.mem.indexOf(u8, seg.text, "r2c3") != null) found_r2c3 = true;
    }
    try std.testing.expect(found_2x2);
    try std.testing.expect(found_r1c3);
    try std.testing.expect(found_r2c3);
}

test "Table.render spanned row with cell style override" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").addColumn("B");
    try table.addSpannedRow(&.{
        Cell.text("styled").withStyle(Style.empty.bold()),
        Cell.text("normal"),
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);
}

test "Table.render spanned row with cell justify override" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    _ = table.addColumn("A").withColumn(Column.init("B").withJustify(.left));
    try table.addSpannedRow(&.{
        Cell.text("left"),
        Cell.text("centered").withJustify(.center),
    });

    const segments = try table.render(80, allocator);
    defer allocator.free(segments);

    try std.testing.expect(segments.len > 0);
}

test "Cell.segments creates segment cell" {
    const segs = [_]Segment{Segment.plain("hello")};
    const cell = Cell.segments(&segs);
    try std.testing.expectEqual(@as(usize, 5), cell.getCellWidth());
}

test "RowSpanTracker basic functionality" {
    const allocator = std.testing.allocator;
    var tracker = try RowSpanTracker.init(allocator, 3);
    defer tracker.deinit();

    // Initially no columns are blocked
    try std.testing.expect(!tracker.isBlocked(0));
    try std.testing.expect(!tracker.isBlocked(1));
    try std.testing.expect(!tracker.isBlocked(2));

    // Register a cell with rowspan 2 at column 0
    const cell = Cell.text("test").withRowspan(2);
    tracker.registerSpan(0, cell);

    // After registration, column 0 should be blocked for the next row
    try std.testing.expect(tracker.isBlocked(0));
    try std.testing.expect(!tracker.isBlocked(1));

    // After advancing once, still blocked (rowspan=2 means 1 more row to block)
    tracker.advanceRow();
    try std.testing.expect(tracker.isBlocked(0));

    // After advancing again, no longer blocked
    tracker.advanceRow();
    try std.testing.expect(!tracker.isBlocked(0));
}

test "RowSpanTracker with colspan" {
    const allocator = std.testing.allocator;
    var tracker = try RowSpanTracker.init(allocator, 4);
    defer tracker.deinit();

    // Register a cell with colspan 2 and rowspan 2
    const cell = Cell.text("test").withColspan(2).withRowspan(2);
    tracker.registerSpan(1, cell);

    // Columns 1 and 2 should be blocked
    try std.testing.expect(!tracker.isBlocked(0));
    try std.testing.expect(tracker.isBlocked(1));
    try std.testing.expect(tracker.isBlocked(2));
    try std.testing.expect(!tracker.isBlocked(3));
}
