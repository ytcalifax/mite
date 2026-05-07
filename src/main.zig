const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;
const gvt = @import("vt");
const TerminalRenderer = @import("renderer/TerminalRenderer.zig");
const Config = @import("config/Config.zig").Config;
const Cmdline = @import("Cmdline.zig");
const AppState = @import("app/AppState.zig");
const VtHandler = @import("app/VtHandler.zig");
const pty = @import("platform/pty.zig");
const input = @import("platform/input.zig");
const window = @import("platform/window.zig");
const clipboard = @import("platform/clipboard.zig");

const cimport = @cImport({
    @cInclude("ResourceNames.h");
});

const log = std.log.scoped(.mite);

const WM_APP_CHILD_PROCESS_DATA = win32.WM_APP + 1;
const WM_APP_CHILD_PROCESS_DATA_RESULT = 0x12345678;

const TIMER_CURSOR = 1;
const TIMER_SELECTION_FADE = 2;

const MIN_COLS = 40;
const MIN_ROWS = 10;
const MAX_COLS = 160;
const MAX_ROWS = 1000;

const global = struct {
    var icons: Icons = undefined;
    var renderer: TerminalRenderer = undefined;
    var state: ?AppState.State = null;
    var term_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var config: Config = undefined;
    var resizing: bool = false;
    var resize_reflow_suppressed: bool = false;
    var fullscreen_resize_reflow_suppressed: bool = false;
    var high_surrogate: ?u16 = null;
    var cursor_phase: f32 = 0.0;
    var mouse_in_scrollbar: bool = false;
    var tracking_mouse: bool = false;
    var mouse_capture: enum { none, scrollbar_drag, selecting } = .none;
    var scrollbar_drag_offset: f32 = 0.0;
    var selection_fade: f32 = 0.0;
    var tab_hover_index: i32 = -1;
};

fn switchTab(state: *AppState.State, index: usize) void {
    if (index < state.tabs.items.len and state.tabs.items[index] != null) {
        state.active_tab_index = index;
        win32.invalidateHwnd(state.hwnd);
    }
}

fn getTabAtMouse(hwnd: win32.HWND, x: i32, y: i32) i32 {
    if (y < 0 or y >= 30) return -1;
    const state = stateFromHwnd(hwnd);

    var tab_count_real: u32 = 0;
    for (state.tabs.items) |maybe_tab| {
        if (maybe_tab != null) tab_count_real += 1;
    }
    const tab_count_visual = tab_count_real + 1; // Real tabs + "+" button

    const client_size = win32.getClientSize(hwnd);
    const sb_px = TerminalRenderer.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| @as(i32, @intCast(sb_px));

    const tab_w: f32 = 16.0;
    const spacing: f32 = 8.0;
    const tab_area_width = tab_w * @as(f32, @floatFromInt(tab_count_visual)) + spacing * @as(f32, @floatFromInt(tab_count_visual - 1));
    const tab_start_x = @as(f32, @floatFromInt(grid_w)) - tab_area_width - 8.0;

    if (@as(f32, @floatFromInt(x)) >= tab_start_x and @as(f32, @floatFromInt(x)) < @as(f32, @floatFromInt(grid_w)) - 8.0) {
        const local_x = @as(f32, @floatFromInt(x)) - tab_start_x;
        const visual_tab_idx = @as(i32, @intFromFloat(local_x / (tab_w + spacing)));
        const x_in_tab = fmod(local_x, (tab_w + spacing));
        if (visual_tab_idx >= 0 and visual_tab_idx < @as(i32, @intCast(tab_count_visual)) and x_in_tab < tab_w) {
            if (visual_tab_idx == @as(i32, @intCast(tab_count_real))) {
                return -2; // Special value for "+" button
            }

            var current_visible: i32 = 0;
            for (state.tabs.items, 0..) |maybe_tab, i| {
                if (maybe_tab != null) {
                    if (current_visible == visual_tab_idx) return @intCast(i);
                    current_visible += 1;
                }
            }
        }
    }
    return -1;
}

fn fmod(x: f32, y: f32) f32 {
    return x - y * @floor(x / y);
}

var is_resizing: bool = false;

fn updateWindowTitle(hwnd: win32.HWND, title: []const u8) void {
    window.updateWindowTitle(hwnd, title, global.gpa.allocator());
}

fn calcGridSize(client_size: win32.SIZE, cs: win32.SIZE, dpi: u32) pty.GridPos {
    const sb_px = TerminalRenderer.scrollbarWidth(dpi);
    const grid_w = client_size.cx -| @as(i32, @intCast(sb_px));
    return .{
        .col = @intCast(@min(MAX_COLS, @max(MIN_COLS, @divTrunc(@max(1, grid_w), cs.cx)))),
        .row = @intCast(@min(MAX_ROWS, @max(MIN_ROWS, @divTrunc(@max(1, client_size.cy - 2), cs.cy)))), // Y_PADDING = 2
    };
}

fn stateFromHwnd(hwnd: win32.HWND) *AppState.State {
    const s = &global.state.?;
    std.debug.assert(s.hwnd == hwnd);
    return s;
}

fn resizeActiveTab(hwnd: win32.HWND, state: *AppState.State, grid: pty.GridPos, notify_pty: bool) void {
    const tab = state.activeTab();
    const term_same_size = grid.col == tab.term.cols and grid.row == tab.term.rows;
    const pty_same_size = grid.col == tab.pty_grid.col and grid.row == tab.pty_grid.row;
    if (term_same_size and (!notify_pty or pty_same_size)) return;

    var active_screen = tab.term.screens.active;
    active_screen.scroll(.active);

    if (!term_same_size) {
        tab.term.resize(global.term_arena.allocator(), grid.col, grid.row) catch |err| {
            log.err("Terminal resize failed: {any}", .{err});
            return;
        };
    }

    if (notify_pty and !pty_same_size) {
        var out_err: pty.Error = undefined;
        var pty_resized = true;
        tab.child_process.resize(&out_err, grid) catch {
            log.err("PTY resize failed: {s}", .{out_err.what});
            pty_resized = false;
        };
        if (pty_resized) tab.pty_grid = grid;
    }

    active_screen.scroll(.active);
    win32.invalidateHwnd(hwnd);
}

fn flushMessages() void {
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
        if (msg.message == win32.WM_QUIT) onWmQuit(msg.wParam);
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

const WindowPlacementOptions = struct {
    left: ?i32 = null,
    top: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    columns: ?u16 = null,
    rows: ?u16 = null,
};

const WindowPlacement = struct {
    pos: win32.POINT,
    size: win32.SIZE,
};

fn calcWindowPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: win32.SIZE,
    opt: WindowPlacementOptions,
) WindowPlacement {
    const inset = window.getClientInset(dpi);
    const sb_px = TerminalRenderer.scrollbarWidth(dpi);

    const client_w: i32 = if (opt.columns) |cols|
        @as(i32, @intCast(cols)) * cell_size.cx + @as(i32, @intCast(sb_px))
    else if (opt.width) |w|
        @as(i32, @intCast(w))
    else
        80 * cell_size.cx + @as(i32, @intCast(sb_px));

    const client_h: i32 = if (opt.rows) |rows|
        @as(i32, @intCast(rows)) * cell_size.cy + 2 // Y_PADDING = 2
    else if (opt.height) |h|
        @as(i32, @intCast(h))
    else
        24 * cell_size.cy + 2; // Y_PADDING = 2

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

fn calcWindowRect(dpi: u32, rect: win32.RECT, edge: win32.WPARAM, cell_size: win32.SIZE) win32.RECT {
    const inset = window.getClientInset(dpi);
    const sb_px = TerminalRenderer.scrollbarWidth(dpi);

    const win_w = rect.right - rect.left;
    const win_h = rect.bottom - rect.top;
    const client_w = win_w - inset.cx;
    const client_h = win_h - inset.cy;

    const grid_w = client_w -| @as(i32, @intCast(sb_px));
    const col_count = @max(MIN_COLS, @divTrunc(grid_w + @divTrunc(cell_size.cx, 2), cell_size.cx));
    const row_count = @max(MIN_ROWS, @divTrunc(client_h - 2 + @divTrunc(cell_size.cy, 2), cell_size.cy)); // Y_PADDING = 2

    const snap_client_w = col_count * cell_size.cx + @as(i32, @intCast(sb_px));
    const snap_client_h = row_count * cell_size.cy + 2; // Y_PADDING = 2
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

fn setWindowPosRect(hwnd: win32.HWND, rect: win32.RECT) void {
    if (0 == win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1 },
    )) win32.panicWin32("SetWindowPos", win32.GetLastError());
}

fn handleShortcut(hwnd: win32.HWND, state: *AppState.State, wparam: win32.WPARAM) bool {
    const vk: u16 = @intCast(wparam);
    const ctrl = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
    const shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
    const alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0;

    for (input.shortcut_mappings) |m| {
        if (m.vk == vk and m.ctrl == ctrl and m.shift == shift and m.alt == alt) {
            switch (m.action) {
                .paste => pasteClipboard(hwnd, state),
                .fullscreen => {
                    const was_fullscreen = window.isFullscreen(hwnd);
                    global.resize_reflow_suppressed = true;
                    global.fullscreen_resize_reflow_suppressed = true;
                    window.toggleFullscreen(hwnd, state);
                    if (was_fullscreen) {
                        global.fullscreen_resize_reflow_suppressed = false;
                        global.resize_reflow_suppressed = false;
                        const grid = calcGridSize(
                            win32.getClientSize(hwnd),
                            global.renderer.cell_size,
                            win32.GetDpiForWindow(hwnd),
                        );
                        resizeActiveTab(hwnd, state, grid, true);
                    }
                },
                else => {},
            }
            return true;
        }
    }
    return false;
}

fn createTab(state: *AppState.State, grid: pty.GridPos) !void {
    var target_index: ?usize = null;
    for (state.tabs.items, 0..) |maybe_tab, i| {
        if (maybe_tab == null) {
            target_index = i;
            break;
        }
    }

    const tab_index = target_index orelse state.tabs.items.len;
    if (tab_index >= 100) return error.TooManyTabs;

    var arena = try global.gpa.allocator().create(std.heap.ArenaAllocator);
    errdefer global.gpa.allocator().destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();

    const shell_w = blk: {
        const shell_cmd = global.config.shell.program;
        const shell_args = global.config.shell.args;

        var total_len: usize = shell_cmd.len + 2;
        for (shell_args) |arg| {
            total_len += arg.len + 3;
        }

        const full_cmd = arena.allocator().alloc(u8, total_len + 1) catch unreachable;
        var stream = std.io.fixedBufferStream(full_cmd);
        const writer = stream.writer();
        writer.print("\"{s}\"", .{shell_cmd}) catch unreachable;
        for (shell_args) |arg| {
            writer.print(" \"{s}\"", .{arg}) catch unreachable;
        }
        full_cmd[stream.pos] = 0;
        const final_cmd = full_cmd[0..stream.pos :0];

        const u16_len = std.unicode.calcUtf16LeLen(final_cmd) catch |e| {
            log.err("calcUtf16LeLen failed for '{s}': {any}", .{ final_cmd, e });
            break :blk win32.L("cmd.exe");
        };
        const buf = arena.allocator().alloc(u16, u16_len + 1) catch unreachable;
        const len = std.unicode.utf8ToUtf16Le(buf, final_cmd) catch unreachable;
        buf[len] = 0;
        break :blk buf[0..len :0].ptr;
    };

    var err: pty.Error = undefined;
    const child_process = pty.ChildProcess.startConPtyWin32(
        &err,
        arena.allocator(),
        null,
        @constCast(shell_w),
        state.hwnd,
        WM_APP_CHILD_PROCESS_DATA + @as(u32, @intCast(tab_index)),
        WM_APP_CHILD_PROCESS_DATA_RESULT,
        grid,
    ) catch |e| {
        log.err("ChildProcess.startConPtyWin32 failed: {any} - {s}", .{ e, err.what });
        return e;
    };

    const term = global.term_arena.allocator().create(gvt.Terminal) catch unreachable;
    term.* = gvt.Terminal.init(global.term_arena.allocator(), .{
        .cols = grid.col,
        .rows = grid.row,
    }) catch |e| {
        log.err("Terminal.init failed: {any}", .{e});
        return e;
    };

    const new_tab: AppState.Tab = .{
        .child_process = child_process,
        .term = term,
        .pty_grid = grid,
        .vt_stream = VtHandler.VtStream(VtHandler.MiteHandler).initAlloc(global.gpa.allocator(), VtHandler.MiteHandler{
            .inner = term.vtHandler(),
            .hwnd = state.hwnd,
            .update_title_fn = updateWindowTitle,
        }),
        .title = "Mite",
        .arena = arena,
    };

    if (target_index) |idx| {
        state.tabs.items[idx] = new_tab;
    } else {
        try state.tabs.append(global.gpa.allocator(), new_tab);
    }
    state.active_tab_index = tab_index;
}

fn closeTab(state: *AppState.State, index: usize) void {
    var tab_count: usize = 0;
    for (state.tabs.items) |maybe_tab| {
        if (maybe_tab != null) tab_count += 1;
    }
    if (tab_count <= 1) return;

    if (state.tabs.items[index]) |*tab| {
        _ = win32.TerminateProcess(tab.child_process.process_handle, 0);
        tab.arena.deinit();
        global.gpa.allocator().destroy(tab.arena);
        state.tabs.items[index] = null;
    }

    if (state.active_tab_index == index) {
        // Find next available tab
        var found = false;
        for (index..state.tabs.items.len) |i| {
            if (state.tabs.items[i] != null) {
                state.active_tab_index = i;
                found = true;
                break;
            }
        }
        if (!found) {
            var i: usize = index;
            while (i > 0) {
                i -= 1;
                if (state.tabs.items[i] != null) {
                    state.active_tab_index = i;
                    found = true;
                    break;
                }
            }
        }
    }
    win32.invalidateHwnd(state.hwnd);
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg >= WM_APP_CHILD_PROCESS_DATA and msg < WM_APP_CHILD_PROCESS_DATA + 100) {
        const tab_index = msg - WM_APP_CHILD_PROCESS_DATA;
        const buffer: [*]const u8 = @ptrFromInt(wparam);
        const len: usize = @bitCast(lparam);
        if (global.state) |*state| {
            if (tab_index < state.tabs.items.len) {
                if (state.tabs.items[tab_index]) |*tab| {
                    tab.vt_stream.nextSlice(buffer[0..len]) catch |e| {
                        log.err("vt stream failed: {any}", .{e});
                    };
                    win32.invalidateHwnd(hwnd);
                }
            }
        }
        return WM_APP_CHILD_PROCESS_DATA_RESULT;
    }

    switch (msg) {
        win32.WM_CREATE => {
            std.debug.assert(global.state == null);

            const client_size = win32.getClientSize(hwnd);
            const cs = global.renderer.cell_size;
            const dpi = win32.dpiFromHwnd(hwnd);
            const cell_count = calcGridSize(client_size, cs, dpi);

            global.state = .{
                .hwnd = hwnd,
                .tabs = .empty,
                .active_tab_index = 0,
            };

            createTab(&global.state.?, cell_count) catch |e| {
                log.err("Failed to create initial tab: {any}", .{e});
                win32.ExitProcess(1);
            };

            global.cursor_phase = 0.0;
            _ = win32.SetTimer(hwnd, TIMER_CURSOR, 16, null);

            return 0;
        },
        win32.WM_CLOSE, win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);

            const tab_idx = getTabAtMouse(hwnd, mouse_x, mouse_y);
            if (tab_idx == -2) {
                const state = stateFromHwnd(hwnd);
                const grid = calcGridSize(win32.getClientSize(hwnd), global.renderer.cell_size, win32.dpiFromHwnd(hwnd));
                createTab(state, grid) catch |e| log.err("createTab failed: {any}", .{e});
                return 0;
            } else if (tab_idx >= 0) {
                const state = stateFromHwnd(hwnd);
                switchTab(state, @intCast(tab_idx));
                return 0;
            }

            const client_size = win32.getClientSize(hwnd);
            const sb_px = TerminalRenderer.scrollbarWidth(win32.dpiFromHwnd(hwnd));
            const grid_w = client_size.cx -| @as(i32, @intCast(sb_px));
            if (mouse_x >= grid_w) {
                const state = stateFromHwnd(hwnd);
                const screen = state.activeTab().term.screens.active;
                const sb = screen.pages.scrollbar();
                if (sb.total > sb.len) {
                    const win_h: f32 = @floatFromInt(client_size.cy);
                    const min_track_height: f32 = 20.0;
                    const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                    const max_offset = sb.total - sb.len;
                    const track_y = @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);
                    const mouse_yf: f32 = @floatFromInt(mouse_y);

                    if (mouse_yf >= track_y and mouse_yf < track_y + track_height) {
                        global.mouse_capture = .scrollbar_drag;
                        global.scrollbar_drag_offset = mouse_yf - track_y;
                    } else {
                        global.mouse_capture = .scrollbar_drag;
                        global.scrollbar_drag_offset = track_height / 2.0;
                        scrollbarDragTo(state, mouse_yf - track_height / 2.0, win_h, track_height);
                    }
                    _ = win32.SetCapture(hwnd);
                    win32.invalidateHwnd(hwnd);
                }
            } else {
                const state = stateFromHwnd(hwnd);
                const screen = state.activeTab().term.screens.active;
                global.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                const cs = global.renderer.cell_size;
                const col: usize = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx));
                const row: usize = @intCast(@divTrunc(@max(mouse_y, 0), cs.cy));
                if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                    screen.clearSelection();
                    const sel = gvt.Selection.init(pin, pin, false);
                    screen.select(sel) catch |e| log.err("screen.select failed: {any}", .{e});
                    global.mouse_capture = .selecting;
                    _ = win32.SetCapture(hwnd);
                    win32.invalidateHwnd(hwnd);
                }
            }
            return 0;
        },
        win32.WM_MBUTTONDOWN => {
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);
            const tab_idx = getTabAtMouse(hwnd, mouse_x, mouse_y);
            if (tab_idx >= 0) {
                const state = stateFromHwnd(hwnd);
                closeTab(state, @intCast(tab_idx));
                return 0;
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            switch (global.mouse_capture) {
                .none => {},
                .scrollbar_drag => {
                    global.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                    win32.invalidateHwnd(hwnd);
                },
                .selecting => {
                    global.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                    const state = stateFromHwnd(hwnd);
                    const screen = state.activeTab().term.screens.active;
                    if (screen.selection) |sel| {
                        const alloc = global.gpa.allocator();
                        const text = screen.selectionString(alloc, .{ .sel = sel }) catch |e| {
                            log.err("selectionString failed: {any}", .{e});
                            return 0;
                        };
                        defer alloc.free(text);
                        if (text.len > 0) {
                            clipboard.copyToClipboard(hwnd, text);
                        }
                        global.selection_fade = 1.0;
                        _ = win32.SetTimer(hwnd, TIMER_SELECTION_FADE, 16, null);
                    }
                },
            }
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_MOUSEWHEEL => {
            const state = stateFromHwnd(hwnd);
            const delta: i16 = @bitCast(win32.hiword(wparam));
            const scroll_lines: isize = if (delta > 0) -3 else 3;
            const screen = state.activeTab().term.screens.active;
            screen.scroll(.{ .delta_row = scroll_lines });
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            if (!global.tracking_mouse) {
                var tme = win32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = win32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = win32.TrackMouseEvent(&tme);
                global.tracking_mouse = true;
            }
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);

            const new_hover = getTabAtMouse(hwnd, mouse_x, mouse_y);
            if (new_hover != global.tab_hover_index) {
                global.tab_hover_index = new_hover;
                win32.invalidateHwnd(hwnd);
            }

            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, @intCast(TerminalRenderer.scrollbarWidth(win32.dpiFromHwnd(hwnd))));

            switch (global.mouse_capture) {
                .none => {},
                .scrollbar_drag => {
                    const state = stateFromHwnd(hwnd);
                    const win_h: f32 = @floatFromInt(client_size.cy);
                    const sb = state.activeTab().term.screens.active.pages.scrollbar();
                    const min_track_height: f32 = 20.0;
                    const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                    scrollbarDragTo(state, @as(f32, @floatFromInt(mouse_y)) - global.scrollbar_drag_offset, win_h, track_height);
                    win32.invalidateHwnd(hwnd);
                },
                .selecting => {
                    const state = stateFromHwnd(hwnd);
                    const screen = state.activeTab().term.screens.active;
                    const cs = global.renderer.cell_size;
                    const clamped_x: i32 = @max(0, @min(mouse_x, grid_w - 1));
                    const clamped_y: i32 = @max(0, @min(mouse_y, client_size.cy - 1));
                    const col: usize = @intCast(@divTrunc(clamped_x, cs.cx));
                    const row: usize = @intCast(@divTrunc(clamped_y, cs.cy));
                    if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                        if (screen.selection) |*sel| {
                            sel.endPtr().* = pin;
                            win32.invalidateHwnd(hwnd);
                        }
                    }
                },
            }

            const in_scrollbar = mouse_x >= grid_w;
            if (in_scrollbar != global.mouse_in_scrollbar) {
                global.mouse_in_scrollbar = in_scrollbar;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            global.tracking_mouse = false;
            global.tab_hover_index = -1;
            if (global.mouse_in_scrollbar) {
                global.mouse_in_scrollbar = false;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_DISPLAYCHANGE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_SYSCOMMAND => {
            const command = wparam & 0xfff0;
            switch (command) {
                win32.SC_MINIMIZE, win32.SC_MAXIMIZE => global.resize_reflow_suppressed = true,
                else => {},
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_EXITSIZEMOVE => {
            global.resizing = false;
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_SIZING => {
            if (!global.resizing) {
                global.resizing = true;
                win32.invalidateHwnd(hwnd);
            }
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = win32.dpiFromHwnd(hwnd);
            const new_rect = calcWindowRect(dpi, rect.*, wparam, global.renderer.cell_size);
            rect.* = new_rect;
            return 0;
        },
        win32.WM_GETMINMAXINFO => {
            const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;
            const inset = window.getClientInset(dpi);
            const sb_px = TerminalRenderer.scrollbarWidth(dpi);

            const min_client_w = @as(i32, @intCast(MIN_COLS)) * cs.cx + @as(i32, @intCast(sb_px));
            const min_client_h = @as(i32, @intCast(MIN_ROWS)) * cs.cy + 2; // Y_PADDING = 2

            mmi.ptMinTrackSize.x = min_client_w + inset.cx;
            mmi.ptMinTrackSize.y = min_client_h + inset.cy;
            return 0;
        },
        win32.WM_SIZE => {
            const state = stateFromHwnd(hwnd);

            if (is_resizing) return 0;
            if (wparam == win32.SIZE_MINIMIZED) {
                global.resize_reflow_suppressed = true;
                return 0;
            }

            is_resizing = true;
            defer is_resizing = false;

            const lp_usize = @as(usize, @bitCast(lparam));
            const width = @as(u16, @truncate(lp_usize));
            const height = @as(u16, @truncate(lp_usize >> 16));

            const grid = calcGridSize(
                .{ .cx = @as(i32, @intCast(width)), .cy = @as(i32, @intCast(height)) },
                global.renderer.cell_size,
                win32.GetDpiForWindow(hwnd),
            );

            const notify_pty = if (global.fullscreen_resize_reflow_suppressed) false else switch (wparam) {
                win32.SIZE_MAXIMIZED => blk: {
                    global.resize_reflow_suppressed = true;
                    break :blk false;
                },
                win32.SIZE_RESTORED => blk: {
                    global.resize_reflow_suppressed = false;
                    break :blk true;
                },
                else => !global.resize_reflow_suppressed,
            };

            resizeActiveTab(hwnd, state, grid, notify_pty);

            return 0;
        },
        win32.WM_PAINT => {
            _, var ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const state = stateFromHwnd(hwnd);
            const cursor_alpha = Config.calculateCursorAlpha(global.cursor_phase, global.config);

            var tab_count: u32 = 0;
            for (state.tabs.items) |maybe_tab| {
                if (maybe_tab != null) tab_count += 1;
            }

            var visible_active_idx: u32 = 0;
            var current_visible: u32 = 0;
            for (state.tabs.items, 0..) |maybe_tab, i| {
                if (maybe_tab != null) {
                    if (i == state.active_tab_index) visible_active_idx = current_visible;
                    current_visible += 1;
                }
            }

            var visible_hover_idx: i32 = -1;
            if (global.tab_hover_index >= 0) {
                var current_v: i32 = 0;
                for (state.tabs.items, 0..) |maybe_tab, i| {
                    if (maybe_tab != null) {
                        if (i == @as(usize, @intCast(global.tab_hover_index))) {
                            visible_hover_idx = current_v;
                            break;
                        }
                        current_v += 1;
                    }
                }
            }

            global.renderer.render(
                hwnd,
                state.activeTab().term,
                global.resizing,
                global.mouse_in_scrollbar,
                if (global.mouse_capture == .selecting) 1.0 else global.selection_fade,
                cursor_alpha,
                tab_count,
                visible_active_idx,
                visible_hover_idx,
            );
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;

            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, @intCast(TerminalRenderer.scrollbarWidth(current_dpi)));
            const col_count = @min(MAX_COLS, @max(MIN_COLS, @divTrunc(grid_w, cs.cx)));
            const row_count = @min(MAX_ROWS, @max(MIN_ROWS, @divTrunc(client_size.cy - 2, cs.cy))); // Y_PADDING = 2

            const new_cs = global.renderer.cellSizeForDpi(new_dpi);
            const new_client_w = col_count * new_cs.cx + @as(i32, @intCast(TerminalRenderer.scrollbarWidth(new_dpi)));
            const new_client_h = row_count * new_cs.cy + 2; // Y_PADDING = 2
            const new_inset = window.getClientInset(new_dpi);
            inout_size.* = .{
                .cx = new_client_w + new_inset.cx,
                .cy = new_client_h + new_inset.cy,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            const dpi = win32.hiword(wparam);
            global.renderer.updateDpi(dpi);
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_KEYDOWN => {
            const state = stateFromHwnd(hwnd);
            if (handleShortcut(hwnd, state, wparam)) return 0;

            const tab = state.activeTab();
            const child_pty = tab.child_process.pty orelse return 0;
            const screen = tab.term.screens.active;

            if (screen.selection != null) {
                screen.clearSelection();
                global.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                win32.invalidateHwnd(hwnd);
            }

            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                win32.invalidateHwnd(hwnd);
            }

            var buf: [32]u8 = undefined;
            if (input.translateKey(wparam, tab.term.modes.values.cursor_keys, &buf)) |seq| {
                child_pty.writeFlushAll(seq) catch |e| log.err("write to pty failed: {any}", .{e});
                return 0;
            }

            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_CHAR => {
            const state = stateFromHwnd(hwnd);
            const tab = state.activeTab();
            const child_pty = tab.child_process.pty orelse return 0;
            const screen = tab.term.screens.active;
            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                win32.invalidateHwnd(hwnd);
            }
            const char: u16 = std.math.cast(u16, wparam) orelse {
                log.warn("unexpected WM_CHAR wparam: {any}", .{wparam});
                return 0;
            };
            if (char == 0x08) return 0;
            if (char == 0x16 and win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0) return 0;
            if (std.unicode.utf16IsHighSurrogate(char)) {
                global.high_surrogate = char;
                return 0;
            }
            const codepoint: u21 = blk: {
                if (global.high_surrogate) |high| {
                    global.high_surrogate = null;
                    if (std.unicode.utf16IsLowSurrogate(char)) {
                        break :blk std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, char }) catch return 0;
                    }
                }
                break :blk @intCast(char);
            };
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
            child_pty.writeFlushAll(utf8_buf[0..len]) catch |e| log.err("write to pty failed: {any}", .{e});
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            const state = stateFromHwnd(hwnd);
            pasteClipboard(hwnd, state);
            return 0;
        },
        win32.WM_TIMER => {
            if (wparam == TIMER_SELECTION_FADE) {
                global.selection_fade -= 0.05;
                if (global.selection_fade <= 0) {
                    global.selection_fade = 0;
                    _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                    const state = stateFromHwnd(hwnd);
                    state.activeTab().term.screens.active.clearSelection();
                }
                win32.invalidateHwnd(hwnd);
            } else if (wparam == TIMER_CURSOR) {
                global.cursor_phase += 16.0;
                const total_ms = @as(f32, @floatFromInt(global.config.cursor.fade_in + global.config.cursor.fade_out));
                if (total_ms > 0 and global.cursor_phase >= total_ms) global.cursor_phase -= total_ms;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },

        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};

fn getIcons(dpi: XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);

    const small = @as(?win32.HICON, @ptrCast(win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ))) orelse win32.LoadIconW(null, win32.IDI_APPLICATION);
    const large = @as(?win32.HICON, @ptrCast(win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ))) orelse win32.LoadIconW(null, win32.IDI_APPLICATION);
    return .{ .small = small.?, .large = large.? };
}

fn onWmQuit(wparam: win32.WPARAM) noreturn {
    win32.ExitProcess(@intCast(wparam));
}

fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

fn scrollbarDragTo(state: *AppState.State, track_top: f32, win_h: f32, track_height: f32) void {
    const screen = state.activeTab().term.screens.active;
    const sb = screen.pages.scrollbar();
    if (sb.total <= sb.len) return;
    const max_offset = sb.total - sb.len;
    const scrollable = win_h - track_height;
    if (scrollable <= 0) return;
    const ratio = std.math.clamp(track_top / scrollable, 0.0, 1.0);
    const target_row: usize = @intFromFloat(ratio * @as(f32, @floatFromInt(max_offset)));
    screen.scroll(.{ .row = target_row });
}

fn pasteClipboard(hwnd: win32.HWND, state: *AppState.State) void {
    const child_pty = state.activeTab().child_process.pty orelse return;
    if (win32.OpenClipboard(hwnd) == 0) return;
    defer _ = win32.CloseClipboard();
    const handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse return;
    const hmem: isize = @bitCast(@intFromPtr(handle));
    const mem: [*:0]const u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse return));
    defer {
        win32.SetLastError(.NO_ERROR);
        if (0 == win32.GlobalUnlock(hmem)) {
            const err = win32.GetLastError();
            if (err != .NO_ERROR) log.err("GlobalUnlock failed: {any}", .{err});
        }
    }

    clipboard.pasteUtf16(mem, &child_pty.write) catch |e| log.err("paste failed: {any}", .{e});
}

pub fn main() !void {
    defer _ = global.gpa.deinit();
    const gpa = global.gpa.allocator();

    var args_it = try std.process.argsWithAllocator(gpa);
    defer args_it.deinit();
    const cmdline = (try Cmdline.parse(&args_it)) orelse {
        try Cmdline.usage(std.fs.File.stderr());
        return;
    };

    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();
    global.config = Config.load(config_arena.allocator()) catch |err| blk: {
        log.err("failed to load config: {any}", .{err});
        const names = config_arena.allocator().alloc([]const u8, 2) catch {
            log.err("OOM while allocating fallback font names", .{});
            return;
        };
        names[0] = "Consolas 7NF";
        names[1] = "Consolas";
        break :blk Config{ .font = .{ .names = names } };
    };

    const opt: WindowPlacementOptions = .{
        .width = @as(u32, @intFromFloat(cmdline.font_size * 50)),
        .height = @as(u32, @intFromFloat(cmdline.font_size * 30)),
    };

    const maybe_monitor: ?win32.HMONITOR = win32.MonitorFromPoint(.{ .x = 0, .y = 0 }, win32.MONITOR_DEFAULTTOPRIMARY);

    const dpi: XY(u32) = blk: {
        const monitor = maybe_monitor orelse break :blk .{ .x = 96, .y = 96 };
        var d: XY(u32) = undefined;
        if (win32.GetDpiForMonitor(monitor, win32.MDT_EFFECTIVE_DPI, &d.x, &d.y) < 0) break :blk .{ .x = 96, .y = 96 };
        break :blk d;
    };

    global.icons = getIcons(dpi);
    global.renderer = try TerminalRenderer.init(@max(dpi.x, dpi.y), &global.config);
    defer global.renderer.deinit();

    const cell_size = global.renderer.cell_size;
    const placement = calcWindowPlacement(maybe_monitor, @max(dpi.x, dpi.y), cell_size, opt);

    const CLASS_NAME = win32.L("MiteWindow");
    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = global.icons.large,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = global.icons.small,
        };
        _ = win32.RegisterClassExW(&wc);
    }

    const hwnd = win32.CreateWindowExW(
        window.window_style_ex,
        CLASS_NAME,
        win32.L("Mite"),
        window.window_style,
        placement.pos.x,
        placement.pos.y,
        placement.size.cx,
        placement.size.cy,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse return error.CreateWindowFailed;

    {
        window.applyWindowTheme(hwnd, global.config);
    }

    _ = win32.UpdateWindow(hwnd);
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });
    _ = win32.SetForegroundWindow(hwnd);

    while (true) {
        const state = blk: {
            while (global.state == null) {
                var msg: win32.MSG = undefined;
                const res = win32.GetMessageW(&msg, null, 0, 0);
                if (res <= 0) onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            break :blk &global.state.?;
        };

        var handles = [1]win32.HANDLE{state.activeTab().child_process.process_handle};
        const wait_result = win32.MsgWaitForMultipleObjectsEx(1, &handles, win32.INFINITE, win32.QS_ALLINPUT, .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 });
        if (wait_result == 0) win32.ExitProcess(0);

        flushMessages();
    }
}
