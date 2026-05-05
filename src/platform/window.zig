const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../config/Config.zig").Config;
const AppState = @import("../app/AppState.zig");

const log = std.log.scoped(.window);

pub const window_style = win32.WS_OVERLAPPEDWINDOW;
pub const window_style_ex = win32.WINDOW_EX_STYLE{ .NOREDIRECTIONBITMAP = 1 };

pub fn updateWindowTitle(hwnd: win32.HWND, title: []const u8, allocator: std.mem.Allocator) void {
    var sanitized: std.ArrayListUnmanaged(u8) = .empty;
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

pub fn rgbToColorRef(rgb: u24) u32 {
    const r = (rgb >> 16) & 0xFF;
    const g = (rgb >> 8) & 0xFF;
    const b = rgb & 0xFF;
    return (b << 16) | (g << 8) | r;
}

pub fn applyWindowTheme(hwnd: win32.HWND, config: Config) void {
    const dark_value: c_int = 1;
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_value, @sizeOf(@TypeOf(dark_value)));

    const bg_rgb = Config.parseColor(config.background) catch 0x140f1a;
    const caption_color = rgbToColorRef(bg_rgb);
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_CAPTION_COLOR, &caption_color, @sizeOf(@TypeOf(caption_color)));

    const fg_rgb = Config.parseColor(config.foreground) catch 0xc8c4d0;
    const text_color = rgbToColorRef(fg_rgb);
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_TEXT_COLOR, &text_color, @sizeOf(@TypeOf(text_color)));

    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_BORDER_COLOR, &caption_color, @sizeOf(@TypeOf(caption_color)));

    const margins = win32.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 0 };
    _ = win32.DwmExtendFrameIntoClientArea(hwnd, &margins);
}

pub fn toggleFullscreen(hwnd: win32.HWND, state: *AppState.State) void {
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
            _ = win32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, .{ .NOOWNERZORDER = 1, .DRAWFRAME = 1 });
        }
    } else {
        _ = win32.SetWindowLongW(hwnd, win32.GWL_STYLE, style | overlapped_window_style);
        _ = win32.SetWindowPlacement(hwnd, &state.previous_placement);
        _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1, .NOZORDER = 1, .NOOWNERZORDER = 1, .DRAWFRAME = 1 });
    }
}

pub fn getClientInset(dpi: u32) win32.SIZE {
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
