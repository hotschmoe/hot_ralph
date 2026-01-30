Let me fetch that repository to understand its structure and capabilities.Now I have a solid understanding of the library. Let me create a comprehensive porting plan for you.

---

# Plan: Porting `rich_rust` to Zig (https://github.com/Dicklesworthstone/rich_rust - https://github.com/Textualize/rich)

## Overview

Python's Rich and `rich_rust` are comprehensive terminal output libraries with styled text, tables, panels, progress bars, trees, syntax highlighting, and more. Porting to Zig aligns well with your ReclaimerOS work and preference for minimal-bloat systems.

---

## Phase 1: Core Foundation (Weeks 1-2)

### 1.1 Color System (`color.zig`)

The color module handles 4-bit (standard), 8-bit (256), and 24-bit (truecolor) palettes with automatic downgrading.

```zig
// src/color.zig
const std = @import("std");

pub const ColorType = enum {
    default,
    standard,    // 16 colors (0-15)
    eight_bit,   // 256 colors (0-255)
    truecolor,   // RGB 24-bit
};

pub const ColorSystem = enum(u8) {
    standard = 1,
    eight_bit = 2,
    truecolor = 3,
    
    pub fn supports(self: ColorSystem, other: ColorSystem) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

pub const ColorTriplet = struct {
    r: u8,
    g: u8,
    b: u8,
    
    pub fn hex(self: ColorTriplet) [7]u8 {
        var buf: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf;
    }
    
    pub fn blend(c1: ColorTriplet, c2: ColorTriplet, t: f32) ColorTriplet {
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(c1.r)) + (@as(f32, @floatFromInt(c2.r)) - @as(f32, @floatFromInt(c1.r))) * t),
            .g = @intFromFloat(@as(f32, @floatFromInt(c1.g)) + (@as(f32, @floatFromInt(c2.g)) - @as(f32, @floatFromInt(c1.g))) * t),
            .b = @intFromFloat(@as(f32, @floatFromInt(c1.b)) + (@as(f32, @floatFromInt(c2.b)) - @as(f32, @floatFromInt(c1.b))) * t),
        };
    }
};

pub const Color = struct {
    name: []const u8,
    type: ColorType,
    number: ?u8 = null,
    triplet: ?ColorTriplet = null,
    
    pub const default = Color{ .name = "default", .type = .default };
    
    // Standard 16 colors
    pub const black = Color{ .name = "black", .type = .standard, .number = 0 };
    pub const red = Color{ .name = "red", .type = .standard, .number = 1 };
    pub const green = Color{ .name = "green", .type = .standard, .number = 2 };
    pub const yellow = Color{ .name = "yellow", .type = .standard, .number = 3 };
    pub const blue = Color{ .name = "blue", .type = .standard, .number = 4 };
    pub const magenta = Color{ .name = "magenta", .type = .standard, .number = 5 };
    pub const cyan = Color{ .name = "cyan", .type = .standard, .number = 6 };
    pub const white = Color{ .name = "white", .type = .standard, .number = 7 };
    // Bright variants (8-15)
    pub const bright_black = Color{ .name = "bright_black", .type = .standard, .number = 8 };
    pub const bright_red = Color{ .name = "bright_red", .type = .standard, .number = 9 };
    // ... etc
    
    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{
            .name = "rgb",
            .type = .truecolor,
            .triplet = .{ .r = r, .g = g, .b = b },
        };
    }
    
    pub fn fromHex(hex: []const u8) !Color {
        const start: usize = if (hex[0] == '#') 1 else 0;
        if (hex.len - start != 6) return error.InvalidHexColor;
        
        const r = try std.fmt.parseInt(u8, hex[start..][0..2], 16);
        const g = try std.fmt.parseInt(u8, hex[start..][2..4], 16);
        const b = try std.fmt.parseInt(u8, hex[start..][4..6], 16);
        
        return fromRgb(r, g, b);
    }
    
    pub fn from256(number: u8) Color {
        return .{
            .name = "color256",
            .type = .eight_bit,
            .number = number,
        };
    }
    
    /// Downgrade color to fit target color system
    pub fn downgrade(self: Color, target: ColorSystem) Color {
        return switch (self.type) {
            .default => self,
            .standard => self,
            .eight_bit => if (target == .standard) 
                self.toStandard() 
            else 
                self,
            .truecolor => switch (target) {
                .standard => self.toStandard(),
                .eight_bit => self.to256(),
                .truecolor => self,
            },
        };
    }
    
    fn toStandard(self: Color) Color {
        // Convert to nearest standard color using distance calculation
        // ... implementation
        return Color.white; // placeholder
    }
    
    fn to256(self: Color) Color {
        if (self.triplet) |t| {
            // Use 6x6x6 color cube + grayscale ramp
            const number = rgbTo256(t.r, t.g, t.b);
            return Color.from256(number);
        }
        return self;
    }
    
    /// Generate ANSI escape codes
    pub fn getAnsiCodes(self: Color, foreground: bool, writer: anytype) !void {
        const base: u8 = if (foreground) 30 else 40;
        
        switch (self.type) {
            .default => try writer.print("{d}", .{if (foreground) @as(u8, 39) else @as(u8, 49)}),
            .standard => {
                if (self.number.? < 8) {
                    try writer.print("{d}", .{base + self.number.?});
                } else {
                    try writer.print("{d}", .{base + 60 + self.number.? - 8});
                }
            },
            .eight_bit => {
                try writer.print("{d};5;{d}", .{ if (foreground) @as(u8, 38) else @as(u8, 48), self.number.? });
            },
            .truecolor => {
                const t = self.triplet.?;
                try writer.print("{d};2;{d};{d};{d}", .{ 
                    if (foreground) @as(u8, 38) else @as(u8, 48), 
                    t.r, t.g, t.b 
                });
            },
        }
    }
};

fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Check for grayscale
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return @as(u8, @intFromFloat((@as(f32, @floatFromInt(r)) - 8.0) / 247.0 * 24.0)) + 232;
    }
    // Use 6x6x6 color cube
    const ri: u8 = @intFromFloat(@as(f32, @floatFromInt(r)) / 255.0 * 5.0);
    const gi: u8 = @intFromFloat(@as(f32, @floatFromInt(g)) / 255.0 * 5.0);
    const bi: u8 = @intFromFloat(@as(f32, @floatFromInt(b)) / 255.0 * 5.0);
    return 16 + 36 * ri + 6 * gi + bi;
}
```

### 1.2 Style System (`style.zig`)

```zig
// src/style.zig
const std = @import("std");
const Color = @import("color.zig").Color;

pub const StyleAttribute = enum(u4) {
    bold = 0,
    dim = 1,
    italic = 2,
    underline = 3,
    blink = 4,
    blink2 = 5,
    reverse = 6,
    conceal = 7,
    strike = 8,
};

pub const Style = struct {
    color: ?Color = null,
    bgcolor: ?Color = null,
    attributes: u16 = 0,        // Bitmask of which attributes are set
    set_attributes: u16 = 0,    // Bitmask of which attributes have been explicitly set
    link: ?[]const u8 = null,
    
    pub const empty = Style{};
    
    pub fn bold(self: Style) Style {
        var s = self;
        s.attributes |= (1 << @intFromEnum(StyleAttribute.bold));
        s.set_attributes |= (1 << @intFromEnum(StyleAttribute.bold));
        return s;
    }
    
    pub fn italic(self: Style) Style {
        var s = self;
        s.attributes |= (1 << @intFromEnum(StyleAttribute.italic));
        s.set_attributes |= (1 << @intFromEnum(StyleAttribute.italic));
        return s;
    }
    
    pub fn underline(self: Style) Style {
        var s = self;
        s.attributes |= (1 << @intFromEnum(StyleAttribute.underline));
        s.set_attributes |= (1 << @intFromEnum(StyleAttribute.underline));
        return s;
    }
    
    pub fn dim(self: Style) Style {
        var s = self;
        s.attributes |= (1 << @intFromEnum(StyleAttribute.dim));
        s.set_attributes |= (1 << @intFromEnum(StyleAttribute.dim));
        return s;
    }
    
    pub fn strikethrough(self: Style) Style {
        var s = self;
        s.attributes |= (1 << @intFromEnum(StyleAttribute.strike));
        s.set_attributes |= (1 << @intFromEnum(StyleAttribute.strike));
        return s;
    }
    
    pub fn reverse(self: Style) Style {
        var s = self;
        s.attributes |= (1 << @intFromEnum(StyleAttribute.reverse));
        s.set_attributes |= (1 << @intFromEnum(StyleAttribute.reverse));
        return s;
    }
    
    pub fn foreground(self: Style, c: Color) Style {
        var s = self;
        s.color = c;
        return s;
    }
    
    pub fn background(self: Style, c: Color) Style {
        var s = self;
        s.bgcolor = c;
        return s;
    }
    
    pub fn hyperlink(self: Style, url: []const u8) Style {
        var s = self;
        s.link = url;
        return s;
    }
    
    /// Combine two styles (other overrides self)
    pub fn combine(self: Style, other: Style) Style {
        return .{
            .color = other.color orelse self.color,
            .bgcolor = other.bgcolor orelse self.bgcolor,
            .attributes = (self.attributes & ~other.set_attributes) | other.attributes,
            .set_attributes = self.set_attributes | other.set_attributes,
            .link = other.link orelse self.link,
        };
    }
    
    /// Parse style from string like "bold red on white"
    pub fn parse(definition: []const u8) !Style {
        var style = Style{};
        var on_background = false;
        
        var iter = std.mem.splitScalar(u8, definition, ' ');
        while (iter.next()) |token| {
            if (token.len == 0) continue;
            
            if (std.mem.eql(u8, token, "on")) {
                on_background = true;
                continue;
            }
            
            // Check attributes
            if (std.mem.eql(u8, token, "bold") or std.mem.eql(u8, token, "b")) {
                style = style.bold();
            } else if (std.mem.eql(u8, token, "italic") or std.mem.eql(u8, token, "i")) {
                style = style.italic();
            } else if (std.mem.eql(u8, token, "underline") or std.mem.eql(u8, token, "u")) {
                style = style.underline();
            } else if (std.mem.eql(u8, token, "dim") or std.mem.eql(u8, token, "d")) {
                style = style.dim();
            } else if (std.mem.eql(u8, token, "strike") or std.mem.eql(u8, token, "s")) {
                style = style.strikethrough();
            } else if (std.mem.eql(u8, token, "reverse") or std.mem.eql(u8, token, "r")) {
                style = style.reverse();
            } else {
                // Try to parse as color
                const color = try parseColor(token);
                if (on_background) {
                    style.bgcolor = color;
                    on_background = false;
                } else {
                    style.color = color;
                }
            }
        }
        
        return style;
    }
    
    fn parseColor(token: []const u8) !Color {
        // Named colors
        const named_colors = .{
            .{ "black", Color.black },
            .{ "red", Color.red },
            .{ "green", Color.green },
            .{ "yellow", Color.yellow },
            .{ "blue", Color.blue },
            .{ "magenta", Color.magenta },
            .{ "cyan", Color.cyan },
            .{ "white", Color.white },
        };
        
        inline for (named_colors) |pair| {
            if (std.mem.eql(u8, token, pair[0])) return pair[1];
        }
        
        // Hex color
        if (token[0] == '#') {
            return Color.fromHex(token);
        }
        
        // rgb(r,g,b)
        if (std.mem.startsWith(u8, token, "rgb(")) {
            // Parse RGB...
        }
        
        // color(N) for 256 palette
        if (std.mem.startsWith(u8, token, "color(")) {
            const num_str = token[6 .. token.len - 1];
            const num = try std.fmt.parseInt(u8, num_str, 10);
            return Color.from256(num);
        }
        
        return error.UnknownColor;
    }
    
    /// Render ANSI SGR sequence
    pub fn renderAnsi(self: Style, color_system: @import("color.zig").ColorSystem, writer: anytype) !void {
        var codes = std.ArrayList(u8).init(std.heap.page_allocator);
        defer codes.deinit();
        
        // Attributes
        const sgr_map = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
        var i: u4 = 0;
        while (i < 9) : (i += 1) {
            if (self.attributes & (@as(u16, 1) << i) != 0) {
                try codes.append(sgr_map[i]);
            }
        }
        
        // Colors
        if (self.color) |c| {
            const downgraded = c.downgrade(color_system);
            // ... generate codes
        }
        
        if (self.bgcolor) |c| {
            const downgraded = c.downgrade(color_system);
            // ... generate codes
        }
        
        if (codes.items.len > 0) {
            try writer.writeAll("\x1b[");
            for (codes.items, 0..) |code, idx| {
                if (idx > 0) try writer.writeByte(';');
                try writer.print("{d}", .{code});
            }
            try writer.writeByte('m');
        }
    }
};
```

### 1.3 Segment (`segment.zig`)

Segments are the atomic rendering unit - text with optional style.

```zig
// src/segment.zig
const std = @import("std");
const Style = @import("style.zig").Style;

pub const ControlType = enum {
    bell,
    carriage_return,
    home,
    clear,
    show_cursor,
    hide_cursor,
    enable_alt_screen,
    disable_alt_screen,
    cursor_up,
    cursor_down,
    cursor_forward,
    cursor_backward,
    cursor_move_to_column,
    cursor_move_to,
    erase_in_line,
    set_window_title,
};

pub const ControlCode = union(ControlType) {
    bell: void,
    carriage_return: void,
    home: void,
    clear: void,
    show_cursor: void,
    hide_cursor: void,
    enable_alt_screen: void,
    disable_alt_screen: void,
    cursor_up: u16,
    cursor_down: u16,
    cursor_forward: u16,
    cursor_backward: u16,
    cursor_move_to_column: u16,
    cursor_move_to: struct { x: u16, y: u16 },
    erase_in_line: u8,
    set_window_title: []const u8,
};

pub const Segment = struct {
    text: []const u8,
    style: ?Style = null,
    control: ?[]const ControlCode = null,
    
    pub fn plain(text: []const u8) Segment {
        return .{ .text = text };
    }
    
    pub fn styled(text: []const u8, style: Style) Segment {
        return .{ .text = text, .style = style };
    }
    
    pub fn controlSeg(code: ControlCode) Segment {
        return .{ .text = "", .control = &[_]ControlCode{code} };
    }
    
    pub fn line() Segment {
        return plain("\n");
    }
    
    /// Calculate cell width of this segment
    pub fn cellLength(self: Segment) usize {
        return @import("cells.zig").cellLen(self.text);
    }
    
    pub fn isControl(self: Segment) bool {
        return self.control != null;
    }
    
    /// Split segment at cell position
    pub fn splitCells(self: Segment, pos: usize, allocator: std.mem.Allocator) !struct { Segment, Segment } {
        const cells = @import("cells.zig");
        var current_pos: usize = 0;
        var byte_pos: usize = 0;
        
        const view = std.unicode.Utf8View.initUnchecked(self.text);
        var iter = view.iterator();
        
        while (iter.nextCodepoint()) |cp| {
            const char_width = cells.getCharacterCellSize(cp);
            if (current_pos + char_width > pos) break;
            current_pos += char_width;
            byte_pos = iter.i;
        }
        
        return .{
            Segment{ .text = self.text[0..byte_pos], .style = self.style },
            Segment{ .text = self.text[byte_pos..], .style = self.style },
        };
    }
};

/// Strip all styles from segments
pub fn stripStyles(segments: []const Segment, allocator: std.mem.Allocator) ![]Segment {
    var result = try allocator.alloc(Segment, segments.len);
    for (segments, 0..) |seg, i| {
        result[i] = .{ .text = seg.text, .control = seg.control };
    }
    return result;
}

/// Split segments at cell positions (for word wrapping, column division)
pub fn divide(
    segments: []const Segment,
    cuts: []const usize,
    allocator: std.mem.Allocator,
) ![][]Segment {
    var result = std.ArrayList([]Segment).init(allocator);
    // ... implementation
    return result.toOwnedSlice();
}
```

### 1.4 Cells / Unicode Width (`cells.zig`)

```zig
// src/cells.zig
const std = @import("std");

/// Get the display width of a Unicode codepoint
pub fn getCharacterCellSize(codepoint: u21) usize {
    // Zero-width characters
    if (codepoint == 0x200B or // Zero-width space
        codepoint == 0x200C or // Zero-width non-joiner
        codepoint == 0x200D or // Zero-width joiner
        codepoint == 0xFEFF)   // BOM
    {
        return 0;
    }
    
    // Combining characters
    if (isCombining(codepoint)) return 0;
    
    // Control characters
    if (codepoint < 32 or (codepoint >= 0x7F and codepoint < 0xA0)) {
        return 0;
    }
    
    // Wide characters (CJK, emoji, etc.)
    if (isWide(codepoint)) return 2;
    
    return 1;
}

fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or  // Combining Diacritical Marks
           (cp >= 0x1AB0 and cp <= 0x1AFF) or  // Combining Diacritical Marks Extended
           (cp >= 0x1DC0 and cp <= 0x1DFF) or  // Combining Diacritical Marks Supplement
           (cp >= 0x20D0 and cp <= 0x20FF) or  // Combining Diacritical Marks for Symbols
           (cp >= 0xFE20 and cp <= 0xFE2F);    // Combining Half Marks
}

fn isWide(cp: u21) bool {
    // CJK ranges (simplified)
    return (cp >= 0x1100 and cp <= 0x115F) or   // Hangul Jamo
           (cp >= 0x2E80 and cp <= 0x9FFF) or   // CJK
           (cp >= 0xAC00 and cp <= 0xD7A3) or   // Hangul Syllables
           (cp >= 0xF900 and cp <= 0xFAFF) or   // CJK Compatibility Ideographs
           (cp >= 0xFE10 and cp <= 0xFE1F) or   // Vertical Forms
           (cp >= 0xFE30 and cp <= 0xFE6F) or   // CJK Compatibility Forms
           (cp >= 0xFF00 and cp <= 0xFF60) or   // Fullwidth Forms
           (cp >= 0x20000 and cp <= 0x2FFFD) or // CJK Extension B+
           (cp >= 0x30000 and cp <= 0x3FFFD) or // CJK Extension G+
           // Emoji (basic ranges)
           (cp >= 0x1F300 and cp <= 0x1F9FF);
}

/// Calculate the cell width of a string
pub fn cellLen(text: []const u8) usize {
    var width: usize = 0;
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        width += getCharacterCellSize(cp);
    }
    return width;
}

/// Truncate text to fit within max_width cells
pub fn truncate(text: []const u8, max_width: usize, ellipsis: []const u8) []const u8 {
    var width: usize = 0;
    var byte_pos: usize = 0;
    const ellipsis_width = cellLen(ellipsis);
    
    const view = std.unicode.Utf8View.initUnchecked(text);
    var iter = view.iterator();
    
    while (iter.nextCodepoint()) |cp| {
        const char_width = getCharacterCellSize(cp);
        if (width + char_width + ellipsis_width > max_width) break;
        width += char_width;
        byte_pos = iter.i;
    }
    
    if (byte_pos < text.len) {
        // Would need allocator to append ellipsis - return truncated for now
        return text[0..byte_pos];
    }
    return text;
}
```

---

## Phase 2: Markup Parser & Text (Weeks 2-3)

### 2.1 Markup Parser (`markup.zig`)

```zig
// src/markup.zig
const std = @import("std");
const Style = @import("style.zig").Style;

pub const Tag = struct {
    name: []const u8,
    parameters: ?[]const u8 = null,
};

pub const MarkupToken = union(enum) {
    text: []const u8,
    open_tag: Tag,
    close_tag: ?[]const u8,  // null means [/]
};

pub const MarkupError = error{
    UnbalancedBracket,
    InvalidTag,
    UnclosedTag,
};

/// Parse markup text into tokens
pub fn parseMarkup(text: []const u8, allocator: std.mem.Allocator) ![]MarkupToken {
    var tokens = std.ArrayList(MarkupToken).init(allocator);
    var i: usize = 0;
    var text_start: usize = 0;
    
    while (i < text.len) {
        // Escaped bracket
        if (i + 1 < text.len and text[i] == '\\' and (text[i + 1] == '[' or text[i + 1] == ']')) {
            if (i > text_start) {
                try tokens.append(.{ .text = text[text_start..i] });
            }
            try tokens.append(.{ .text = text[i + 1 .. i + 2] });
            i += 2;
            text_start = i;
            continue;
        }
        
        // Start of tag
        if (text[i] == '[') {
            if (i > text_start) {
                try tokens.append(.{ .text = text[text_start..i] });
            }
            
            // Find closing bracket
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse 
                return MarkupError.UnbalancedBracket;
            
            const tag_content = text[i + 1 .. end];
            
            if (tag_content.len == 0) {
                return MarkupError.InvalidTag;
            }
            
            if (tag_content[0] == '/') {
                // Close tag
                const tag_name = if (tag_content.len > 1) tag_content[1..] else null;
                try tokens.append(.{ .close_tag = tag_name });
            } else {
                // Open tag
                try tokens.append(.{ .open_tag = .{ .name = tag_content } });
            }
            
            i = end + 1;
            text_start = i;
            continue;
        }
        
        i += 1;
    }
    
    // Remaining text
    if (text_start < text.len) {
        try tokens.append(.{ .text = text[text_start..] });
    }
    
    return tokens.toOwnedSlice();
}

/// Convert markup to segments
pub fn render(text: []const u8, base_style: Style, allocator: std.mem.Allocator) ![]@import("segment.zig").Segment {
    const Segment = @import("segment.zig").Segment;
    const tokens = try parseMarkup(text, allocator);
    defer allocator.free(tokens);
    
    var segments = std.ArrayList(Segment).init(allocator);
    var style_stack = std.ArrayList(Style).init(allocator);
    defer style_stack.deinit();
    
    try style_stack.append(base_style);
    
    for (tokens) |token| {
        switch (token) {
            .text => |txt| {
                const current_style = style_stack.items[style_stack.items.len - 1];
                try segments.append(Segment.styled(txt, current_style));
            },
            .open_tag => |tag| {
                const current_style = style_stack.items[style_stack.items.len - 1];
                const new_style = try Style.parse(tag.name);
                try style_stack.append(current_style.combine(new_style));
            },
            .close_tag => {
                if (style_stack.items.len > 1) {
                    _ = style_stack.pop();
                }
            },
        }
    }
    
    return segments.toOwnedSlice();
}
```

### 2.2 Text with Spans (`text.zig`)

```zig
// src/text.zig
const std = @import("std");
const Style = @import("style.zig").Style;
const Segment = @import("segment.zig").Segment;
const markup = @import("markup.zig");
const cells = @import("cells.zig");

pub const Span = struct {
    start: usize,
    end: usize,
    style: Style,
};

pub const Text = struct {
    plain: []const u8,
    spans: []Span,
    style: Style,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Text {
        return .{
            .plain = "",
            .spans = &[_]Span{},
            .style = Style.empty,
            .allocator = allocator,
        };
    }
    
    pub fn fromPlain(allocator: std.mem.Allocator, text: []const u8) Text {
        return .{
            .plain = text,
            .spans = &[_]Span{},
            .style = Style.empty,
            .allocator = allocator,
        };
    }
    
    /// Parse markup syntax
    pub fn fromMarkup(allocator: std.mem.Allocator, text: []const u8) !Text {
        // Parse and extract plain text + spans
        var plain_buf = std.ArrayList(u8).init(allocator);
        var spans_buf = std.ArrayList(Span).init(allocator);
        
        const tokens = try markup.parseMarkup(text, allocator);
        defer allocator.free(tokens);
        
        var style_stack = std.ArrayList(Style).init(allocator);
        defer style_stack.deinit();
        try style_stack.append(Style.empty);
        
        for (tokens) |token| {
            switch (token) {
                .text => |txt| {
                    const start = plain_buf.items.len;
                    try plain_buf.appendSlice(txt);
                    const end = plain_buf.items.len;
                    
                    const current_style = style_stack.items[style_stack.items.len - 1];
                    if (current_style.attributes != 0 or current_style.color != null or current_style.bgcolor != null) {
                        try spans_buf.append(.{
                            .start = start,
                            .end = end,
                            .style = current_style,
                        });
                    }
                },
                .open_tag => |tag| {
                    const current_style = style_stack.items[style_stack.items.len - 1];
                    const new_style = try Style.parse(tag.name);
                    try style_stack.append(current_style.combine(new_style));
                },
                .close_tag => {
                    if (style_stack.items.len > 1) {
                        _ = style_stack.pop();
                    }
                },
            }
        }
        
        return .{
            .plain = try plain_buf.toOwnedSlice(),
            .spans = try spans_buf.toOwnedSlice(),
            .style = Style.empty,
            .allocator = allocator,
        };
    }
    
    pub fn cellLength(self: Text) usize {
        return cells.cellLen(self.plain);
    }
    
    /// Render to segments
    pub fn render(self: Text, allocator: std.mem.Allocator) ![]Segment {
        if (self.spans.len == 0) {
            var result = try allocator.alloc(Segment, 1);
            result[0] = Segment.styled(self.plain, self.style);
            return result;
        }
        
        var segments = std.ArrayList(Segment).init(allocator);
        var pos: usize = 0;
        
        for (self.spans) |span| {
            // Text before span
            if (span.start > pos) {
                try segments.append(Segment.styled(self.plain[pos..span.start], self.style));
            }
            // Span text
            try segments.append(Segment.styled(
                self.plain[span.start..span.end],
                self.style.combine(span.style),
            ));
            pos = span.end;
        }
        
        // Remaining text
        if (pos < self.plain.len) {
            try segments.append(Segment.styled(self.plain[pos..], self.style));
        }
        
        return segments.toOwnedSlice();
    }
    
    pub fn append(self: *Text, other: Text) !void {
        const offset = self.plain.len;
        
        // Append plain text
        var new_plain = try self.allocator.alloc(u8, self.plain.len + other.plain.len);
        @memcpy(new_plain[0..self.plain.len], self.plain);
        @memcpy(new_plain[self.plain.len..], other.plain);
        
        // Append spans with offset
        var new_spans = try self.allocator.alloc(Span, self.spans.len + other.spans.len);
        @memcpy(new_spans[0..self.spans.len], self.spans);
        for (other.spans, 0..) |span, i| {
            new_spans[self.spans.len + i] = .{
                .start = span.start + offset,
                .end = span.end + offset,
                .style = span.style,
            };
        }
        
        self.plain = new_plain;
        self.spans = new_spans;
    }
    
    pub fn deinit(self: *Text) void {
        if (self.spans.len > 0) {
            self.allocator.free(self.spans);
        }
        // Note: plain text lifetime depends on source
    }
};
```

---

## Phase 3: Console & Terminal Detection (Weeks 3-4)

### 3.1 Terminal Detection (`terminal.zig`)

```zig
// src/terminal.zig
const std = @import("std");
const builtin = @import("builtin");
const ColorSystem = @import("color.zig").ColorSystem;

pub const TerminalInfo = struct {
    width: u16,
    height: u16,
    color_system: ColorSystem,
    is_tty: bool,
    supports_unicode: bool,
    supports_hyperlinks: bool,
    term: ?[]const u8,
};

pub fn detect() TerminalInfo {
    const stdout = std.io.getStdOut();
    const is_tty = stdout.isTty();
    
    var info = TerminalInfo{
        .width = 80,
        .height = 24,
        .color_system = .standard,
        .is_tty = is_tty,
        .supports_unicode = true,
        .supports_hyperlinks = false,
        .term = std.posix.getenv("TERM"),
    };
    
    if (!is_tty) {
        // Check FORCE_COLOR
        if (std.posix.getenv("FORCE_COLOR")) |_| {
            info.color_system = .truecolor;
        } else {
            info.color_system = .standard;
        }
        return info;
    }
    
    // Get terminal size
    if (builtin.os.tag != .windows) {
        var ws: std.posix.winsize = undefined;
        if (std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0) {
            info.width = ws.ws_col;
            info.height = ws.ws_row;
        }
    }
    
    // Detect color support
    info.color_system = detectColorSystem();
    
    // Detect hyperlink support
    info.supports_hyperlinks = detectHyperlinks();
    
    return info;
}

fn detectColorSystem() ColorSystem {
    // Check COLORTERM
    if (std.posix.getenv("COLORTERM")) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
            return .truecolor;
        }
    }
    
    // Check TERM
    if (std.posix.getenv("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "256color") != null or
            std.mem.indexOf(u8, term, "256") != null)
        {
            return .eight_bit;
        }
        if (std.mem.indexOf(u8, term, "truecolor") != null) {
            return .truecolor;
        }
    }
    
    // Check terminal program
    if (std.posix.getenv("TERM_PROGRAM")) |prog| {
        const truecolor_terminals = [_][]const u8{
            "iTerm.app", "Apple_Terminal", "WezTerm", "vscode",
            "Hyper", "mintty", "Terminus",
        };
        for (truecolor_terminals) |t| {
            if (std.mem.eql(u8, prog, t)) return .truecolor;
        }
    }
    
    // Windows Terminal
    if (std.posix.getenv("WT_SESSION")) |_| {
        return .truecolor;
    }
    
    return .eight_bit;  // Default for modern terminals
}

fn detectHyperlinks() bool {
    // OSC 8 hyperlink support
    if (std.posix.getenv("TERM_PROGRAM")) |prog| {
        const supported = [_][]const u8{
            "iTerm.app", "WezTerm", "vscode", "Hyper",
        };
        for (supported) |t| {
            if (std.mem.eql(u8, prog, t)) return true;
        }
    }
    return false;
}
```

### 3.2 Console (`console.zig`)

```zig
// src/console.zig
const std = @import("std");
const Style = @import("style.zig").Style;
const Segment = @import("segment.zig").Segment;
const Text = @import("text.zig").Text;
const ColorSystem = @import("color.zig").ColorSystem;
const terminal = @import("terminal.zig");

pub const ConsoleOptions = struct {
    width: u16 = 80,
    height: u16 = 24,
    color_system: ColorSystem = .truecolor,
    force_terminal: bool = false,
    no_color: bool = false,
    tab_size: u8 = 8,
    legacy_windows: bool = false,
};

pub const Console = struct {
    options: ConsoleOptions,
    writer: std.fs.File.Writer,
    is_tty: bool,
    current_style: Style,
    allocator: std.mem.Allocator,
    capture_buffer: ?std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) Console {
        const info = terminal.detect();
        return initWithOptions(allocator, .{
            .width = info.width,
            .height = info.height,
            .color_system = info.color_system,
        });
    }
    
    pub fn initWithOptions(allocator: std.mem.Allocator, options: ConsoleOptions) Console {
        return .{
            .options = options,
            .writer = std.io.getStdOut().writer(),
            .is_tty = std.io.getStdOut().isTty(),
            .current_style = Style.empty,
            .allocator = allocator,
            .capture_buffer = null,
        };
    }
    
    pub fn width(self: Console) u16 {
        return self.options.width;
    }
    
    pub fn height(self: Console) u16 {
        return self.options.height;
    }
    
    /// Print with markup parsing
    pub fn print(self: *Console, text: []const u8) !void {
        const txt = try Text.fromMarkup(self.allocator, text);
        defer @constCast(&txt).deinit();
        try self.printText(txt);
        try self.writeLine();
    }
    
    /// Print without markup parsing
    pub fn printPlain(self: *Console, text: []const u8) !void {
        try self.writeAll(text);
        try self.writeLine();
    }
    
    /// Print pre-styled text
    pub fn printStyled(self: *Console, text: []const u8, style: Style) !void {
        try self.setStyle(style);
        try self.writeAll(text);
        try self.resetStyle();
        try self.writeLine();
    }
    
    /// Print a Text object
    pub fn printText(self: *Console, text: Text) !void {
        const segments = try text.render(self.allocator);
        defer self.allocator.free(segments);
        
        for (segments) |seg| {
            try self.printSegment(seg);
        }
    }
    
    /// Print any Renderable
    pub fn printRenderable(self: *Console, renderable: anytype) !void {
        const segments = try renderable.render(self.width(), self.allocator);
        defer self.allocator.free(segments);
        
        for (segments) |seg| {
            try self.printSegment(seg);
        }
        try self.writeLine();
    }
    
    fn printSegment(self: *Console, segment: Segment) !void {
        if (segment.style) |style| {
            try self.setStyle(style);
        }
        try self.writeAll(segment.text);
        if (segment.style != null) {
            try self.resetStyle();
        }
    }
    
    fn setStyle(self: *Console, style: Style) !void {
        if (self.options.no_color) return;
        try style.renderAnsi(self.options.color_system, self.getWriter());
        self.current_style = style;
    }
    
    fn resetStyle(self: *Console) !void {
        if (self.options.no_color) return;
        try self.writeAll("\x1b[0m");
        self.current_style = Style.empty;
    }
    
    fn writeAll(self: *Console, bytes: []const u8) !void {
        if (self.capture_buffer) |*buf| {
            try buf.appendSlice(bytes);
        } else {
            try self.writer.writeAll(bytes);
        }
    }
    
    fn writeLine(self: *Console) !void {
        try self.writeAll("\n");
    }
    
    fn getWriter(self: *Console) std.fs.File.Writer {
        return self.writer;
    }
    
    // === Horizontal Rule ===
    
    pub fn rule(self: *Console, title: ?[]const u8) !void {
        const Rule = @import("renderables/rule.zig").Rule;
        var r = Rule.init();
        if (title) |t| {
            r = r.withTitle(t);
        }
        try self.printRenderable(r);
    }
    
    // === Capture / Export ===
    
    pub fn beginCapture(self: *Console) void {
        self.capture_buffer = std.ArrayList(u8).init(self.allocator);
    }
    
    pub fn endCapture(self: *Console) ?[]const u8 {
        if (self.capture_buffer) |*buf| {
            const result = buf.toOwnedSlice() catch null;
            self.capture_buffer = null;
            return result;
        }
        return null;
    }
    
    pub fn exportHtml(self: *Console, clear: bool) ![]const u8 {
        // Convert captured ANSI to HTML
        // ... implementation
        _ = clear;
        return "<html>...</html>";
    }
    
    pub fn exportSvg(self: *Console, clear: bool) ![]const u8 {
        // Convert captured ANSI to SVG
        // ... implementation
        _ = clear;
        return "<svg>...</svg>";
    }
};
```

---

## Phase 4: Renderables (Weeks 4-6)

### 4.1 Renderable Interface

```zig
// src/renderable.zig
const std = @import("std");
const Segment = @import("segment.zig").Segment;
const Console = @import("console.zig").Console;
const ConsoleOptions = @import("console.zig").ConsoleOptions;

pub const Measurement = struct {
    minimum: usize,
    maximum: usize,
    
    pub fn exact(width: usize) Measurement {
        return .{ .minimum = width, .maximum = width };
    }
    
    pub fn range(min: usize, max: usize) Measurement {
        return .{ .minimum = min, .maximum = max };
    }
};

/// Interface for renderable objects
pub fn Renderable(comptime T: type) type {
    return struct {
        pub fn render(self: T, width: usize, allocator: std.mem.Allocator) ![]Segment {
            return self.renderImpl(width, allocator);
        }
        
        pub fn measure(self: T, console: *Console, options: ConsoleOptions) Measurement {
            if (@hasDecl(T, "measureImpl")) {
                return self.measureImpl(console, options);
            }
            return Measurement.range(1, options.width);
        }
    };
}
```

### 4.2 Panel (`renderables/panel.zig`)

```zig
// src/renderables/panel.zig
const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Style = @import("../style.zig").Style;
const Text = @import("../text.zig").Text;
const box = @import("../box.zig");
const cells = @import("../cells.zig");

pub const Panel = struct {
    content: union(enum) {
        text: Text,
        renderable: *anyopaque,
    },
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    box_style: box.BoxStyle = box.BoxStyle.rounded,
    style: Style = Style.empty,
    border_style: Style = Style.empty,
    title_style: Style = Style.empty,
    width: ?usize = null,
    padding: struct { top: u8, right: u8, bottom: u8, left: u8 } = .{ .top = 0, .right = 1, .bottom = 0, .left = 1 },
    expand: bool = true,
    allocator: std.mem.Allocator,
    
    pub fn fromText(allocator: std.mem.Allocator, text: []const u8) Panel {
        return .{
            .content = .{ .text = Text.fromPlain(allocator, text) },
            .allocator = allocator,
        };
    }
    
    pub fn withTitle(self: Panel, title: []const u8) Panel {
        var p = self;
        p.title = title;
        return p;
    }
    
    pub fn withSubtitle(self: Panel, subtitle: []const u8) Panel {
        var p = self;
        p.subtitle = subtitle;
        return p;
    }
    
    pub fn withWidth(self: Panel, w: usize) Panel {
        var p = self;
        p.width = w;
        return p;
    }
    
    pub fn rounded(self: Panel) Panel {
        var p = self;
        p.box_style = box.BoxStyle.rounded;
        return p;
    }
    
    pub fn square(self: Panel) Panel {
        var p = self;
        p.box_style = box.BoxStyle.square;
        return p;
    }
    
    pub fn heavy(self: Panel) Panel {
        var p = self;
        p.box_style = box.BoxStyle.heavy;
        return p;
    }
    
    pub fn double(self: Panel) Panel {
        var p = self;
        p.box_style = box.BoxStyle.double;
        return p;
    }
    
    pub fn ascii(self: Panel) Panel {
        var p = self;
        p.box_style = box.BoxStyle.ascii;
        return p;
    }
    
    pub fn render(self: Panel, max_width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments = std.ArrayList(Segment).init(allocator);
        const b = self.box_style;
        
        const inner_width = (self.width orelse max_width) - 2;
        const content_width = inner_width - self.padding.left - self.padding.right;
        
        // Top border with optional title
        try self.renderTopBorder(&segments, inner_width, b);
        
        // Padding top
        var i: u8 = 0;
        while (i < self.padding.top) : (i += 1) {
            try self.renderEmptyLine(&segments, inner_width, b);
        }
        
        // Content
        const content_segments = switch (self.content) {
            .text => |txt| try txt.render(allocator),
            .renderable => &[_]Segment{},  // TODO
        };
        
        for (content_segments) |seg| {
            try segments.append(Segment.styled(b.left, self.border_style));
            try self.renderPadding(&segments, self.padding.left);
            try segments.append(seg);
            // Pad to width
            const seg_width = seg.cellLength();
            if (seg_width < content_width) {
                try self.renderPadding(&segments, content_width - seg_width);
            }
            try self.renderPadding(&segments, self.padding.right);
            try segments.append(Segment.styled(b.right, self.border_style));
            try segments.append(Segment.line());
        }
        
        // Padding bottom
        i = 0;
        while (i < self.padding.bottom) : (i += 1) {
            try self.renderEmptyLine(&segments, inner_width, b);
        }
        
        // Bottom border with optional subtitle
        try self.renderBottomBorder(&segments, inner_width, b);
        
        return segments.toOwnedSlice();
    }
    
    fn renderTopBorder(self: Panel, segments: *std.ArrayList(Segment), width: usize, b: box.BoxStyle) !void {
        try segments.append(Segment.styled(b.top_left, self.border_style));
        
        if (self.title) |title| {
            const title_len = cells.cellLen(title);
            const padding = (width - title_len - 2) / 2;
            
            try self.renderHorizontal(segments, padding, b);
            try segments.append(Segment.plain(" "));
            try segments.append(Segment.styled(title, self.title_style));
            try segments.append(Segment.plain(" "));
            try self.renderHorizontal(segments, width - title_len - 2 - padding, b);
        } else {
            try self.renderHorizontal(segments, width, b);
        }
        
        try segments.append(Segment.styled(b.top_right, self.border_style));
        try segments.append(Segment.line());
    }
    
    fn renderBottomBorder(self: Panel, segments: *std.ArrayList(Segment), width: usize, b: box.BoxStyle) !void {
        try segments.append(Segment.styled(b.bottom_left, self.border_style));
        
        if (self.subtitle) |subtitle| {
            const subtitle_len = cells.cellLen(subtitle);
            const padding = (width - subtitle_len - 2) / 2;
            
            try self.renderHorizontal(segments, padding, b);
            try segments.append(Segment.plain(" "));
            try segments.append(Segment.styled(subtitle, self.title_style));
            try segments.append(Segment.plain(" "));
            try self.renderHorizontal(segments, width - subtitle_len - 2 - padding, b);
        } else {
            try self.renderHorizontal(segments, width, b);
        }
        
        try segments.append(Segment.styled(b.bottom_right, self.border_style));
        try segments.append(Segment.line());
    }
    
    fn renderHorizontal(self: Panel, segments: *std.ArrayList(Segment), count: usize, b: box.BoxStyle) !void {
        _ = self;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try segments.append(Segment.plain(b.horizontal));
        }
    }
    
    fn renderEmptyLine(self: Panel, segments: *std.ArrayList(Segment), width: usize, b: box.BoxStyle) !void {
        try segments.append(Segment.styled(b.left, self.border_style));
        try self.renderPadding(segments, width);
        try segments.append(Segment.styled(b.right, self.border_style));
        try segments.append(Segment.line());
    }
    
    fn renderPadding(self: Panel, segments: *std.ArrayList(Segment), count: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try segments.append(Segment.plain(" "));
        }
    }
};
```

### 4.3 Box Drawing (`box.zig`)

```zig
// src/box.zig

pub const BoxStyle = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
    left: []const u8,
    right: []const u8,
    
    // Common box styles
    pub const rounded = BoxStyle{
        .top_left = "╭",
        .top_right = "╮",
        .bottom_left = "╰",
        .bottom_right = "╯",
        .horizontal = "─",
        .vertical = "│",
        .left = "│",
        .right = "│",
    };
    
    pub const square = BoxStyle{
        .top_left = "┌",
        .top_right = "┐",
        .bottom_left = "└",
        .bottom_right = "┘",
        .horizontal = "─",
        .vertical = "│",
        .left = "│",
        .right = "│",
    };
    
    pub const heavy = BoxStyle{
        .top_left = "┏",
        .top_right = "┓",
        .bottom_left = "┗",
        .bottom_right = "┛",
        .horizontal = "━",
        .vertical = "┃",
        .left = "┃",
        .right = "┃",
    };
    
    pub const double = BoxStyle{
        .top_left = "╔",
        .top_right = "╗",
        .bottom_left = "╚",
        .bottom_right = "╝",
        .horizontal = "═",
        .vertical = "║",
        .left = "║",
        .right = "║",
    };
    
    pub const ascii = BoxStyle{
        .top_left = "+",
        .top_right = "+",
        .bottom_left = "+",
        .bottom_right = "+",
        .horizontal = "-",
        .vertical = "|",
        .left = "|",
        .right = "|",
    };
};
```

### 4.4 Table (`renderables/table.zig`)

```zig
// src/renderables/table.zig
const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Style = @import("../style.zig").Style;
const cells = @import("../cells.zig");
const box = @import("../box.zig");

pub const JustifyMethod = enum {
    left,
    center,
    right,
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
};

pub const Table = struct {
    columns: std.ArrayList(Column),
    rows: std.ArrayList([][]const u8),
    title: ?[]const u8 = null,
    title_style: Style = Style.empty,
    header_style: Style = Style.empty,
    border_style: Style = Style.empty,
    row_styles: ?[]Style = null,
    box_style: box.BoxStyle = box.BoxStyle.square,
    show_header: bool = true,
    show_edge: bool = true,
    show_lines: bool = false,
    padding: struct { left: u8, right: u8 } = .{ .left = 1, .right = 1 },
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .columns = std.ArrayList(Column).init(allocator),
            .rows = std.ArrayList([][]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn withTitle(self: *Table, title: []const u8) *Table {
        self.title = title;
        return self;
    }
    
    pub fn withColumn(self: *Table, col: Column) *Table {
        self.columns.append(col) catch {};
        return self;
    }
    
    pub fn addRow(self: *Table, row: [][]const u8) !void {
        try self.rows.append(row);
    }
    
    pub fn addRowCells(self: *Table, row: anytype) !void {
        var cells_arr = try self.allocator.alloc([]const u8, row.len);
        inline for (row, 0..) |cell, i| {
            cells_arr[i] = cell;
        }
        try self.rows.append(cells_arr);
    }
    
    pub fn render(self: Table, max_width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments = std.ArrayList(Segment).init(allocator);
        
        // Calculate column widths
        const col_widths = try self.calculateColumnWidths(max_width, allocator);
        defer allocator.free(col_widths);
        
        const b = self.box_style;
        
        // Title
        if (self.title) |title| {
            try self.renderTitle(&segments, title, col_widths, b);
        }
        
        // Top border
        if (self.show_edge) {
            try self.renderHorizontalBorder(&segments, col_widths, b.top_left, b.horizontal, b.top_right, "┬");
        }
        
        // Header
        if (self.show_header) {
            try self.renderHeaderRow(&segments, col_widths, b);
            try self.renderHorizontalBorder(&segments, col_widths, "├", "─", "┤", "┼");
        }
        
        // Data rows
        for (self.rows.items) |row| {
            try self.renderDataRow(&segments, row, col_widths, b);
            if (self.show_lines) {
                try self.renderHorizontalBorder(&segments, col_widths, "├", "─", "┤", "┼");
            }
        }
        
        // Bottom border
        if (self.show_edge) {
            try self.renderHorizontalBorder(&segments, col_widths, b.bottom_left, b.horizontal, b.bottom_right, "┴");
        }
        
        return segments.toOwnedSlice();
    }
    
    fn calculateColumnWidths(self: Table, max_width: usize, allocator: std.mem.Allocator) ![]usize {
        var widths = try allocator.alloc(usize, self.columns.items.len);
        
        // Start with header widths
        for (self.columns.items, 0..) |col, i| {
            widths[i] = cells.cellLen(col.header);
        }
        
        // Check data widths
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
        
        // Apply column constraints
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
        
        // Add padding
        for (widths) |*w| {
            w.* += self.padding.left + self.padding.right;
        }
        
        _ = max_width;  // TODO: shrink to fit
        
        return widths;
    }
    
    fn renderHorizontalBorder(
        self: Table,
        segments: *std.ArrayList(Segment),
        widths: []usize,
        left: []const u8,
        horizontal: []const u8,
        right: []const u8,
        cross: []const u8,
    ) !void {
        try segments.append(Segment.styled(left, self.border_style));
        
        for (widths, 0..) |w, i| {
            var j: usize = 0;
            while (j < w) : (j += 1) {
                try segments.append(Segment.styled(horizontal, self.border_style));
            }
            if (i < widths.len - 1) {
                try segments.append(Segment.styled(cross, self.border_style));
            }
        }
        
        try segments.append(Segment.styled(right, self.border_style));
        try segments.append(Segment.line());
    }
    
    fn renderHeaderRow(self: Table, segments: *std.ArrayList(Segment), widths: []usize, b: box.BoxStyle) !void {
        try segments.append(Segment.styled(b.left, self.border_style));
        
        for (self.columns.items, 0..) |col, i| {
            try self.renderCell(segments, col.header, widths[i], col.justify, self.header_style.combine(col.header_style));
            if (i < self.columns.items.len - 1) {
                try segments.append(Segment.styled(b.vertical, self.border_style));
            }
        }
        
        try segments.append(Segment.styled(b.right, self.border_style));
        try segments.append(Segment.line());
    }
    
    fn renderDataRow(self: Table, segments: *std.ArrayList(Segment), row: [][]const u8, widths: []usize, b: box.BoxStyle) !void {
        try segments.append(Segment.styled(b.left, self.border_style));
        
        for (self.columns.items, 0..) |col, i| {
            const cell = if (i < row.len) row[i] else "";
            try self.renderCell(segments, cell, widths[i], col.justify, col.style);
            if (i < self.columns.items.len - 1) {
                try segments.append(Segment.styled(b.vertical, self.border_style));
            }
        }
        
        try segments.append(Segment.styled(b.right, self.border_style));
        try segments.append(Segment.line());
    }
    
    fn renderCell(self: Table, segments: *std.ArrayList(Segment), text: []const u8, width: usize, justify: JustifyMethod, style: Style) !void {
        const text_width = cells.cellLen(text);
        const content_width = width - self.padding.left - self.padding.right;
        const padding_total = if (content_width > text_width) content_width - text_width else 0;
        
        const left_pad: usize = switch (justify) {
            .left => self.padding.left,
            .right => self.padding.left + padding_total,
            .center => self.padding.left + padding_total / 2,
        };
        const right_pad = width - left_pad - text_width;
        
        try self.renderSpaces(segments, left_pad);
        try segments.append(Segment.styled(text, style));
        try self.renderSpaces(segments, right_pad);
    }
    
    fn renderSpaces(self: Table, segments: *std.ArrayList(Segment), count: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try segments.append(Segment.plain(" "));
        }
    }
    
    fn renderTitle(self: Table, segments: *std.ArrayList(Segment), title: []const u8, widths: []usize, b: box.BoxStyle) !void {
        _ = b;
        const total_width = blk: {
            var sum: usize = 0;
            for (widths) |w| sum += w;
            sum += widths.len + 1;  // borders
            break :blk sum;
        };
        
        const title_width = cells.cellLen(title);
        const padding = (total_width - title_width - 2) / 2;
        
        try segments.append(Segment.styled("┌", self.border_style));
        try self.renderSpaces(segments, padding);
        try segments.append(Segment.styled(title, self.title_style));
        try self.renderSpaces(segments, total_width - title_width - 2 - padding);
        try segments.append(Segment.styled("┐", self.border_style));
        try segments.append(Segment.line());
    }
};
```

### 4.5 Rule (`renderables/rule.zig`)

```zig
// src/renderables/rule.zig
const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Style = @import("../style.zig").Style;
const cells = @import("../cells.zig");

pub const Alignment = enum { left, center, right };

pub const Rule = struct {
    title: ?[]const u8 = null,
    characters: []const u8 = "─",
    style: Style = Style.empty,
    align: Alignment = .center,
    end: []const u8 = "",
    
    pub fn init() Rule {
        return .{};
    }
    
    pub fn withTitle(self: Rule, title: []const u8) Rule {
        var r = self;
        r.title = title;
        return r;
    }
    
    pub fn withStyle(self: Rule, style: Style) Rule {
        var r = self;
        r.style = style;
        return r;
    }
    
    pub fn alignLeft(self: Rule) Rule {
        var r = self;
        r.align = .left;
        return r;
    }
    
    pub fn alignRight(self: Rule) Rule {
        var r = self;
        r.align = .right;
        return r;
    }
    
    pub fn render(self: Rule, width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments = std.ArrayList(Segment).init(allocator);
        
        if (self.title) |title| {
            const title_len = cells.cellLen(title);
            const rule_len = width - title_len - 2;  // 2 spaces around title
            
            const left_len: usize = switch (self.align) {
                .left => 1,
                .center => rule_len / 2,
                .right => rule_len - 1,
            };
            const right_len = rule_len - left_len;
            
            try self.renderChars(&segments, left_len);
            try segments.append(Segment.plain(" "));
            try segments.append(Segment.styled(title, self.style));
            try segments.append(Segment.plain(" "));
            try self.renderChars(&segments, right_len);
        } else {
            try self.renderChars(&segments, width);
        }
        
        if (self.end.len > 0) {
            try segments.append(Segment.plain(self.end));
        }
        
        return segments.toOwnedSlice();
    }
    
    fn renderChars(self: Rule, segments: *std.ArrayList(Segment), count: usize) !void {
        const char_len = cells.cellLen(self.characters);
        var remaining = count;
        
        while (remaining >= char_len) {
            try segments.append(Segment.styled(self.characters, self.style));
            remaining -= char_len;
        }
    }
};
```

### 4.6 Progress Bar (`renderables/progress.zig`)

```zig
// src/renderables/progress.zig
const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Style = @import("../style.zig").Style;
const Color = @import("../color.zig").Color;

pub const ProgressBar = struct {
    completed: usize = 0,
    total: usize = 100,
    width: usize = 40,
    complete_style: Style = Style.empty.foreground(Color.green),
    finished_style: Style = Style.empty.foreground(Color.bright_green),
    incomplete_style: Style = Style.empty.foreground(Color.white).dim(),
    pulse: bool = false,
    
    pub fn init() ProgressBar {
        return .{};
    }
    
    pub fn withCompleted(self: ProgressBar, c: usize) ProgressBar {
        var p = self;
        p.completed = c;
        return p;
    }
    
    pub fn withTotal(self: ProgressBar, t: usize) ProgressBar {
        var p = self;
        p.total = t;
        return p;
    }
    
    pub fn withWidth(self: ProgressBar, w: usize) ProgressBar {
        var p = self;
        p.width = w;
        return p;
    }
    
    pub fn render(self: ProgressBar, max_width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments = std.ArrayList(Segment).init(allocator);
        
        const bar_width = @min(self.width, max_width);
        const ratio: f64 = @as(f64, @floatFromInt(self.completed)) / @as(f64, @floatFromInt(self.total));
        const complete_width: usize = @intFromFloat(ratio * @as(f64, @floatFromInt(bar_width)));
        const incomplete_width = bar_width - complete_width;
        
        const style = if (self.completed >= self.total) self.finished_style else self.complete_style;
        
        // Complete portion
        var i: usize = 0;
        while (i < complete_width) : (i += 1) {
            try segments.append(Segment.styled("━", style));
        }
        
        // Incomplete portion
        i = 0;
        while (i < incomplete_width) : (i += 1) {
            try segments.append(Segment.styled("━", self.incomplete_style));
        }
        
        return segments.toOwnedSlice();
    }
    
    pub fn percentage(self: ProgressBar) f64 {
        return @as(f64, @floatFromInt(self.completed)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }
};

pub const Spinner = struct {
    frames: []const []const u8 = &[_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    current_frame: usize = 0,
    style: Style = Style.empty,
    
    pub fn init() Spinner {
        return .{};
    }
    
    pub fn advance(self: *Spinner) void {
        self.current_frame = (self.current_frame + 1) % self.frames.len;
    }
    
    pub fn render(self: Spinner, allocator: std.mem.Allocator) ![]Segment {
        var segments = try allocator.alloc(Segment, 1);
        segments[0] = Segment.styled(self.frames[self.current_frame], self.style);
        return segments;
    }
};
```

### 4.7 Tree (`renderables/tree.zig`)

```zig
// src/renderables/tree.zig
const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Style = @import("../style.zig").Style;

pub const TreeGuide = struct {
    vertical: []const u8 = "│",
    horizontal: []const u8 = "──",
    corner: []const u8 = "└",
    tee: []const u8 = "├",
    space: []const u8 = "   ",
};

pub const TreeNode = struct {
    label: []const u8,
    children: std.ArrayList(TreeNode),
    style: Style = Style.empty,
    guide_style: Style = Style.empty,
    expanded: bool = true,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, label: []const u8) TreeNode {
        return .{
            .label = label,
            .children = std.ArrayList(TreeNode).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn addChild(self: *TreeNode, child: TreeNode) !void {
        try self.children.append(child);
    }
    
    pub fn addChildLabel(self: *TreeNode, label: []const u8) !*TreeNode {
        var child = TreeNode.init(self.allocator, label);
        try self.children.append(child);
        return &self.children.items[self.children.items.len - 1];
    }
};

pub const Tree = struct {
    root: TreeNode,
    guide: TreeGuide = .{},
    hide_root: bool = false,
    
    pub fn init(root: TreeNode) Tree {
        return .{ .root = root };
    }
    
    pub fn render(self: Tree, width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments = std.ArrayList(Segment).init(allocator);
        _ = width;
        
        if (!self.hide_root) {
            try segments.append(Segment.styled(self.root.label, self.root.style));
            try segments.append(Segment.line());
        }
        
        try self.renderChildren(&segments, &self.root, "", true);
        
        return segments.toOwnedSlice();
    }
    
    fn renderChildren(self: Tree, segments: *std.ArrayList(Segment), node: *const TreeNode, prefix: []const u8, is_root: bool) !void {
        _ = is_root;
        
        for (node.children.items, 0..) |*child, i| {
            const is_last = (i == node.children.items.len - 1);
            
            // Guide character
            try segments.append(Segment.plain(prefix));
            if (is_last) {
                try segments.append(Segment.styled(self.guide.corner, node.guide_style));
            } else {
                try segments.append(Segment.styled(self.guide.tee, node.guide_style));
            }
            try segments.append(Segment.styled(self.guide.horizontal, node.guide_style));
            try segments.append(Segment.plain(" "));
            
            // Label
            try segments.append(Segment.styled(child.label, child.style));
            try segments.append(Segment.line());
            
            // Recurse
            if (child.children.items.len > 0 and child.expanded) {
                var new_prefix = std.ArrayList(u8).init(segments.allocator);
                defer new_prefix.deinit();
                try new_prefix.appendSlice(prefix);
                if (is_last) {
                    try new_prefix.appendSlice(self.guide.space);
                } else {
                    try new_prefix.appendSlice(self.guide.vertical);
                    try new_prefix.appendSlice("  ");
                }
                try self.renderChildren(segments, child, new_prefix.items, false);
            }
        }
    }
};
```

---

## Phase 5: Optional Features (Weeks 6-8)

### 5.1 Syntax Highlighting

Would require porting or wrapping a syntax highlighter. Options:
- Wrap Tree-sitter via C ABI
- Port a simple regex-based highlighter
- Use Zig's comptime for grammar definitions

### 5.2 Markdown Rendering

Use a Zig markdown parser like `zig-md` or port a simple CommonMark parser.

### 5.3 JSON Pretty-Printing

```zig
// src/renderables/json.zig
const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Style = @import("../style.zig").Style;
const Color = @import("../color.zig").Color;

pub const JsonTheme = struct {
    key_style: Style = Style.empty.foreground(Color.cyan),
    string_style: Style = Style.empty.foreground(Color.green),
    number_style: Style = Style.empty.foreground(Color.yellow),
    bool_style: Style = Style.empty.foreground(Color.magenta),
    null_style: Style = Style.empty.foreground(Color.bright_black).italic(),
    bracket_style: Style = Style.empty,
};

pub const Json = struct {
    data: std.json.Value,
    theme: JsonTheme = .{},
    indent: usize = 2,
    
    pub fn parse(allocator: std.mem.Allocator, json_text: []const u8) !Json {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        return .{ .data = parsed.value };
    }
    
    pub fn render(self: Json, width: usize, allocator: std.mem.Allocator) ![]Segment {
        var segments = std.ArrayList(Segment).init(allocator);
        _ = width;
        
        try self.renderValue(&segments, self.data, 0);
        
        return segments.toOwnedSlice();
    }
    
    fn renderValue(self: Json, segments: *std.ArrayList(Segment), value: std.json.Value, depth: usize) !void {
        switch (value) {
            .null => try segments.append(Segment.styled("null", self.theme.null_style)),
            .bool => |b| try segments.append(Segment.styled(if (b) "true" else "false", self.theme.bool_style)),
            .integer => |n| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try segments.append(Segment.styled(str, self.theme.number_style));
            },
            .float => |f| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "?";
                try segments.append(Segment.styled(str, self.theme.number_style));
            },
            .string => |s| {
                try segments.append(Segment.styled("\"", self.theme.string_style));
                try segments.append(Segment.styled(s, self.theme.string_style));
                try segments.append(Segment.styled("\"", self.theme.string_style));
            },
            .array => |arr| {
                try segments.append(Segment.styled("[", self.theme.bracket_style));
                if (arr.items.len > 0) {
                    try segments.append(Segment.line());
                    for (arr.items, 0..) |item, i| {
                        try self.renderIndent(segments, depth + 1);
                        try self.renderValue(segments, item, depth + 1);
                        if (i < arr.items.len - 1) {
                            try segments.append(Segment.plain(","));
                        }
                        try segments.append(Segment.line());
                    }
                    try self.renderIndent(segments, depth);
                }
                try segments.append(Segment.styled("]", self.theme.bracket_style));
            },
            .object => |obj| {
                try segments.append(Segment.styled("{", self.theme.bracket_style));
                if (obj.count() > 0) {
                    try segments.append(Segment.line());
                    var iter = obj.iterator();
                    var i: usize = 0;
                    while (iter.next()) |entry| {
                        try self.renderIndent(segments, depth + 1);
                        try segments.append(Segment.styled("\"", self.theme.key_style));
                        try segments.append(Segment.styled(entry.key_ptr.*, self.theme.key_style));
                        try segments.append(Segment.styled("\"", self.theme.key_style));
                        try segments.append(Segment.plain(": "));
                        try self.renderValue(segments, entry.value_ptr.*, depth + 1);
                        if (i < obj.count() - 1) {
                            try segments.append(Segment.plain(","));
                        }
                        try segments.append(Segment.line());
                        i += 1;
                    }
                    try self.renderIndent(segments, depth);
                }
                try segments.append(Segment.styled("}", self.theme.bracket_style));
            },
            else => {},
        }
    }
    
    fn renderIndent(self: Json, segments: *std.ArrayList(Segment), depth: usize) !void {
        var i: usize = 0;
        while (i < depth * self.indent) : (i += 1) {
            try segments.append(Segment.plain(" "));
        }
    }
};
```

---

## Phase 6: Project Structure

```
rich_zig/
├── build.zig
├── build.zig.zon
├── README.md
├── src/
│   ├── lib.zig           # Main library entry
│   ├── prelude.zig       # Convenience re-exports
│   ├── color.zig
│   ├── style.zig
│   ├── segment.zig
│   ├── text.zig
│   ├── cells.zig
│   ├── box.zig
│   ├── terminal.zig
│   ├── console.zig
│   ├── measure.zig
│   ├── markup.zig
│   └── renderables/
│       ├── mod.zig
│       ├── align.zig
│       ├── columns.zig
│       ├── padding.zig
│       ├── panel.zig
│       ├── progress.zig
│       ├── rule.zig
│       ├── table.zig
│       ├── tree.zig
│       ├── live.zig
│       ├── layout.zig
│       ├── syntax.zig     # Optional
│       ├── markdown.zig   # Optional
│       └── json.zig       # Optional
├── examples/
│   ├── hello.zig
│   ├── table_demo.zig
│   ├── progress_demo.zig
│   └── showcase.zig
└── tests/
    ├── color_test.zig
    ├── style_test.zig
    └── ...
```

---

## Usage Examples

### Basic Usage

```zig
const std = @import("std");
const rich = @import("rich_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var console = rich.Console.init(allocator);
    
    // Styled text with markup
    try console.print("[bold green]Success![/] Operation completed.");
    try console.print("[red on white]Error:[/] [italic]File not found[/]");
    
    // Horizontal rule
    try console.rule("Configuration");
}
```

### Tables

```zig
const rich = @import("rich_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var console = rich.Console.init(allocator);
    
    var table = rich.Table.init(allocator)
        .withTitle("Server Status")
        .withColumn(rich.Column.init("Service"))
        .withColumn(rich.Column.init("Status").withJustify(.center))
        .withColumn(rich.Column.init("Uptime").withJustify(.right));
    
    try table.addRowCells(.{ "nginx", "✓ Running", "14d 3h" });
    try table.addRowCells(.{ "postgres", "✓ Running", "14d 3h" });
    try table.addRowCells(.{ "redis", "✗ Stopped", "0s" });
    
    try console.printRenderable(table);
}
```

### Panels

```zig
const rich = @import("rich_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var console = rich.Console.init(allocator);
    
    const panel = rich.Panel.fromText(allocator, "Welcome to ReclaimerOS!")
        .withTitle("System Message")
        .withSubtitle("v0.1.0")
        .withWidth(50)
        .rounded();
    
    try console.printRenderable(panel);
}
```

### Progress Bars

```zig
const std = @import("std");
const rich = @import("rich_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var console = rich.Console.init(allocator);
    
    var i: usize = 0;
    while (i <= 100) : (i += 5) {
        const bar = rich.ProgressBar.init()
            .withCompleted(i)
            .withTotal(100)
            .withWidth(40);
        
        // Clear line and redraw
        try console.writer.writeAll("\r");
        try console.print("[bold]Installing:[/] ");
        try console.printRenderable(bar);
        try console.print(std.fmt.allocPrint(allocator, " {d}%", .{i}));
        
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    try console.writeLine();
}
```

### Trees

```zig
const rich = @import("rich_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var console = rich.Console.init(allocator);
    
    var root = rich.TreeNode.init(allocator, "📁 project");
    
    var src = try root.addChildLabel("📁 src");
    _ = try src.addChildLabel("📄 main.zig");
    _ = try src.addChildLabel("📄 lib.zig");
    
    var tests = try root.addChildLabel("📁 tests");
    _ = try tests.addChildLabel("📄 unit_tests.zig");
    
    _ = try root.addChildLabel("📄 build.zig");
    _ = try root.addChildLabel("📄 README.md");
    
    const tree = rich.Tree.init(root);
    try console.printRenderable(tree);
}
```

### Integration with ReclaimerOS

For your container-native OS, this could be useful for:

```zig
// Boot splash
const rich = @import("rich_zig");

pub fn showBootSplash(allocator: std.mem.Allocator) !void {
    var console = rich.Console.init(allocator);
    
    const banner = rich.Panel.fromText(allocator,
        \\  ____           _       _                      ___  ____  
        \\ |  _ \ ___  ___| | __ _(_)_ __ ___   ___ _ __ / _ \/ ___| 
        \\ | |_) / _ \/ __| |/ _` | | '_ ` _ \ / _ \ '__| | | \___ \ 
        \\ |  _ <  __/ (__| | (_| | | | | | | |  __/ |  | |_| |___) |
        \\ |_| \_\___|\___|_|\__,_|_|_| |_| |_|\___|_|   \___/|____/ 
    ).withTitle("Container-Native OS").heavy();
    
    try console.printRenderable(banner);
    
    // Boot progress
    const stages = [_][]const u8{
        "Initializing CEVA...",
        "Loading container runtime...",
        "Starting system services...",
        "Ready!",
    };
    
    for (stages, 0..) |stage, i| {
        const progress = rich.ProgressBar.init()
            .withCompleted((i + 1) * 25)
            .withTotal(100);
        
        try console.print(stage);
        try console.printRenderable(progress);
        std.time.sleep(500 * std.time.ns_per_ms);
    }
}
```

---

## Timeline Summary

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| 1. Core Foundation | 2 weeks | Color, Style, Segment, Cells |
| 2. Markup & Text | 1 week | Markup parser, Text with spans |
| 3. Console | 1 week | Terminal detection, Console I/O |
| 4. Renderables | 2 weeks | Panel, Table, Rule, Progress, Tree |
| 5. Optional | 2 weeks | Syntax, Markdown, JSON, Live |
| 6. Polish | 1 week | Docs, examples, tests |

**Total: ~8-9 weeks** for a full-featured port.

---

## Key Zig Advantages

1. **Comptime markup parsing** - Could validate markup at compile time
2. **No hidden allocations** - Explicit allocator control
3. **Cross-compilation** - Easy targeting of ARM for ReclaimerOS
4. **C interop** - Could wrap Tree-sitter for syntax highlighting
5. **WebAssembly** - Same code could compile to WASM for browser demos

This would be a substantial but rewarding project that fits well with your systems programming focus and ReclaimerOS work.