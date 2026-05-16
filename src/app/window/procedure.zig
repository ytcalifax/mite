const std = @import("std");
const win32 = @import("win32").everything;
const gvt = @import("vt");
const TerminalRenderer = @import("../../renderer/terminal.zig");
const Config = @import("../../config/config.zig").Config;
const AppState = @import("../state.zig");
const TerminalResizer = @import("../terminal/resizer.zig");
const TabLifecycle = @import("../tabs/lifecycle.zig");
const TabSwitcher = @import("../tabs/switcher.zig");
const pty = @import("../../platform/windows/process/pty.zig");
const input = @import("../../platform/windows/io/input.zig");
const window = @import("../../platform/windows/window/core.zig");
const windowgrid = @import("../../platform/windows/window/grid.zig");
const clipboard = @import("../../platform/windows/io/clipboard.zig");
const IconResources = @import("../../platform/windows/resources/icons.zig");

const log = std.log.scoped(.mite);

const WM_APP_CHILD_PROCESS_DATA = win32.WM_APP + 1;
const WM_APP_CHILD_PROCESS_DATA_RESULT = 0x12345678;

const TIMER_CURSOR = 1;
const TIMER_SELECTION_FADE = 2;
const TIMER_PTY_PAINT = 3;
const TIMER_TAB_ANIMATION = 4;
const CURSOR_TIMER_MS = 33;
const PTY_PAINT_COALESCE_MS = 8;
const TAB_ANIMATION_MS = 16;

pub const global = struct {
    pub var icons: IconResources.Pair = undefined;
    pub var renderer: TerminalRenderer = undefined;
    pub var state: ?AppState.State = null;
    var term_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    pub var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    pub var config: Config = undefined;
    var resizing: bool = false;
    var size_policy: TerminalResizer.SizePolicy = .{};
    var high_surrogate: ?u16 = null;
    var cursor_phase: f32 = 0.0;
    var mouse_in_scrollbar: bool = false;
    var tracking_mouse: bool = false;
    var mouse_capture: enum { none, scrollbar_drag, selecting } = .none;
    var scrollbar_drag_offset: f32 = 0.0;
    var selection_fade: f32 = 0.0;
    var tab_hover_index: i32 = -1;
    var tab_expansions: [100]f32 = [_]f32{0.0} ** 100;
    var cell_buffer_dirty: bool = true;
    var pty_paint_pending: bool = false;
    var pending_live_resize_grid: ?pty.GridPos = null;
};

fn switchTab(state: *AppState.State, index: usize) void {
    if (index < state.tabs.items.len and state.tabs.items[index] != null) {
        activateTab(state, index);
    }
}

fn currentWindowGrid(hwnd: win32.HWND) pty.GridPos {
    return windowgrid.calcGridSize(
        win32.getClientSize(hwnd),
        global.renderer.cell_size,
        win32.dpiFromHwnd(hwnd),
    );
}

fn activateTab(state: *AppState.State, index: usize) void {
    const changed = state.active_tab_index != index;
    state.active_tab_index = index;
    const result = TerminalResizer.resizeActiveTab(
        global.term_arena.allocator(),
        state.activeTab(),
        currentWindowGrid(state.hwnd),
        true,
    );
    if (changed or result.paint) invalidateWithCells(state.hwnd);
}

fn getTabAtMouse(hwnd: win32.HWND, x: i32, y: i32) i32 {
    const state = stateFromHwnd(hwnd);

    const client_size = win32.getClientSize(hwnd);
    const sb_px = TerminalRenderer.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| @as(i32, @intCast(sb_px));
    return switch (TabSwitcher.hitTest(state, client_size, grid_w, global.config.tabs.switcher_location, x, y)) {
        .none => -1,
        .add_tab => -2,
        .tab => |index| @intCast(index),
    };
}

fn updateWindowTitle(hwnd: win32.HWND, title: []const u8) void {
    window.updateWindowTitle(hwnd, title, global.gpa.allocator());
}

pub fn tabLifecycleContext() TabLifecycle.Context {
    return .{
        .gpa = global.gpa.allocator(),
        .term_allocator = global.term_arena.allocator(),
        .config = &global.config,
        .update_title_fn = updateWindowTitle,
        .pty_message_base = WM_APP_CHILD_PROCESS_DATA,
        .pty_message_result = WM_APP_CHILD_PROCESS_DATA_RESULT,
    };
}

pub fn handleTabDestroyResult(state: *AppState.State, result: TabLifecycle.DestroyResult) void {
    switch (result) {
        .none => {},
        .quit => win32.PostQuitMessage(0),
        .paint => invalidateWithCells(state.hwnd),
        .activate => |index| activateTab(state, index),
    }
}

fn cursorAnimationEnabled() bool {
    return global.config.cursor.blink and global.config.cursor.fade_in + global.config.cursor.fade_out > 0;
}

fn startCursorTimer(hwnd: win32.HWND) void {
    if (cursorAnimationEnabled()) {
        _ = win32.SetTimer(hwnd, TIMER_CURSOR, CURSOR_TIMER_MS, null);
    }
}

fn markCellsDirty() void {
    global.cell_buffer_dirty = true;
}

fn invalidateWithCells(hwnd: win32.HWND) void {
    markCellsDirty();
    win32.invalidateHwnd(hwnd);
}

fn schedulePtyPaint(hwnd: win32.HWND) void {
    markCellsDirty();
    if (!global.pty_paint_pending) {
        global.pty_paint_pending = true;
        _ = win32.SetTimer(hwnd, TIMER_PTY_PAINT, PTY_PAINT_COALESCE_MS, null);
    }
}

fn stateFromHwnd(hwnd: win32.HWND) *AppState.State {
    const s = &global.state.?;
    std.debug.assert(s.hwnd == hwnd);
    return s;
}

pub fn flushMessages() void {
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
        if (msg.message == win32.WM_QUIT) onWmQuit(msg.wParam);
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
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
                    global.size_policy.beforeFullscreenToggle(state.activeTab());
                    window.toggleFullscreen(hwnd, state);
                    if (was_fullscreen) {
                        global.size_policy.afterFullscreenRestore();
                        const grid = windowgrid.calcGridSize(
                            win32.getClientSize(hwnd),
                            global.renderer.cell_size,
                            win32.GetDpiForWindow(hwnd),
                        );
                        const result = TerminalResizer.resizeActiveTab(
                            global.term_arena.allocator(),
                            state.activeTab(),
                            grid,
                            true,
                        );
                        if (result.paint) invalidateWithCells(hwnd);
                    }
                },
            }
            return true;
        }
    }
    return false;
}

fn mousePosToGrid(mouse_x: i32, mouse_y: i32, cs: win32.SIZE) struct { col: usize, row: usize } {
    return .{
        .col = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx)),
        .row = @intCast(@divTrunc(@max(mouse_y, 0), cs.cy)),
    };
}

pub fn proc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg >= WM_APP_CHILD_PROCESS_DATA and msg < WM_APP_CHILD_PROCESS_DATA + 100) {
        const tab_index = msg - WM_APP_CHILD_PROCESS_DATA;
        const payload: *pty.ReadPayload = @ptrFromInt(wparam);
        defer pty.releaseReadPayload(payload);
        if (global.state) |*state| {
            if (tab_index < state.tabs.items.len) {
                if (state.tabs.items[tab_index]) |*tab| {
                    if (tab.generation == payload.generation) {
                        tab.vt_stream.nextSlice(payload.data[0..payload.len]) catch |e| {
                            log.err("vt stream failed: {any}", .{e});
                        };
                        TerminalResizer.afterPtyOutput(global.term_arena.allocator(), tab);
                        schedulePtyPaint(hwnd);
                    }
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
            const cell_count = windowgrid.calcGridSize(client_size, cs, dpi);

            global.state = .{
                .hwnd = hwnd,
                .tabs = .empty,
                .active_tab_index = 0,
            };

            TabLifecycle.createTab(tabLifecycleContext(), &global.state.?, cell_count) catch |e| {
                log.err("Failed to create initial tab: {any}", .{e});
                win32.ExitProcess(1);
            };

            global.cursor_phase = 0.0;
            startCursorTimer(hwnd);

            return 0;
        },
        win32.WM_CLOSE => {
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            if (global.state) |*state| TabLifecycle.closeAllTabs(tabLifecycleContext(), state);
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);

            const tab_idx = getTabAtMouse(hwnd, mouse_x, mouse_y);
            if (tab_idx == -2) {
                const state = stateFromHwnd(hwnd);
                const grid = windowgrid.calcGridSize(win32.getClientSize(hwnd), global.renderer.cell_size, win32.dpiFromHwnd(hwnd));
                TabLifecycle.createTab(tabLifecycleContext(), state, grid) catch |e| log.err("createTab failed: {any}", .{e});
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
                    invalidateWithCells(hwnd);
                }
            } else {
                const state = stateFromHwnd(hwnd);
                const screen = state.activeTab().term.screens.active;
                global.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                const cs = global.renderer.cell_size;
                const pos = mousePosToGrid(mouse_x, mouse_y, cs);
                if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(pos.col), .y = @intCast(pos.row) } })) |pin| {
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
                handleTabDestroyResult(state, TabLifecycle.closeTab(tabLifecycleContext(), state, @intCast(tab_idx)));
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
                    invalidateWithCells(hwnd);
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
                        markCellsDirty();
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
            invalidateWithCells(hwnd);
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
                _ = win32.SetTimer(hwnd, TIMER_TAB_ANIMATION, TAB_ANIMATION_MS, null);
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
                    invalidateWithCells(hwnd);
                },
                .selecting => {
                    const state = stateFromHwnd(hwnd);
                    const screen = state.activeTab().term.screens.active;
                    const cs = global.renderer.cell_size;
                    const clamped_x: i32 = @max(0, @min(mouse_x, grid_w - 1));
                    const clamped_y: i32 = @max(0, @min(mouse_y, client_size.cy - 1));
                    const pos = mousePosToGrid(clamped_x, clamped_y, cs);
                    if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(pos.col), .y = @intCast(pos.row) } })) |pin| {
                        if (screen.selection) |*sel| {
                            sel.endPtr().* = pin;
                            invalidateWithCells(hwnd);
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
            _ = win32.SetTimer(hwnd, TIMER_TAB_ANIMATION, TAB_ANIMATION_MS, null);
            if (global.mouse_in_scrollbar) {
                global.mouse_in_scrollbar = false;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_DISPLAYCHANGE => {
            invalidateWithCells(hwnd);
            return 0;
        },
        win32.WM_SYSCOMMAND => {
            const command = wparam & 0xfff0;
            global.size_policy.onSystemCommand(command);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_ENTERSIZEMOVE => {
            global.resizing = true;
            global.pending_live_resize_grid = null;
            invalidateWithCells(hwnd);
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            global.resizing = false;
            const state = stateFromHwnd(hwnd);
            const grid = global.pending_live_resize_grid orelse currentWindowGrid(hwnd);
            global.pending_live_resize_grid = null;
            const result = TerminalResizer.resizeActiveTab(
                global.term_arena.allocator(),
                state.activeTab(),
                grid,
                true,
            );
            if (result.paint) invalidateWithCells(hwnd) else win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_SIZING => {
            if (!global.resizing) {
                global.resizing = true;
                invalidateWithCells(hwnd);
            }
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = win32.dpiFromHwnd(hwnd);
            const new_rect = windowgrid.calcSnappedWindowRect(dpi, rect.*, wparam, global.renderer.cell_size);
            rect.* = new_rect;
            return 0;
        },
        win32.WM_GETMINMAXINFO => {
            const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;
            const inset = window.getClientInset(dpi);
            const sb_px = TerminalRenderer.scrollbarWidth(dpi);

            const min_client_w = @as(i32, @intCast(windowgrid.MIN_COLS)) * cs.cx + @as(i32, @intCast(sb_px));
            const min_client_h = @as(i32, @intCast(windowgrid.MIN_ROWS)) * cs.cy + windowgrid.Y_PADDING;

            mmi.ptMinTrackSize.x = min_client_w + inset.cx;
            mmi.ptMinTrackSize.y = min_client_h + inset.cy;
            return 0;
        },
        win32.WM_SIZE => {
            const state = stateFromHwnd(hwnd);

            if (global.size_policy.handling_size_message) return 0;
            if (wparam == win32.SIZE_MINIMIZED) {
                global.size_policy.onMinimized();
                return 0;
            }

            global.size_policy.handling_size_message = true;
            defer global.size_policy.handling_size_message = false;

            const lp_usize = @as(usize, @bitCast(lparam));
            const width = @as(u16, @truncate(lp_usize));
            const height = @as(u16, @truncate(lp_usize >> 16));

            const grid = windowgrid.calcGridSize(
                .{ .cx = @as(i32, @intCast(width)), .cy = @as(i32, @intCast(height)) },
                global.renderer.cell_size,
                win32.GetDpiForWindow(hwnd),
            );

            if (global.resizing and
                state.activeTab().term.screens.active_key == .primary)
            {
                // Keep scrollback stable during live drags; apply one PTY resize on WM_EXITSIZEMOVE.
                global.pending_live_resize_grid = grid;
                win32.invalidateHwnd(hwnd);
                return 0;
            }

            const notify_pty = global.size_policy.shouldNotifyPty(state.activeTab(), wparam);
            const result = TerminalResizer.resizeActiveTab(
                global.term_arena.allocator(),
                state.activeTab(),
                grid,
                notify_pty,
            );
            if (result.paint) invalidateWithCells(hwnd);

            return 0;
        },
        win32.WM_PAINT => {
            _, var ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const state = stateFromHwnd(hwnd);
            if (!TerminalResizer.shouldPaint(state.activeTab())) return 0;

            const cursor_alpha = Config.calculateCursorAlpha(global.cursor_phase, global.config);

            const tab_count: u32 = @intCast(state.tabCount());
            const visible_active_idx = state.visibleIndexOf(state.active_tab_index) orelse 0;

            var visible_hover_idx: i32 = -1;
            if (global.tab_hover_index >= 0) {
                visible_hover_idx = if (state.visibleIndexOf(@intCast(global.tab_hover_index))) |idx|
                    @intCast(idx)
                else
                    -1;
            } else if (global.tab_hover_index == -2) {
                visible_hover_idx = @intCast(tab_count);
            }

            const rebuild_cells = global.cell_buffer_dirty or
                global.resizing or
                global.selection_fade > 0 or
                global.mouse_capture == .selecting;
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
                &global.tab_expansions,
                rebuild_cells,
            );
            global.cell_buffer_dirty = false;
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;

            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, @intCast(TerminalRenderer.scrollbarWidth(current_dpi)));
            const col_count = @min(windowgrid.MAX_COLS, @max(windowgrid.MIN_COLS, @divTrunc(grid_w, cs.cx)));
            const row_count = @min(windowgrid.MAX_ROWS, @max(windowgrid.MIN_ROWS, @divTrunc(client_size.cy - windowgrid.Y_PADDING, cs.cy)));

            const new_cs = global.renderer.cellSizeForDpi(new_dpi);
            const new_client_w = col_count * new_cs.cx + @as(i32, @intCast(TerminalRenderer.scrollbarWidth(new_dpi)));
            const new_client_h = row_count * new_cs.cy + windowgrid.Y_PADDING;
            const new_inset = window.getClientInset(new_dpi);
            inout_size.* = .{
                .cx = new_client_w + new_inset.cx,
                .cy = new_client_h + new_inset.cy,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            global.size_policy.onDpiChanged();
            const dpi = win32.hiword(wparam);
            global.renderer.updateDpi(dpi);
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            invalidateWithCells(hwnd);
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
                invalidateWithCells(hwnd);
            }

            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                invalidateWithCells(hwnd);
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
                invalidateWithCells(hwnd);
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
                invalidateWithCells(hwnd);
            } else if (wparam == TIMER_CURSOR) {
                if (!cursorAnimationEnabled()) {
                    _ = win32.KillTimer(hwnd, TIMER_CURSOR);
                    return 0;
                }
                global.cursor_phase += CURSOR_TIMER_MS;
                const total_ms = @as(f32, @floatFromInt(global.config.cursor.fade_in + global.config.cursor.fade_out));
                if (total_ms > 0 and global.cursor_phase >= total_ms) global.cursor_phase -= total_ms;
                win32.invalidateHwnd(hwnd);
            } else if (wparam == TIMER_PTY_PAINT) {
                global.pty_paint_pending = false;
                _ = win32.KillTimer(hwnd, TIMER_PTY_PAINT);
                win32.invalidateHwnd(hwnd);
            } else if (wparam == TIMER_TAB_ANIMATION) {
                const state = stateFromHwnd(hwnd);
                const tab_count: u32 = @intCast(state.tabCount());
                var visible_hover_idx: i32 = -1;
                if (global.tab_hover_index >= 0) {
                    if (state.visibleIndexOf(@intCast(global.tab_hover_index))) |idx| {
                        visible_hover_idx = @intCast(idx);
                    }
                } else if (global.tab_hover_index == -2) {
                    visible_hover_idx = @intCast(tab_count);
                }

                var any_animating = false;
                for (0..tab_count + 1) |i| {
                    if (i >= 100) break;
                    const target: f32 = if (@as(i32, @intCast(i)) == visible_hover_idx) 1.0 else 0.0;
                    const expansion = &global.tab_expansions[i];
                    if (expansion.* != target) {
                        const step: f32 = 0.15;
                        if (expansion.* < target) {
                            expansion.* = @min(expansion.* + step, target);
                        } else {
                            expansion.* = @max(expansion.* - step, target);
                        }
                        any_animating = true;
                    }
                }
                if (!any_animating) {
                    _ = win32.KillTimer(hwnd, TIMER_TAB_ANIMATION);
                }
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },

        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub fn onWmQuit(wparam: win32.WPARAM) noreturn {
    win32.ExitProcess(@intCast(wparam));
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
    clipboard.pasteFromClipboard(hwnd, &child_pty.write) catch |e| log.err("paste failed: {any}", .{e});
}
