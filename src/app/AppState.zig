const std = @import("std");
const win32 = @import("win32").everything;
const gvt = @import("vt");
const pty = @import("../platform/pty.zig");
const VtHandler = @import("VtHandler.zig");

pub const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

pub const Tab = struct {
    child_process: pty.ChildProcess,
    term: *gvt.Terminal,
    pty_grid: pty.GridPos,
    deferred_primary_grid: ?pty.GridPos = null,
    generation: u32,
    vt_stream: VtHandler.VtStream(VtHandler.MiteHandler),
    title: []const u8,
    arena: *std.heap.ArenaAllocator,
};

pub const State = struct {
    hwnd: win32.HWND,
    tabs: std.ArrayList(?Tab),
    active_tab_index: usize,
    next_tab_generation: u32 = 1,
    bounds: ?WindowBounds = null,
    previous_placement: win32.WINDOWPLACEMENT = undefined,

    pub fn activeTab(self: *State) *Tab {
        return &self.tabs.items[self.active_tab_index].?;
    }

    pub fn reportError(self: *const State, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "Unknown error";
        _ = win32.MessageBoxA(self.hwnd, msg.ptr, "Mite Error", .{ .ICONERROR = 1 });
    }
};
