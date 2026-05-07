const std = @import("std");
const win32 = @import("win32").everything;

const AppState = @import("../state.zig");
const config = @import("../../config/config.zig");

const tab_width: f32 = 16.0;
const tab_spacing: f32 = 8.0;
const margin: f32 = 8.0;
const height: f32 = 30.0;

pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Hit = union(enum) {
    none,
    add_tab,
    tab: usize,
};

pub fn bounds(client_size: win32.SIZE, grid_width: i32, tab_count_visual: u32, location: config.SwitcherLocation) Bounds {
    const width = tab_width * @as(f32, @floatFromInt(tab_count_visual)) +
        tab_spacing * @as(f32, @floatFromInt(tab_count_visual -| 1));

    return .{
        .x = switch (location) {
            .top_left, .bottom_left => margin,
            .top_right, .bottom_right => @as(f32, @floatFromInt(grid_width)) - width - margin,
        },
        .y = switch (location) {
            .top_left, .top_right => 0.0,
            .bottom_left, .bottom_right => @max(0.0, @as(f32, @floatFromInt(client_size.cy)) - height),
        },
        .width = width,
        .height = height,
    };
}

pub fn hitTest(
    state: *const AppState.State,
    client_size: win32.SIZE,
    grid_width: i32,
    location: config.SwitcherLocation,
    x: i32,
    y: i32,
) Hit {
    const tab_count_real: u32 = @intCast(state.tabCount());
    const tab_count_visual = tab_count_real + 1;
    const b = bounds(client_size, grid_width, tab_count_visual, location);

    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    if (xf < b.x or xf >= b.x + b.width or yf < b.y or yf >= b.y + b.height) return .none;

    const local_x = xf - b.x;
    const visual_tab_index: u32 = @intFromFloat(local_x / (tab_width + tab_spacing));
    const x_in_tab = local_x - (tab_width + tab_spacing) * @floor(local_x / (tab_width + tab_spacing));

    if (visual_tab_index >= tab_count_visual or x_in_tab >= tab_width) return .none;
    if (visual_tab_index == tab_count_real) return .add_tab;

    return if (state.physicalIndexForVisible(visual_tab_index)) |index|
        .{ .tab = index }
    else
        .none;
}
