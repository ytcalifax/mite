const std = @import("std");
const win32 = @import("win32").everything;
const gvt = @import("vt");

const log = std.log.scoped(.vt_handler);

pub const MiteHandler = struct {
    inner: gvt.ReadonlyHandler,
    hwnd: win32.HWND,
    update_title_fn: *const fn (hwnd: win32.HWND, title: []const u8) void,

    pub fn deinit(self: *MiteHandler) void {
        self.inner.deinit();
    }

    pub fn vt(self: *MiteHandler, comptime action: gvt.StreamAction.Tag, value: gvt.StreamAction.Value(action)) !void {
        if (action == .window_title) {
            self.update_title_fn(self.hwnd, value.title);
        }
        try self.inner.vt(action, value);
    }
};

pub fn VtStream(comptime Handler: type) type {
    return gvt.Stream(Handler);
}
