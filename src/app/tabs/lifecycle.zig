const std = @import("std");
const win32 = @import("win32").everything;
const gvt = @import("vt");

const AppState = @import("../state.zig");
const Config = @import("../../config/config.zig").Config;
const VtHandler = @import("../terminal/vthandler.zig");
const pty = @import("../../platform/windows/process/pty.zig");
const windowscommandline = @import("../../platform/windows/process/commandline.zig");

const log = std.log.scoped(.tab_lifecycle);

const max_scrollback_bytes = 512 * 1024 * 1024;

pub const Context = struct {
    gpa: std.mem.Allocator,
    term_allocator: std.mem.Allocator,
    config: *const Config,
    update_title_fn: *const fn (hwnd: win32.HWND, title: []const u8) void,
    pty_message_base: u32,
    pty_message_result: u32,
};

pub const DestroyResult = union(enum) {
    none,
    quit,
    paint,
    activate: usize,
};

pub fn createTab(ctx: Context, state: *AppState.State, grid: pty.GridPos) !void {
    const tab_index = findReusableTabIndex(state) orelse state.tabs.items.len;
    if (tab_index >= 100) return error.TooManyTabs;

    var arena = try ctx.gpa.create(std.heap.ArenaAllocator);
    errdefer ctx.gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();

    const shell_w = shellCommandUtf16(arena.allocator(), ctx.config) catch |err| blk: {
        log.err("failed to build shell command line: {any}", .{err});
        break :blk win32.L("cmd.exe");
    };

    const generation = nextGeneration(state);

    var pty_error: pty.Error = undefined;
    var child_process = pty.ChildProcess.startConPtyWin32(
        &pty_error,
        arena.allocator(),
        null,
        @constCast(shell_w),
        state.hwnd,
        ctx.pty_message_base + @as(u32, @intCast(tab_index)),
        ctx.pty_message_result,
        generation,
        grid,
    ) catch |err| {
        log.err("ChildProcess.startConPtyWin32 failed: {any} - {s}", .{ err, pty_error.what });
        return err;
    };
    errdefer child_process.deinit(true);

    const term = try ctx.term_allocator.create(gvt.Terminal);
    errdefer ctx.term_allocator.destroy(term);
    term.* = try gvt.Terminal.init(ctx.term_allocator, .{
        .cols = grid.col,
        .rows = grid.row,
        .max_scrollback = max_scrollback_bytes,
    });
    errdefer term.deinit(ctx.term_allocator);

    const new_tab: AppState.Tab = .{
        .child_process = child_process,
        .term = term,
        .pty_grid = grid,
        .generation = generation,
        .vt_stream = VtHandler.VtStream(VtHandler.MiteHandler).initAlloc(ctx.gpa, VtHandler.MiteHandler{
            .inner = term.vtHandler(),
            .hwnd = state.hwnd,
            .update_title_fn = ctx.update_title_fn,
        }),
        .title = "Mite",
        .arena = arena,
    };

    if (tab_index < state.tabs.items.len) {
        state.tabs.items[tab_index] = new_tab;
    } else {
        try state.tabs.append(ctx.gpa, new_tab);
    }
    state.active_tab_index = tab_index;
}

pub fn closeTab(ctx: Context, state: *AppState.State, index: usize) DestroyResult {
    return destroyTab(ctx, state, index, true, false);
}

pub fn closeAllTabs(ctx: Context, state: *AppState.State) void {
    var i: usize = 0;
    while (i < state.tabs.items.len) : (i += 1) {
        _ = destroyTab(ctx, state, i, true, true);
    }
}

pub fn handleExitedTab(ctx: Context, state: *AppState.State, index: usize) DestroyResult {
    return destroyTab(ctx, state, index, false, true);
}

fn destroyTab(ctx: Context, state: *AppState.State, index: usize, terminate: bool, allow_empty: bool) DestroyResult {
    if (index >= state.tabs.items.len or state.tabs.items[index] == null) return .none;
    if (!allow_empty and state.tabCount() <= 1) return .none;

    const was_active = state.active_tab_index == index;

    if (state.tabs.items[index]) |*tab| {
        tab.vt_stream.handler.deinit();
        tab.child_process.deinit(terminate);
        tab.arena.deinit();
        ctx.gpa.destroy(tab.arena);
        state.tabs.items[index] = null;
    }

    if (state.tabCount() == 0) return .quit;
    if (!was_active) return .paint;

    return if (replacementTabIndex(state, index)) |replacement|
        .{ .activate = replacement }
    else
        .quit;
}

fn findReusableTabIndex(state: *const AppState.State) ?usize {
    for (state.tabs.items, 0..) |maybe_tab, i| {
        if (maybe_tab == null) return i;
    }
    return null;
}

fn replacementTabIndex(state: *const AppState.State, removed_index: usize) ?usize {
    for (removed_index..state.tabs.items.len) |i| {
        if (state.tabs.items[i] != null) return i;
    }

    var i = removed_index;
    while (i > 0) {
        i -= 1;
        if (state.tabs.items[i] != null) return i;
    }
    return null;
}

fn nextGeneration(state: *AppState.State) u32 {
    const generation = state.next_tab_generation;
    state.next_tab_generation +%= 1;
    if (state.next_tab_generation == 0) state.next_tab_generation = 1;
    return generation;
}

fn shellCommandUtf16(allocator: std.mem.Allocator, config: *const Config) ![*:0]const u16 {
    const command_line = try windowscommandline.make(allocator, config.shell.program, config.shell.args);
    const u16_len = try std.unicode.calcUtf16LeLen(command_line);
    const buf = try allocator.alloc(u16, u16_len + 1);
    const len = try std.unicode.utf8ToUtf16Le(buf, command_line);
    buf[len] = 0;
    return buf[0..len :0].ptr;
}
