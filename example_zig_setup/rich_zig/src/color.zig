const std = @import("std");

pub const ColorType = enum {
    default,
    standard, // 16 colors (0-15)
    eight_bit, // 256 colors (0-255)
    truecolor, // RGB 24-bit
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
        const clamped_t = @max(0.0, @min(1.0, t));
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(c1.r)) + (@as(f32, @floatFromInt(c2.r)) - @as(f32, @floatFromInt(c1.r))) * clamped_t),
            .g = @intFromFloat(@as(f32, @floatFromInt(c1.g)) + (@as(f32, @floatFromInt(c2.g)) - @as(f32, @floatFromInt(c1.g))) * clamped_t),
            .b = @intFromFloat(@as(f32, @floatFromInt(c1.b)) + (@as(f32, @floatFromInt(c2.b)) - @as(f32, @floatFromInt(c1.b))) * clamped_t),
        };
    }

    pub fn eql(self: ColorTriplet, other: ColorTriplet) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Color = struct {
    color_type: ColorType,
    number: ?u8 = null,
    triplet: ?ColorTriplet = null,

    // Default color (terminal default)
    pub const default: Color = .{ .color_type = .default };

    // Standard 16 colors (0-15)
    pub const black: Color = .{ .color_type = .standard, .number = 0 };
    pub const red: Color = .{ .color_type = .standard, .number = 1 };
    pub const green: Color = .{ .color_type = .standard, .number = 2 };
    pub const yellow: Color = .{ .color_type = .standard, .number = 3 };
    pub const blue: Color = .{ .color_type = .standard, .number = 4 };
    pub const magenta: Color = .{ .color_type = .standard, .number = 5 };
    pub const cyan: Color = .{ .color_type = .standard, .number = 6 };
    pub const white: Color = .{ .color_type = .standard, .number = 7 };

    // Bright variants (8-15)
    pub const bright_black: Color = .{ .color_type = .standard, .number = 8 };
    pub const bright_red: Color = .{ .color_type = .standard, .number = 9 };
    pub const bright_green: Color = .{ .color_type = .standard, .number = 10 };
    pub const bright_yellow: Color = .{ .color_type = .standard, .number = 11 };
    pub const bright_blue: Color = .{ .color_type = .standard, .number = 12 };
    pub const bright_magenta: Color = .{ .color_type = .standard, .number = 13 };
    pub const bright_cyan: Color = .{ .color_type = .standard, .number = 14 };
    pub const bright_white: Color = .{ .color_type = .standard, .number = 15 };

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{
            .color_type = .truecolor,
            .triplet = .{ .r = r, .g = g, .b = b },
        };
    }

    pub fn fromHex(hex_str: []const u8) !Color {
        const start: usize = if (hex_str.len > 0 and hex_str[0] == '#') 1 else 0;
        if (hex_str.len - start != 6) return error.InvalidHexColor;

        const r = std.fmt.parseInt(u8, hex_str[start..][0..2], 16) catch return error.InvalidHexColor;
        const g = std.fmt.parseInt(u8, hex_str[start..][2..4], 16) catch return error.InvalidHexColor;
        const b = std.fmt.parseInt(u8, hex_str[start..][4..6], 16) catch return error.InvalidHexColor;

        return fromRgb(r, g, b);
    }

    pub fn from256(number: u8) Color {
        return .{
            .color_type = .eight_bit,
            .number = number,
        };
    }

    pub fn downgrade(self: Color, target: ColorSystem) Color {
        return switch (self.color_type) {
            .default => self,
            .standard => self,
            .eight_bit => switch (target) {
                .standard => self.toStandard(),
                .eight_bit, .truecolor => self,
            },
            .truecolor => switch (target) {
                .standard => self.toStandard(),
                .eight_bit => self.to256(),
                .truecolor => self,
            },
        };
    }

    fn toStandard(self: Color) Color {
        const triplet = self.getTriplet() orelse return Color.white;

        var best_index: u8 = 0;
        var best_distance: i32 = std.math.maxInt(i32);

        for (standard_color_triplets, 0..) |std_color, i| {
            const dr: i32 = @as(i32, triplet.r) - @as(i32, std_color.r);
            const dg: i32 = @as(i32, triplet.g) - @as(i32, std_color.g);
            const db: i32 = @as(i32, triplet.b) - @as(i32, std_color.b);
            const distance = dr * dr + dg * dg + db * db;

            if (distance < best_distance) {
                best_distance = distance;
                best_index = @intCast(i);
            }
        }

        return .{ .color_type = .standard, .number = best_index };
    }

    fn to256(self: Color) Color {
        const triplet = self.triplet orelse return self;
        const number = rgbTo256(triplet.r, triplet.g, triplet.b);
        return Color.from256(number);
    }

    pub fn getTriplet(self: Color) ?ColorTriplet {
        if (self.triplet) |t| return t;

        // For 256 colors, convert back to RGB approximation
        if (self.color_type == .eight_bit) {
            if (self.number) |n| {
                return tripletFrom256(n);
            }
        }

        // For standard colors, return approximate RGB values
        if (self.color_type == .standard) {
            if (self.number) |n| {
                if (n < standard_color_triplets.len) {
                    return standard_color_triplets[n];
                }
            }
        }

        return null;
    }

    pub fn getAnsiCodes(self: Color, foreground: bool, writer: anytype) !void {
        const base: u8 = if (foreground) 30 else 40;

        switch (self.color_type) {
            .default => try writer.print("{d}", .{if (foreground) @as(u8, 39) else @as(u8, 49)}),
            .standard => {
                const num = self.number orelse return;
                if (num < 8) {
                    try writer.print("{d}", .{base + num});
                } else {
                    try writer.print("{d}", .{base + 60 + num - 8});
                }
            },
            .eight_bit => {
                const num = self.number orelse return;
                try writer.print("{d};5;{d}", .{ if (foreground) @as(u8, 38) else @as(u8, 48), num });
            },
            .truecolor => {
                const t = self.triplet orelse return;
                try writer.print("{d};2;{d};{d};{d}", .{
                    if (foreground) @as(u8, 38) else @as(u8, 48),
                    t.r,
                    t.g,
                    t.b,
                });
            },
        }
    }

    pub fn eql(self: Color, other: Color) bool {
        if (self.color_type != other.color_type) return false;
        if (self.number != other.number) return false;
        if (self.triplet == null and other.triplet == null) return true;
        if (self.triplet == null or other.triplet == null) return false;
        return self.triplet.?.eql(other.triplet.?);
    }

    pub fn paletteToRgb(n: u8) ColorTriplet {
        return tripletFrom256(n);
    }
};

pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Check for grayscale
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return @as(u8, @intFromFloat((@as(f32, @floatFromInt(r)) - 8.0) / 247.0 * 24.0)) + 232;
    }

    // Use 6x6x6 color cube (colors 16-231)
    const ri: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(r)) / 255.0 * 5.0));
    const gi: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(g)) / 255.0 * 5.0));
    const bi: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(b)) / 255.0 * 5.0));
    return 16 + 36 * ri + 6 * gi + bi;
}

// RGB values for the 16 standard terminal colors
const standard_color_triplets = [16]ColorTriplet{
    .{ .r = 0, .g = 0, .b = 0 }, // black
    .{ .r = 128, .g = 0, .b = 0 }, // red
    .{ .r = 0, .g = 128, .b = 0 }, // green
    .{ .r = 128, .g = 128, .b = 0 }, // yellow
    .{ .r = 0, .g = 0, .b = 128 }, // blue
    .{ .r = 128, .g = 0, .b = 128 }, // magenta
    .{ .r = 0, .g = 128, .b = 128 }, // cyan
    .{ .r = 192, .g = 192, .b = 192 }, // white
    .{ .r = 128, .g = 128, .b = 128 }, // bright_black
    .{ .r = 255, .g = 0, .b = 0 }, // bright_red
    .{ .r = 0, .g = 255, .b = 0 }, // bright_green
    .{ .r = 255, .g = 255, .b = 0 }, // bright_yellow
    .{ .r = 0, .g = 0, .b = 255 }, // bright_blue
    .{ .r = 255, .g = 0, .b = 255 }, // bright_magenta
    .{ .r = 0, .g = 255, .b = 255 }, // bright_cyan
    .{ .r = 255, .g = 255, .b = 255 }, // bright_white
};

pub fn tripletFrom256(n: u8) ColorTriplet {
    if (n < 16) {
        return standard_color_triplets[n];
    } else if (n < 232) {
        // 6x6x6 color cube
        const cube_index = n - 16;
        const ri = cube_index / 36;
        const gi = (cube_index % 36) / 6;
        const bi = cube_index % 6;
        return .{
            .r = if (ri > 0) @as(u8, @intCast(ri * 40 + 55)) else 0,
            .g = if (gi > 0) @as(u8, @intCast(gi * 40 + 55)) else 0,
            .b = if (bi > 0) @as(u8, @intCast(bi * 40 + 55)) else 0,
        };
    } else {
        // Grayscale (232-255)
        const gray = @as(u8, @intCast((n - 232) * 10 + 8));
        return .{ .r = gray, .g = gray, .b = gray };
    }
}

// Named color lookup table for parsing
pub const named_colors = std.StaticStringMap(Color).initComptime(.{
    .{ "default", Color.default },
    .{ "black", Color.black },
    .{ "red", Color.red },
    .{ "green", Color.green },
    .{ "yellow", Color.yellow },
    .{ "blue", Color.blue },
    .{ "magenta", Color.magenta },
    .{ "cyan", Color.cyan },
    .{ "white", Color.white },
    .{ "bright_black", Color.bright_black },
    .{ "bright_red", Color.bright_red },
    .{ "bright_green", Color.bright_green },
    .{ "bright_yellow", Color.bright_yellow },
    .{ "bright_blue", Color.bright_blue },
    .{ "bright_magenta", Color.bright_magenta },
    .{ "bright_cyan", Color.bright_cyan },
    .{ "bright_white", Color.bright_white },
    .{ "grey", Color.bright_black },
    .{ "gray", Color.bright_black },
});

// Tests
test "ColorTriplet.hex" {
    const triplet = ColorTriplet{ .r = 255, .g = 128, .b = 0 };
    try std.testing.expectEqualStrings("#ff8000", &triplet.hex());
}

test "ColorTriplet.blend" {
    const c1 = ColorTriplet{ .r = 0, .g = 0, .b = 0 };
    const c2 = ColorTriplet{ .r = 255, .g = 255, .b = 255 };

    const mid = ColorTriplet.blend(c1, c2, 0.5);
    try std.testing.expectEqual(@as(u8, 127), mid.r);
    try std.testing.expectEqual(@as(u8, 127), mid.g);
    try std.testing.expectEqual(@as(u8, 127), mid.b);

    const start = ColorTriplet.blend(c1, c2, 0.0);
    try std.testing.expectEqual(@as(u8, 0), start.r);

    const end = ColorTriplet.blend(c1, c2, 1.0);
    try std.testing.expectEqual(@as(u8, 255), end.r);
}

test "Color.fromHex valid" {
    const c1 = try Color.fromHex("#ff0000");
    try std.testing.expectEqual(ColorType.truecolor, c1.color_type);
    try std.testing.expectEqual(@as(u8, 255), c1.triplet.?.r);
    try std.testing.expectEqual(@as(u8, 0), c1.triplet.?.g);
    try std.testing.expectEqual(@as(u8, 0), c1.triplet.?.b);

    const c2 = try Color.fromHex("00ff00");
    try std.testing.expectEqual(@as(u8, 0), c2.triplet.?.r);
    try std.testing.expectEqual(@as(u8, 255), c2.triplet.?.g);

    const c3 = try Color.fromHex("#abcdef");
    try std.testing.expectEqual(@as(u8, 0xab), c3.triplet.?.r);
    try std.testing.expectEqual(@as(u8, 0xcd), c3.triplet.?.g);
    try std.testing.expectEqual(@as(u8, 0xef), c3.triplet.?.b);
}

test "Color.fromHex invalid" {
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("#ff00"));
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("ff"));
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("#gggggg"));
}

test "Color.downgrade truecolor to 256" {
    const truecolor = Color.fromRgb(255, 0, 0);
    const downgraded = truecolor.downgrade(.eight_bit);
    try std.testing.expectEqual(ColorType.eight_bit, downgraded.color_type);
    try std.testing.expect(downgraded.number != null);
}

test "Color.downgrade truecolor to standard" {
    const truecolor = Color.fromRgb(255, 0, 0);
    const downgraded = truecolor.downgrade(.standard);
    try std.testing.expectEqual(ColorType.standard, downgraded.color_type);
    // Should map to red (1) or bright_red (9)
    try std.testing.expect(downgraded.number.? == 9 or downgraded.number.? == 1);
}

test "Color.downgrade standard stays standard" {
    const standard = Color.red;
    const downgraded = standard.downgrade(.standard);
    try std.testing.expect(standard.eql(downgraded));
}

test "Color.getAnsiCodes" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    // Default foreground
    try Color.default.getAnsiCodes(true, writer);
    try std.testing.expectEqualStrings("39", stream.getWritten());

    stream.reset();

    // Standard red foreground
    try Color.red.getAnsiCodes(true, writer);
    try std.testing.expectEqualStrings("31", stream.getWritten());

    stream.reset();

    // Standard red background
    try Color.red.getAnsiCodes(false, writer);
    try std.testing.expectEqualStrings("41", stream.getWritten());

    stream.reset();

    // Bright red foreground (number 9)
    try Color.bright_red.getAnsiCodes(true, writer);
    try std.testing.expectEqualStrings("91", stream.getWritten());

    stream.reset();

    // 256 color
    try Color.from256(196).getAnsiCodes(true, writer);
    try std.testing.expectEqualStrings("38;5;196", stream.getWritten());

    stream.reset();

    // Truecolor
    try Color.fromRgb(255, 128, 64).getAnsiCodes(true, writer);
    try std.testing.expectEqualStrings("38;2;255;128;64", stream.getWritten());
}

test "rgbTo256 grayscale" {
    // Pure black
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    // Pure white
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
    // Mid gray
    const mid_gray = rgbTo256(128, 128, 128);
    try std.testing.expect(mid_gray >= 232 and mid_gray <= 255);
}

test "rgbTo256 color cube" {
    // Pure red should be near color 196 (5,0,0 in cube)
    const pure_red = rgbTo256(255, 0, 0);
    try std.testing.expectEqual(@as(u8, 196), pure_red);

    // Pure green should be near color 46 (0,5,0 in cube)
    const pure_green = rgbTo256(0, 255, 0);
    try std.testing.expectEqual(@as(u8, 46), pure_green);

    // Pure blue should be near color 21 (0,0,5 in cube)
    const pure_blue = rgbTo256(0, 0, 255);
    try std.testing.expectEqual(@as(u8, 21), pure_blue);
}

test "ColorSystem.supports" {
    try std.testing.expect(ColorSystem.truecolor.supports(.truecolor));
    try std.testing.expect(ColorSystem.truecolor.supports(.eight_bit));
    try std.testing.expect(ColorSystem.truecolor.supports(.standard));

    try std.testing.expect(!ColorSystem.eight_bit.supports(.truecolor));
    try std.testing.expect(ColorSystem.eight_bit.supports(.eight_bit));
    try std.testing.expect(ColorSystem.eight_bit.supports(.standard));

    try std.testing.expect(!ColorSystem.standard.supports(.truecolor));
    try std.testing.expect(!ColorSystem.standard.supports(.eight_bit));
    try std.testing.expect(ColorSystem.standard.supports(.standard));
}

test "named_colors lookup" {
    try std.testing.expect(named_colors.get("red").?.eql(Color.red));
    try std.testing.expect(named_colors.get("green").?.eql(Color.green));
    try std.testing.expect(named_colors.get("gray").?.eql(Color.bright_black));
    try std.testing.expect(named_colors.get("invalid") == null);
}
