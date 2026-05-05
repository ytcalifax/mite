const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.clipboard);

fn globalUnlock(hmem: isize) void {
    win32.SetLastError(.NO_ERROR);
    if (0 == win32.GlobalUnlock(hmem)) {
        const err = win32.GetLastError();
        if (err != .NO_ERROR) log.err("GlobalUnlock failed: {any}", .{err});
    }
}

pub fn copyToClipboard(hwnd: win32.HWND, utf8: [:0]const u8) void {
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

pub fn pasteUtf16(utf16: [*:0]const u16, file: *const std.fs.File) !void {
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
