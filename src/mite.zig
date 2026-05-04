const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;
const gvt = @import("vt");
const d3d11 = @import("win32/d3d11.zig");
const Config = @import("Config.zig").Config;
const Cmdline = @import("Cmdline.zig");

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

const KeyMapping = struct {
    vk: u16,
    seq: []const u8,
    app: ?[]const u8 = null,
};

const key_mappings = [_]KeyMapping{
    .{ .vk = @intFromEnum(win32.VK_BACK), .seq = "\x7f" },
    .{ .vk = @intFromEnum(win32.VK_UP), .seq = "\x1b[A", .app = "\x1bOA" },
    .{ .vk = @intFromEnum(win32.VK_DOWN), .seq = "\x1b[B", .app = "\x1bOB" },
    .{ .vk = @intFromEnum(win32.VK_RIGHT), .seq = "\x1b[C", .app = "\x1bOC" },
    .{ .vk = @intFromEnum(win32.VK_LEFT), .seq = "\x1b[D", .app = "\x1bOD" },
    .{ .vk = @intFromEnum(win32.VK_HOME), .seq = "\x1b[H", .app = "\x1bOH" },
    .{ .vk = @intFromEnum(win32.VK_END), .seq = "\x1b[F", .app = "\x1bOF" },
    .{ .vk = @intFromEnum(win32.VK_INSERT), .seq = "\x1b[2~" },
    .{ .vk = @intFromEnum(win32.VK_DELETE), .seq = "\x1b[3~" },
    .{ .vk = @intFromEnum(win32.VK_PRIOR), .seq = "\x1b[5~" },
    .{ .vk = @intFromEnum(win32.VK_NEXT), .seq = "\x1b[6~" },
    .{ .vk = @intFromEnum(win32.VK_F1), .seq = "\x1bOP" },
    .{ .vk = @intFromEnum(win32.VK_F2), .seq = "\x1bOQ" },
    .{ .vk = @intFromEnum(win32.VK_F3), .seq = "\x1bOR" },
    .{ .vk = @intFromEnum(win32.VK_F4), .seq = "\x1bOS" },
    .{ .vk = @intFromEnum(win32.VK_F5), .seq = "\x1b[15~" },
    .{ .vk = @intFromEnum(win32.VK_F6), .seq = "\x1b[17~" },
    .{ .vk = @intFromEnum(win32.VK_F7), .seq = "\x1b[18~" },
    .{ .vk = @intFromEnum(win32.VK_F8), .seq = "\x1b[19~" },
    .{ .vk = @intFromEnum(win32.VK_F9), .seq = "\x1b[20~" },
    .{ .vk = @intFromEnum(win32.VK_F10), .seq = "\x1b[21~" },
    .{ .vk = @intFromEnum(win32.VK_F12), .seq = "\x1b[24~" },
};

const ShortcutMapping = struct {
    vk: u16,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    action: enum { paste, fullscreen },
};

const shortcut_mappings = [_]ShortcutMapping{
    .{ .vk = @intFromEnum(win32.VK_V), .ctrl = true, .shift = true, .action = .paste },
    .{ .vk = @intFromEnum(win32.VK_INSERT), .shift = true, .action = .paste },
    .{ .vk = @intFromEnum(win32.VK_F11), .action = .fullscreen },
};

const global = struct {
    var icons: Icons = undefined;
    var renderer: d3d11 = undefined;
    var state: ?State = null;
    var term_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var config: Config = undefined;
    var resizing: bool = false;
    var high_surrogate: ?u16 = null;
    var cursor_phase: f32 = 0.0;
    var mouse_in_scrollbar: bool = false;
    var tracking_mouse: bool = false;
    var mouse_capture: enum { none, scrollbar_drag, selecting } = .none;
    var scrollbar_drag_offset: f32 = 0.0;
    var selection_fade: f32 = 0.0;
};

fn updateWindowTitle(hwnd: win32.HWND, title: []const u8) void {
    const allocator = global.gpa.allocator();

    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(allocator);

    var i: usize = 0;
    while (i < title.len) {
        const char = title[i];
        sanitized.append(allocator, char) catch {
            log.warn("OOM while sanitizing window title", .{});
            break;
        };
        if (char == '\\' or char == '/') {
            if (i == 0 and i + 1 < title.len and title[i + 1] == char) {
                sanitized.append(allocator, char) catch break;
                i += 1;
            }
            while (i + 1 < title.len and title[i + 1] == char) {
                i += 1;
            }
        }
        i += 1;
    }

    const full_title = std.fmt.allocPrint(allocator, "{s} — mite.", .{sanitized.items}) catch return;
    defer allocator.free(full_title);

    const u16_len = std.unicode.calcUtf16LeLen(full_title) catch return;
    const buf = allocator.alloc(u16, u16_len + 1) catch return;
    defer allocator.free(buf);

    const len = std.unicode.utf8ToUtf16Le(buf, full_title) catch return;
    buf[len] = 0;
    _ = win32.SetWindowTextW(hwnd, buf[0..len :0].ptr);
}

const MiteHandler = struct {
    inner: gvt.ReadonlyHandler,
    hwnd: win32.HWND,

    pub fn deinit(self: *MiteHandler) void {
        self.inner.deinit();
    }

    pub fn vt(self: *MiteHandler, comptime action: gvt.StreamAction.Tag, value: gvt.StreamAction.Value(action)) !void {
        if (action == .window_title) {
            updateWindowTitle(self.hwnd, value.title);
        }
        try self.inner.vt(action, value);
    }
};

const VtStream = gvt.Stream(MiteHandler);

const State = struct {
    hwnd: win32.HWND,
    child_process: ChildProcess,
    term: *gvt.Terminal,
    vt_stream: VtStream,
    bounds: ?WindowBounds = null,
    previous_placement: win32.WINDOWPLACEMENT = undefined,

    fn reportError(self: *const State, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "Unknown error";
        _ = win32.MessageBoxA(self.hwnd, msg.ptr, "Mite Error", .{ .ICONERROR = 1 });
    }
};

const Y_PADDING = 2;

const GridPos = struct {
    row: u16,
    col: u16,
};

fn calcGridSize(client_size: win32.SIZE, cs: win32.SIZE, dpi: u32) GridPos {
    const sb_px = d3d11.scrollbarWidth(dpi);
    const grid_w = client_size.cx -| @as(i32, @intCast(sb_px));
    return .{
        .col = @intCast(@min(MAX_COLS, @max(MIN_COLS, @divTrunc(@max(1, grid_w), cs.cx)))),
        .row = @intCast(@min(MAX_ROWS, @max(MIN_ROWS, @divTrunc(@max(1, client_size.cy - Y_PADDING), cs.cy)))),
    };
}

fn stateFromHwnd(hwnd: win32.HWND) *State {
    const s = &global.state.?;
    std.debug.assert(s.hwnd == hwnd);
    return s;
}

const window_style = win32.WS_OVERLAPPEDWINDOW;
const window_style_ex = win32.WINDOW_EX_STYLE{ .NOREDIRECTIONBITMAP = 1 };

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

/// Converts an RGB hex value (0xRRGGBB) to a Win32 COLORREF (0x00BBGGRR)
fn rgbToColorRef(rgb: u24) u32 {
    const r = (rgb >> 16) & 0xFF;
    const g = (rgb >> 8) & 0xFF;
    const b = rgb & 0xFF;
    return (b << 16) | (g << 8) | r;
}

/// Applies the background and foreground colors from Config to the window frame
fn applyWindowTheme(hwnd: win32.HWND, config: Config) void {
    // 1. Enable Immersive Dark Mode
    const dark_value: c_int = 1;
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_value, @sizeOf(@TypeOf(dark_value)));

    // 2. Parse and apply Background Color to Title Bar (Caption)
    const bg_rgb = Config.parseColor(config.background) catch 0x140f1a;
    const caption_color = rgbToColorRef(bg_rgb);
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_CAPTION_COLOR, &caption_color, @sizeOf(@TypeOf(caption_color)));

    // 3. Parse and apply Foreground Color to Title Bar Text
    const fg_rgb = Config.parseColor(config.foreground) catch 0xc8c4d0;
    const text_color = rgbToColorRef(fg_rgb);
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_TEXT_COLOR, &text_color, @sizeOf(@TypeOf(text_color)));

    // 4. (Optional) Match the window border to the background
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_BORDER_COLOR, &caption_color, @sizeOf(@TypeOf(caption_color)));

    // 5. Extend frame to ensure the color transition is seamless
    const margins = win32.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 0 };
    _ = win32.DwmExtendFrameIntoClientArea(hwnd, &margins);
}

fn calcWindowPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: win32.SIZE,
    opt: WindowPlacementOptions,
) WindowPlacement {
    const inset = getClientInset(dpi);
    const sb_px = d3d11.scrollbarWidth(dpi);

    const client_w: i32 = if (opt.columns) |cols|
        @as(i32, @intCast(cols)) * cell_size.cx + @as(i32, @intCast(sb_px))
    else if (opt.width) |w|
        @as(i32, @intCast(w))
    else
        80 * cell_size.cx + @as(i32, @intCast(sb_px));

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

fn calcWindowRect(dpi: u32, rect: win32.RECT, edge: win32.WPARAM, cell_size: win32.SIZE) win32.RECT {
    const inset = getClientInset(dpi);
    const sb_px = d3d11.scrollbarWidth(dpi);

    const win_w = rect.right - rect.left;
    const win_h = rect.bottom - rect.top;
    const client_w = win_w - inset.cx;
    const client_h = win_h - inset.cy;

    const grid_w = client_w -| @as(i32, @intCast(sb_px));
    const col_count = @max(MIN_COLS, @divTrunc(grid_w + @divTrunc(cell_size.cx, 2), cell_size.cx));
    const row_count = @max(MIN_ROWS, @divTrunc(client_h - Y_PADDING + @divTrunc(cell_size.cy, 2), cell_size.cy));

    const snap_client_w = col_count * cell_size.cx + @as(i32, @intCast(sb_px));
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

fn getClientInset(dpi: u32) win32.SIZE {
    var rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.AdjustWindowRectExForDpi(
        &rect,
        window_style,
        0,
        window_style_ex,
        dpi,
    );
    return .{
        .cx = rect.right - rect.left,
        .cy = rect.bottom - rect.top,
    };
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

fn toggleFullscreen(hwnd: win32.HWND) void {
    const state = stateFromHwnd(hwnd);
    const style = win32.GetWindowLongW(hwnd, win32.GWL_STYLE);
    const overlapped_window_style = @as(i32, @bitCast(win32.WS_OVERLAPPEDWINDOW));
    if ((style & overlapped_window_style) != 0) {
        var mi: win32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(win32.MONITORINFO);
        state.previous_placement.length = @sizeOf(win32.WINDOWPLACEMENT);
        if (win32.GetWindowPlacement(hwnd, &state.previous_placement) != 0 and
            win32.GetMonitorInfoW(win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST), &mi) != 0)
        {
            _ = win32.SetWindowLongW(hwnd, win32.GWL_STYLE, style & ~overlapped_window_style);
            _ = win32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                .{ .NOOWNERZORDER = 1, .DRAWFRAME = 1 });
        }
    } else {
        _ = win32.SetWindowLongW(hwnd, win32.GWL_STYLE, style | overlapped_window_style);
        _ = win32.SetWindowPlacement(hwnd, &state.previous_placement);
        _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0,
            .{ .NOMOVE = 1, .NOSIZE = 1, .NOZORDER = 1, .NOOWNERZORDER = 1, .DRAWFRAME = 1 });
    }
}

fn translateKey(wparam: win32.WPARAM, app_cursor: bool, buf: []u8) ?[]const u8 {
    const vk: u16 = @intCast(wparam);

    var modifier: u8 = 1;
    if (win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0) modifier += 1;
    if (win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0) modifier += 2;
    if (win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0) modifier += 4;

    for (key_mappings) |m| {
        if (m.vk == vk) {
            if (modifier > 1) {
                if (m.seq.len >= 3 and m.seq[0] == '\x1b' and m.seq[1] == '[') {
                    const last = m.seq[m.seq.len - 1];
                    if (last == '~') {
                        const code = m.seq[2 .. m.seq.len - 1];
                        return std.fmt.bufPrint(buf, "\x1b[{s};{d}~", .{ code, modifier }) catch null;
                    } else {
                        return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ modifier, last }) catch null;
                    }
                }
            }

            if (app_cursor) {
                return m.app orelse m.seq;
            }
            return m.seq;
        }
    }
    return null;
}

fn handleShortcut(hwnd: win32.HWND, state: *State, wparam: win32.WPARAM) bool {
    const vk: u16 = @intCast(wparam);
    const ctrl = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
    const shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
    const alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0;

    for (shortcut_mappings) |m| {
        if (m.vk == vk and m.ctrl == ctrl and m.shift == shift and m.alt == alt) {
            switch (m.action) {
                .paste => pasteClipboard(hwnd, state),
                .fullscreen => toggleFullscreen(hwnd),
            }
            return true;
        }
    }
    return false;
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CREATE => {
            std.debug.assert(global.state == null);

            const client_size = win32.getClientSize(hwnd);
            const cs = global.renderer.cell_size;
            const dpi = win32.dpiFromHwnd(hwnd);
            const cell_count = calcGridSize(client_size, cs, dpi);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const shell_w = blk: {
                const u16_len = std.unicode.calcUtf16LeLen(global.config.shell) catch |e| {
                    log.err("calcUtf16LeLen: {any}", .{e});
                    break :blk win32.L("cmd.exe");
                };
                const buf = arena.allocator().alloc(u16, u16_len + 1) catch {
                    break :blk win32.L("cmd.exe");
                };
                const len = std.unicode.utf8ToUtf16Le(buf, global.config.shell) catch {
                    break :blk win32.L("cmd.exe");
                };
                buf[len] = 0;
                break :blk buf[0..len :0];
            };

            var err: Error = undefined;
            const child_process = ChildProcess.startConPtyWin32(
                &err,
                arena.allocator(),
                shell_w.ptr,
                null,
                hwnd,
                WM_APP_CHILD_PROCESS_DATA,
                WM_APP_CHILD_PROCESS_DATA_RESULT,
                cell_count,
            ) catch |e| {
                log.err("ChildProcess.startConPtyWin32 failed: {any} - {s}", .{ e, err.what });
                win32.ExitProcess(1);
            };

            const term = std.heap.page_allocator.create(gvt.Terminal) catch {
                log.err("Failed to allocate terminal state", .{});
                win32.ExitProcess(1);
            };
            term.* = gvt.Terminal.init(global.term_arena.allocator(), .{
                .cols = cell_count.col,
                .rows = cell_count.row,
            }) catch |e| {
                log.err("Terminal.init failed: {any}", .{e});
                win32.ExitProcess(1);
            };

            global.state = .{
                .hwnd = hwnd,
                .child_process = child_process,
                .term = term,
                .vt_stream = VtStream.initAlloc(global.gpa.allocator(), MiteHandler{
                    .inner = term.vtHandler(),
                    .hwnd = hwnd,
                }),
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
            const client_size = win32.getClientSize(hwnd);
            const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
            const grid_w = client_size.cx -| @as(i32, @intCast(sb_px));
            if (mouse_x >= grid_w) {
                const state = stateFromHwnd(hwnd);
                const screen = state.term.screens.active;
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
                const screen = state.term.screens.active;
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
                    const screen = state.term.screens.active;
                    if (screen.selection) |sel| {
                        const alloc = global.gpa.allocator();
                        const text = screen.selectionString(alloc, .{ .sel = sel }) catch |e| {
                            log.err("selectionString failed: {any}", .{e});
                            return 0;
                        };
                        defer alloc.free(text);
                        if (text.len > 0) {
                            copyToClipboard(hwnd, text);
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
            const screen = state.term.screens.active;
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
            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, @intCast(d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd))));

            switch (global.mouse_capture) {
                .none => {},
                .scrollbar_drag => {
                    const state = stateFromHwnd(hwnd);
                    const win_h: f32 = @floatFromInt(client_size.cy);
                    const sb = state.term.screens.active.pages.scrollbar();
                    const min_track_height: f32 = 20.0;
                    const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                    scrollbarDragTo(state, @as(f32, @floatFromInt(mouse_y)) - global.scrollbar_drag_offset, win_h, track_height);
                    win32.invalidateHwnd(hwnd);
                },
                .selecting => {
                    const state = stateFromHwnd(hwnd);
                    const screen = state.term.screens.active;
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
            const inset = getClientInset(dpi);
            const sb_px = d3d11.scrollbarWidth(dpi);

            const min_client_w = @as(i32, @intCast(MIN_COLS)) * cs.cx + @as(i32, @intCast(sb_px));
            const min_client_h = @as(i32, @intCast(MIN_ROWS)) * cs.cy + Y_PADDING;

            mmi.ptMinTrackSize.x = min_client_w + inset.cx;
            mmi.ptMinTrackSize.y = min_client_h + inset.cy;
            return 0;
        },
        win32.WM_SIZE => {
            if (wparam == win32.SIZE_MINIMIZED) return 0;

            const state = stateFromHwnd(hwnd);

            const lp_usize = @as(usize, @bitCast(lparam));
            const width = @as(u16, @truncate(lp_usize));
            const height = @as(u16, @truncate(lp_usize >> 16));

            if (width < 10 or height < 10) return 0;

            const client_size = win32.SIZE{
                .cx = @as(i32, @intCast(width)),
                .cy = @as(i32, @intCast(height)),
            };

            const dpi = win32.GetDpiForWindow(hwnd);
            const grid = calcGridSize(client_size, global.renderer.cell_size, dpi);

            state.term.resize(global.term_arena.allocator(), grid.col, grid.row) catch |err| {
                log.err("Failed to resize terminal: {any}", .{err});
            };

            var out_err: Error = undefined;
            state.child_process.resize(&out_err, grid) catch |err| {
                log.err("Failed to resize PTY: {s} ({any})", .{ out_err.what, err });
            };

            return 0;
        },
        win32.WM_PAINT => {
            _, var ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const state = stateFromHwnd(hwnd);
            const cursor_alpha = Config.calculateCursorAlpha(global.cursor_phase, global.config);
            global.renderer.render(hwnd, state.term, global.resizing, global.mouse_in_scrollbar, if (global.mouse_capture == .selecting) 1.0 else global.selection_fade, cursor_alpha);
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;

            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, @intCast(d3d11.scrollbarWidth(current_dpi)));
            const col_count = @min(MAX_COLS, @max(MIN_COLS, @divTrunc(grid_w, cs.cx)));
            const row_count = @min(MAX_ROWS, @max(MIN_ROWS, @divTrunc(client_size.cy - Y_PADDING, cs.cy)));

            const new_cs = global.renderer.cellSizeForDpi(new_dpi);
            const new_client_w = col_count * new_cs.cx + @as(i32, @intCast(d3d11.scrollbarWidth(new_dpi)));
            const new_client_h = row_count * new_cs.cy + Y_PADDING;
            const new_inset = getClientInset(new_dpi);
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

            const pty = state.child_process.pty orelse return 0;
            const screen = state.term.screens.active;

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
            if (translateKey(wparam, state.term.modes.values.cursor_keys, &buf)) |seq| {
                pty.writeFlushAll(seq) catch |e| log.err("write to pty failed: {any}", .{e});
                return 0;
            }

            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_CHAR => {
            const state = stateFromHwnd(hwnd);
            const pty = state.child_process.pty orelse return 0;
            const screen = state.term.screens.active;
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
            pty.writeFlushAll(utf8_buf[0..len]) catch |e| log.err("write to pty failed: {any}", .{e});
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
                    state.term.screens.active.clearSelection();
                }
                win32.invalidateHwnd(hwnd);
            } else if (wparam == TIMER_CURSOR) {
                global.cursor_phase += 16.0;
                const total_ms = @as(f32, @floatFromInt(global.config.cursor_fade_in + global.config.cursor_fade_out));
                if (total_ms > 0 and global.cursor_phase >= total_ms) global.cursor_phase -= total_ms;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        WM_APP_CHILD_PROCESS_DATA => {
            const buffer: [*]const u8 = @ptrFromInt(wparam);
            const len: usize = @bitCast(lparam);
            std.debug.assert(len > 0);
            const state = stateFromHwnd(hwnd);
            state.vt_stream.nextSlice(buffer[0..len]) catch |e| {
                log.err("vt stream failed: {any}", .{e});
            };
            win32.invalidateHwnd(hwnd);
            return WM_APP_CHILD_PROCESS_DATA_RESULT;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

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

const Error = struct {
    what: [:0]const u8,
    code: Code,

    pub fn setZig(self: *Error, what: [:0]const u8, code: anyerror) error{Error} {
        self.* = .{ .what = what, .code = .{ .zig = code } };
        return error.Error;
    }
    pub fn setWin32(self: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
        self.* = .{ .what = what, .code = .{ .win32 = code } };
        return error.Error;
    }
    pub fn setHresult(self: *Error, what: [:0]const u8, code: i32) error{Error} {
        self.* = .{ .what = what, .code = .{ .hresult = code } };
        return error.Error;
    }

    const Code = union(enum) {
        zig: anyerror,
        win32: win32.WIN32_ERROR,
        hresult: win32.HRESULT,
    };
};

const ChildProcess = struct {
    pty: ?Pty,
    read: win32.HANDLE,
    thread: std.Thread,
    job: win32.HANDLE,
    process_handle: win32.HANDLE,

    const Pty = struct {
        write: std.fs.File,
        hpcon: win32.HPCON,
        pub fn deinit(self: *Pty) void {
            win32.ClosePseudoConsole(self.hpcon);
            win32.closeHandle(self.write.handle);
        }
        pub fn writeFlushAll(self: *const Pty, slice: []const u8) !void {
            try self.write.writeAll(slice);
        }
    };

    pub fn startConPtyWin32(
        out_err: *Error,
        allocator: std.mem.Allocator,
        application_name: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        hwnd: win32.HWND,
        hwnd_msg: u32,
        hwnd_msg_result: win32.LRESULT,
        cell_count: GridPos,
    ) error{Error}!ChildProcess {
        var sec_attr: win32.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
            .bInheritHandle = 1,
            .lpSecurityDescriptor = null,
        };

        var pty_read: win32.HANDLE = undefined;
        var our_write: win32.HANDLE = undefined;
        if (0 == win32.CreatePipe(@ptrCast(&pty_read), @ptrCast(&our_write), &sec_attr, 0)) return out_err.setWin32(
            "CreateInputPipe",
            win32.GetLastError(),
        );
        var pty_handles_closed = false;
        defer if (!pty_handles_closed) win32.closeHandle(pty_read);
        errdefer win32.closeHandle(our_write);

        var our_read: win32.HANDLE = undefined;
        var pty_write: win32.HANDLE = undefined;
        if (0 == win32.CreatePipe(@ptrCast(&our_read), @ptrCast(&pty_write), &sec_attr, 0)) return out_err.setWin32(
            "CreateOutputPipe",
            win32.GetLastError(),
        );

        try setInherit(out_err, our_write, false);
        try setInherit(out_err, our_read, false);

        const thread = std.Thread.spawn(
            .{},
            readConsoleThread,
            .{ hwnd, hwnd_msg, hwnd_msg_result, our_read },
        ) catch |e| return out_err.setZig("CreateReadConsoleThread", e);

        var hpcon: win32.HPCON = undefined;
        {
            const hr = win32.CreatePseudoConsole(
                .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
                pty_read,
                pty_write,
                0,
                @ptrCast(&hpcon),
            );
            win32.closeHandle(pty_read);
            win32.closeHandle(pty_write);
            pty_handles_closed = true;
            if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
        }
        errdefer win32.ClosePseudoConsole(hpcon);

        var attr_list_size: usize = undefined;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);

        const attr_list = allocator.alloc(
            u8,
            attr_list_size,
        ) catch return out_err.setZig("AllocProcAttrs", error.OutOfMemory);
        defer allocator.free(attr_list);

        if (0 == win32.InitializeProcThreadAttributeList(
            attr_list.ptr,
            1,
            0,
            &attr_list_size,
        )) return out_err.setWin32("InitProcAttrs", win32.GetLastError());
        defer win32.DeleteProcThreadAttributeList(attr_list.ptr);

        if (0 == win32.UpdateProcThreadAttribute(
            attr_list.ptr,
            0,
            win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpcon,
            @sizeOf(@TypeOf(hpcon)),
            null,
            null,
        )) return out_err.setWin32("UpdateProcThreadAttribute", win32.GetLastError());

        var startup_info = win32.STARTUPINFOEXW{
            .StartupInfo = .{
                .cb = @sizeOf(win32.STARTUPINFOEXW),
                .hStdError = null,
                .hStdOutput = null,
                .hStdInput = null,
                .dwFlags = .{ .USESTDHANDLES = 1 },
                .lpReserved = null,
                .lpDesktop = null,
                .lpTitle = null,
                .dwX = 0,
                .dwY = 0,
                .dwXSize = 0,
                .dwYSize = 0,
                .dwXCountChars = 0,
                .dwYCountChars = 0,
                .dwFillAttribute = 0,
                .wShowWindow = 0,
                .cbReserved2 = 0,
                .lpReserved2 = null,
            },
            .lpAttributeList = attr_list.ptr,
        };

        _ = std.os.windows.kernel32.SetEnvironmentVariableW(win32.L("TERM"), win32.L("xterm-256color"));
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(win32.L("NO_COLOR"), null);
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(win32.L("COLORTERM"), win32.L("truecolor"));

        var process_info: win32.PROCESS_INFORMATION = undefined;
        if (0 == win32.CreateProcessW(
            application_name,
            command_line,
            null,
            null,
            0,
            .{
                .CREATE_SUSPENDED = 1,
                .EXTENDED_STARTUPINFO_PRESENT = 1,
            },
            null,
            null,
            &startup_info.StartupInfo,
            &process_info,
        )) return out_err.setWin32("CreateProcess", win32.GetLastError());
        defer win32.closeHandle(process_info.hThread.?);
        errdefer win32.closeHandle(process_info.hProcess.?);

        const job = win32.CreateJobObjectW(null, null) orelse return out_err.setWin32(
            "CreateJobObject",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(job);

        {
            var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            _ = win32.SetInformationJobObject(
                job,
                win32.JobObjectExtendedLimitInformation,
                &info,
                @sizeOf(@TypeOf(info)),
            );
        }

        _ = win32.AssignProcessToJobObject(job, process_info.hProcess);

        const suspend_count = win32.ResumeThread(process_info.hThread);
        if (suspend_count == -1) return out_err.setWin32("ResumeThread", win32.GetLastError());

        return .{
            .pty = .{
                .write = .{ .handle = our_write },
                .hpcon = hpcon,
            },
            .read = our_read,
            .thread = thread,
            .job = job,
            .process_handle = process_info.hProcess.?,
        };
    }

    pub fn resize(self: *const ChildProcess, out_err: *Error, size: GridPos) error{Error}!void {
        const pty = self.pty orelse return;
        const hr = win32.ResizePseudoConsole(
            pty.hpcon,
            .{ .X = @intCast(size.col), .Y = @intCast(size.row) },
        );
        if (hr < 0) return out_err.setHresult("ResizePseudoConsole", hr);
    }

    fn setInherit(out_err: *Error, handle: win32.HANDLE, enable: bool) error{Error}!void {
        if (0 == win32.SetHandleInformation(
            handle,
            @bitCast(win32.HANDLE_FLAGS{ .INHERIT = 1 }),
            .{ .INHERIT = if (enable) 1 else 0 },
        )) return out_err.setWin32(
            "SetHandleInformation",
            win32.GetLastError(),
        );
    }

    fn readConsoleThread(
        hwnd: win32.HWND,
        hwnd_msg: u32,
        hwnd_msg_result: win32.LRESULT,
        read: win32.HANDLE,
    ) void {
        while (true) {
            var buffer: [4096]u8 = undefined;
            var read_len: u32 = undefined;
            if (0 == win32.ReadFile(
                read,
                &buffer,
                buffer.len,
                &read_len,
                null,
            )) {
                const err = win32.GetLastError();
                if (err == .ERROR_BROKEN_PIPE) break;
                log.err("ReadFile failed: {any}", .{err});
                break;
            }
            if (read_len == 0) break;
            if (hwnd_msg_result != win32.SendMessageW(
                hwnd,
                hwnd_msg,
                @intFromPtr(&buffer),
                read_len,
            )) break;
        }
    }
};

fn scrollbarDragTo(state: *State, track_top: f32, win_h: f32, track_height: f32) void {
    const screen = state.term.screens.active;
    const sb = screen.pages.scrollbar();
    if (sb.total <= sb.len) return;
    const max_offset = sb.total - sb.len;
    const scrollable = win_h - track_height;
    if (scrollable <= 0) return;
    const ratio = std.math.clamp(track_top / scrollable, 0.0, 1.0);
    const target_row: usize = @intFromFloat(ratio * @as(f32, @floatFromInt(max_offset)));
    screen.scroll(.{ .row = target_row });
}

fn globalUnlock(hmem: isize) void {
    win32.SetLastError(.NO_ERROR);
    if (0 == win32.GlobalUnlock(hmem)) {
        const err = win32.GetLastError();
        if (err != .NO_ERROR) log.err("GlobalUnlock failed: {any}", .{err});
    }
}

fn copyToClipboard(hwnd: win32.HWND, utf8: [:0]const u8) void {
    if (win32.OpenClipboard(hwnd) == 0) return;
    defer _ = win32.CloseClipboard();

    if (win32.EmptyClipboard() == 0) return;

    const u16_len = std.unicode.calcUtf16LeLen(utf8) catch return;
    const hmem = win32.GlobalAlloc(.{ .MEM_MOVEABLE = 1 }, (u16_len + 1) * @sizeOf(u16));
    if (hmem == 0) return;
    var hmem_owned = true;
    defer if (hmem_owned) {
        _ = win32.GlobalFree(hmem);
    };

    {
        const ptr: [*]u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse return));
        defer globalUnlock(hmem);
        const len = std.unicode.utf8ToUtf16Le(ptr[0 .. u16_len + 1], utf8) catch |err| {
            log.err("failed to encode clipboard text as UTF-16: {any}", .{err});
            return;
        };
        ptr[len] = 0;
    }

    if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), @ptrFromInt(@as(usize, @bitCast(hmem)))) != null) {
        hmem_owned = false;
    }
}

fn pasteClipboard(hwnd: win32.HWND, state: *State) void {
    const pty = state.child_process.pty orelse return;
    if (win32.OpenClipboard(hwnd) == 0) return;
    defer _ = win32.CloseClipboard();
    const handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse return;
    const hmem: isize = @bitCast(@intFromPtr(handle));
    const mem: [*:0]const u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse return));
    defer globalUnlock(hmem);

    pasteUtf16(state, mem, &pty.write) catch |e| log.err("paste failed: {any}", .{e});
}

fn pasteUtf16(state: *State, utf16: [*:0]const u16, file: *const std.fs.File) !void {
    _ = state;
    var i: usize = 0;
    while (utf16[i] != 0) {
        if (utf16[i] == '\r' and utf16[i + 1] == '\n') {
            i += 1;
            continue;
        }
        const cp: u21 = blk: {
            if (std.unicode.utf16IsHighSurrogate(utf16[i])) {
                const high = utf16[i];
                i += 1;
                if (utf16[i] != 0 and std.unicode.utf16IsLowSurrogate(utf16[i])) {
                    const pair = std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, utf16[i] }) catch high;
                    i += 1;
                    break :blk pair;
                }
                break :blk high;
            }
            const c: u21 = @intCast(utf16[i]);
            i += 1;
            break :blk c;
        };
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        try file.writeAll(utf8_buf[0..len]);
    }
}

pub fn main() !void {
    defer _ = global.gpa.deinit();
    const gpa = global.gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(gpa);
    defer args_arena.deinit();

    var args_it = try std.process.argsWithAllocator(args_arena.allocator());
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
        break :blk Config{ .font_names = names };
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
    global.renderer = try d3d11.init(@max(dpi.x, dpi.y), &global.config);
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
        window_style_ex,
        CLASS_NAME,
        win32.L("Mite"),
        window_style,
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
       applyWindowTheme(hwnd, global.config);
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

        var handles = [1]win32.HANDLE{state.child_process.process_handle};
        const wait_result = win32.MsgWaitForMultipleObjectsEx(1, &handles, win32.INFINITE, win32.QS_ALLINPUT, .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 });
        if (wait_result == 0) win32.ExitProcess(0);

        flushMessages();
    }
}
