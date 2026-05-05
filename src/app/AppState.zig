const std = @import("std");
const win32 = @import("win32").everything;
const gvt = @import("vt");
const pty = @import("../platform/pty.zig");
const VtHandler = @import("VtHandler.zig");

pub const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

pub const State = struct {
    hwnd: win32.HWND,
    child_process: pty.ChildProcess,
    term: *gvt.Terminal,
    vt_stream: VtHandler.VtStream(VtHandler.MiteHandler),
    bounds: ?WindowBounds = null,
    previous_placement: win32.WINDOWPLACEMENT = undefined,

    pub fn reportError(self: *const State, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "Unknown error";
        _ = win32.MessageBoxA(self.hwnd, msg.ptr, "Mite Error", .{ .ICONERROR = 1 });
    }
};
