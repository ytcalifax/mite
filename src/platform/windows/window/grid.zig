const std = @import("std");
const win32 = @import("win32").everything;
const TerminalRenderer = @import("../../../renderer/terminal.zig");
const pty = @import("../process/pty.zig");
const window = @import("core.zig");

pub const MIN_COLS = 40;
pub const MIN_ROWS = 10;
pub const MAX_COLS = 1000;
pub const MAX_ROWS = 1000;
pub const Y_PADDING = 30;

pub const PlacementOptions = struct {
    left: ?i32 = null,
    top: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    columns: ?u16 = null,
    rows: ?u16 = null,
};

pub const Placement = struct {
    pos: win32.POINT,
    size: win32.SIZE,
};

pub fn calcGridSize(client_size: win32.SIZE, cell_size: win32.SIZE, dpi: u32) pty.GridPos {
    const scrollbar_px = TerminalRenderer.scrollbarWidth(dpi);
    const grid_w = client_size.cx -| @as(i32, @intCast(scrollbar_px));
    return .{
        .col = @intCast(@min(MAX_COLS, @max(MIN_COLS, @divTrunc(@max(1, grid_w), cell_size.cx)))),
        .row = @intCast(@min(MAX_ROWS, @max(MIN_ROWS, @divTrunc(@max(1, client_size.cy - Y_PADDING), cell_size.cy)))),
    };
}

pub fn calcPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: win32.SIZE,
    opt: PlacementOptions,
) Placement {
    const inset = window.getClientInset(dpi);
    const scrollbar_px = TerminalRenderer.scrollbarWidth(dpi);

    const client_w: i32 = if (opt.columns) |cols|
        @as(i32, @intCast(cols)) * cell_size.cx + @as(i32, @intCast(scrollbar_px))
    else if (opt.width) |w|
        @as(i32, @intCast(w))
    else
        80 * cell_size.cx + @as(i32, @intCast(scrollbar_px));

    const client_h: i32 = if (opt.rows) |rows|
        @as(i32, @intCast(rows)) * cell_size.cy + Y_PADDING
    else if (opt.height) |h|
        @as(i32, @intCast(h))
    else
        24 * cell_size.cy + Y_PADDING;

    const win_w = client_w + inset.cx;
    const win_h = client_h + inset.cy;

    var pos: win32.POINT = .{
        .x = opt.left orelse win32.CW_USEDEFAULT,
        .y = opt.top orelse win32.CW_USEDEFAULT,
    };

    if (pos.x == win32.CW_USEDEFAULT or pos.y == win32.CW_USEDEFAULT) {
        if (maybe_monitor) |monitor| {
            var mi: win32.MONITORINFO = undefined;
            mi.cbSize = @sizeOf(win32.MONITORINFO);
            if (win32.GetMonitorInfoW(monitor, &mi) != 0) {
                const work_w = mi.rcWork.right - mi.rcWork.left;
                const work_h = mi.rcWork.bottom - mi.rcWork.top;
                if (pos.x == win32.CW_USEDEFAULT) pos.x = mi.rcWork.left + @divTrunc(work_w - win_w, 2);
                if (pos.y == win32.CW_USEDEFAULT) pos.y = mi.rcWork.top + @divTrunc(work_h - win_h, 2);
            }
        }
    }

    return .{
        .pos = pos,
        .size = .{ .cx = win_w, .cy = win_h },
    };
}

pub fn calcSnappedWindowRect(dpi: u32, rect: win32.RECT, edge: win32.WPARAM, cell_size: win32.SIZE) win32.RECT {
    const inset = window.getClientInset(dpi);
    const scrollbar_px = TerminalRenderer.scrollbarWidth(dpi);

    const win_w = rect.right - rect.left;
    const win_h = rect.bottom - rect.top;
    const client_w = win_w - inset.cx;
    const client_h = win_h - inset.cy;

    const grid_w = client_w -| @as(i32, @intCast(scrollbar_px));
    const col_count = @max(MIN_COLS, @divTrunc(grid_w + @divTrunc(cell_size.cx, 2), cell_size.cx));
    const row_count = @max(MIN_ROWS, @divTrunc(client_h - Y_PADDING + @divTrunc(cell_size.cy, 2), cell_size.cy));

    const snap_client_w = col_count * cell_size.cx + @as(i32, @intCast(scrollbar_px));
    const snap_client_h = row_count * cell_size.cy + Y_PADDING;
    const snap_win_w = snap_client_w + inset.cx;
    const snap_win_h = snap_client_h + inset.cy;

    var result = rect;
    switch (edge) {
        win32.WMSZ_LEFT, win32.WMSZ_TOPLEFT, win32.WMSZ_BOTTOMLEFT => result.left = rect.right - snap_win_w,
        win32.WMSZ_RIGHT, win32.WMSZ_TOPRIGHT, win32.WMSZ_BOTTOMRIGHT => result.right = rect.left + snap_win_w,
        else => {},
    }
    switch (edge) {
        win32.WMSZ_TOP, win32.WMSZ_TOPLEFT, win32.WMSZ_TOPRIGHT => result.top = rect.bottom - snap_win_h,
        win32.WMSZ_BOTTOM, win32.WMSZ_BOTTOMLEFT, win32.WMSZ_BOTTOMRIGHT => result.bottom = rect.top + snap_win_h,
        else => {},
    }
    return result;
}
