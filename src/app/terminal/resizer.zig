const std = @import("std");
const win32 = @import("win32").everything;
const AppState = @import("../state.zig");
const pty = @import("../../platform/windows/process/pty.zig");

const log = std.log.scoped(.terminal_resizer);

pub const ResizeResult = struct {
    paint: bool,
};

pub const SizePolicy = struct {
    reflow_suppressed: bool = false,
    fullscreen_reflow_suppressed: bool = false,
    suppress_next_restored: bool = false,
    handling_size_message: bool = false,

    pub fn beforeFullscreenToggle(self: *SizePolicy, tab: *const AppState.Tab) void {
        const immediate = needsImmediatePtyResize(tab);
        self.reflow_suppressed = !immediate;
        self.fullscreen_reflow_suppressed = !immediate;
    }

    pub fn afterFullscreenRestore(self: *SizePolicy) void {
        self.fullscreen_reflow_suppressed = false;
        self.reflow_suppressed = false;
    }

    pub fn onSystemCommand(self: *SizePolicy, command: win32.WPARAM) void {
        switch (command) {
            win32.SC_MINIMIZE => self.reflow_suppressed = true,
            else => {},
        }
    }

    pub fn onMinimized(self: *SizePolicy) void {
        self.reflow_suppressed = true;
    }

    pub fn onDpiChanged(self: *SizePolicy) void {
        self.reflow_suppressed = true;
        self.suppress_next_restored = true;
    }

    pub fn shouldNotifyPty(self: *SizePolicy, tab: *const AppState.Tab, size_kind: win32.WPARAM) bool {
        if (needsImmediatePtyResize(tab)) return true;
        if (self.fullscreen_reflow_suppressed) return false;

        switch (size_kind) {
            win32.SIZE_MAXIMIZED => {
                self.reflow_suppressed = false;
                return true;
            },
            win32.SIZE_RESTORED => {
                if (self.suppress_next_restored) {
                    self.suppress_next_restored = false;
                    self.reflow_suppressed = false;
                    return false;
                }
                self.reflow_suppressed = false;
                return true;
            },
            else => return !self.reflow_suppressed,
        }
    }
};

pub fn needsImmediatePtyResize(tab: *const AppState.Tab) bool {
    return tab.term.screens.active_key == .alternate;
}

pub fn shouldPaint(tab: *const AppState.Tab) bool {
    return !tab.pending_alternate_resize_paint;
}

pub fn resizeActiveTab(
    term_allocator: std.mem.Allocator,
    tab: *AppState.Tab,
    grid: pty.GridPos,
    notify_pty: bool,
) ResizeResult {
    const term_same_size = grid.col == tab.term.cols and grid.row == tab.term.rows;
    const pty_same_size = grid.col == tab.pty_grid.col and grid.row == tab.pty_grid.row;
    if (term_same_size and (!notify_pty or pty_same_size)) return .{ .paint = false };

    const defer_paint = tab.term.screens.active_key == .alternate and !term_same_size and notify_pty;

    if (!term_same_size) {
        resizeTerminalForGrid(term_allocator, tab, grid) catch |err| {
            log.err("terminal resize failed: {any}", .{err});
            return .{ .paint = false };
        };
        tab.pending_alternate_resize_paint = defer_paint;
    }

    if (notify_pty and !pty_same_size) {
        var out_err: pty.Error = undefined;
        tab.child_process.resize(&out_err, grid) catch {
            log.err("PTY resize failed: {s}", .{out_err.what});
            tab.pending_alternate_resize_paint = false;
            return .{ .paint = true };
        };
        tab.pty_grid = grid;
    }

    return .{ .paint = !tab.pending_alternate_resize_paint };
}

pub fn afterPtyOutput(term_allocator: std.mem.Allocator, tab: *AppState.Tab) void {
    applyDeferredPrimaryResize(term_allocator, tab);
    if (needsImmediatePtyResize(tab)) syncPtyToTerminalGrid(tab);
    tab.pending_alternate_resize_paint = false;
}

fn resizeTerminalForGrid(term_allocator: std.mem.Allocator, tab: *AppState.Tab, grid: pty.GridPos) !void {
    if (tab.term.screens.active_key == .alternate) {
        tab.deferred_primary_grid = grid;
        try resizeTerminalShell(term_allocator, tab, grid, false);
    } else {
        try resizeTerminalShell(term_allocator, tab, grid, true);
        tab.deferred_primary_grid = null;
    }
}

fn resizeTerminalShell(term_allocator: std.mem.Allocator, tab: *AppState.Tab, grid: pty.GridPos, resize_primary: bool) !void {
    const was_at_bottom = tab.term.screens.active.viewportIsBottom();
    if (was_at_bottom) tab.term.screens.active.scroll(.active);

    if (tab.term.cols != grid.col) {
        tab.term.tabstops.deinit(term_allocator);
        tab.term.tabstops = try @TypeOf(tab.term.tabstops).init(term_allocator, grid.col, 8);
    }

    if (resize_primary) {
        const primary = tab.term.screens.get(.primary).?;
        try primary.resize(.{
            .cols = grid.col,
            .rows = grid.row,
            .reflow = tab.term.modes.get(.wraparound),
            .prompt_redraw = tab.term.flags.shell_redraws_prompt,
        });
    }

    if (tab.term.screens.get(.alternate)) |alt| {
        try alt.resize(.{
            .cols = grid.col,
            .rows = grid.row,
            .reflow = false,
        });
    }

    tab.term.cols = grid.col;
    tab.term.rows = grid.row;
    tab.term.scrolling_region = .{
        .top = 0,
        .bottom = grid.row - 1,
        .left = 0,
        .right = grid.col - 1,
    };
    tab.term.flags.dirty.clear = true;

    if (was_at_bottom) tab.term.screens.active.scroll(.active);
}

fn applyDeferredPrimaryResize(term_allocator: std.mem.Allocator, tab: *AppState.Tab) void {
    _ = term_allocator;
    if (tab.term.screens.active_key != .primary) return;
    const grid = tab.deferred_primary_grid orelse return;
    tab.deferred_primary_grid = null;

    const primary = tab.term.screens.get(.primary).?;
    if (primary.pages.cols == grid.col and primary.pages.rows == grid.row) return;

    const was_at_bottom = primary.viewportIsBottom();
    if (was_at_bottom) primary.scroll(.active);
    primary.resize(.{
        .cols = grid.col,
        .rows = grid.row,
        .reflow = tab.term.modes.get(.wraparound),
        .prompt_redraw = tab.term.flags.shell_redraws_prompt,
    }) catch |err| {
        log.err("deferred primary resize failed: {any}", .{err});
        return;
    };
    if (was_at_bottom) primary.scroll(.active);
}

fn syncPtyToTerminalGrid(tab: *AppState.Tab) void {
    const grid: pty.GridPos = .{
        .col = @intCast(tab.term.cols),
        .row = @intCast(tab.term.rows),
    };
    if (grid.col == tab.pty_grid.col and grid.row == tab.pty_grid.row) return;

    var out_err: pty.Error = undefined;
    tab.child_process.resize(&out_err, grid) catch {
        log.err("PTY resize failed: {s}", .{out_err.what});
        return;
    };
    tab.pty_grid = grid;
}
