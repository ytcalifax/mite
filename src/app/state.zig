const std = @import("std");
const win32 = @import("win32").everything;
const gvt = @import("vt");
const pty = @import("../platform/windows/process/pty.zig");
const VtHandler = @import("terminal/vthandler.zig");

pub const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

pub const Tab = struct {
    child_process: pty.ChildProcess,
    term: *gvt.Terminal,
    pty_grid: pty.GridPos,
    deferred_primary_grid: ?pty.GridPos = null,
    pending_alternate_resize_paint: bool = false,
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

    pub fn tabCount(self: *const State) usize {
        var count: usize = 0;
        for (self.tabs.items) |maybe_tab| {
            if (maybe_tab != null) count += 1;
        }
        return count;
    }

    pub fn visibleIndexOf(self: *const State, tab_index: usize) ?u32 {
        var visible_index: u32 = 0;
        for (self.tabs.items, 0..) |maybe_tab, i| {
            if (maybe_tab == null) continue;
            if (i == tab_index) return visible_index;
            visible_index += 1;
        }
        return null;
    }

    pub fn physicalIndexForVisible(self: *const State, visible_index: u32) ?usize {
        var current: u32 = 0;
        for (self.tabs.items, 0..) |maybe_tab, i| {
            if (maybe_tab == null) continue;
            if (current == visible_index) return i;
            current += 1;
        }
        return null;
    }

    pub fn reportError(self: *const State, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "Unknown error";
        _ = win32.MessageBoxA(self.hwnd, msg.ptr, "Mite Error", .{ .ICONERROR = 1 });
    }
};
