const std = @import("std");
const win32 = @import("win32").everything;

pub const Rgba8 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,
    pub fn fromU24(c: u24, a: u8) Rgba8 {
        return .{
            .r = @intCast((c >> 16) & 0xFF),
            .g = @intCast((c >> 8) & 0xFF),
            .b = @intCast(c & 0xFF),
            .a = a,
        };
    }
};

pub const GridConfig = extern struct {
    cell_size: [2]u32,
    col_count: u32,
    row_count: u32,
    scrollbar_y: f32,
    scrollbar_height: f32,
    scrollbar_x: f32,
    scrollbar_width: f32,
    background: Rgba8,
    foreground: Rgba8,
    cursor_color: Rgba8,
    opacity: f32,
    cursor_x: u32,
    cursor_y: u32,
    cursor_alpha: f32,
    cursor_style: u32,
};

pub const Cell = extern struct {
    glyph_index: u32,
    background: Rgba8,
    foreground: Rgba8,
};

pub const CellXY = struct {
    x: u16,
    y: u16,
    pub fn eql(a: CellXY, b: CellXY) bool {
        return a.x == b.x and a.y == b.y;
    }
};
