const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../config/config.zig").Config;
const TerminalRenderer = @import("../renderer/terminal.zig");
const TabLifecycle = @import("tabs/lifecycle.zig");
const Procedure = @import("window/procedure.zig");
const IconResources = @import("../platform/windows/resources/icons.zig");
const window = @import("../platform/windows/window/core.zig");
const windowgrid = @import("../platform/windows/window/grid.zig");

const log = std.log.scoped(.mite);

pub fn run() !void {
    defer _ = Procedure.global.gpa.deinit();
    const gpa = Procedure.global.gpa.allocator();

    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();
    Procedure.global.config = Config.load(config_arena.allocator()) catch |err| blk: {
        log.err("failed to load config: {any}", .{err});
        const names = config_arena.allocator().alloc([]const u8, 2) catch {
            log.err("OOM while allocating fallback font names", .{});
            return;
        };
        names[0] = "Consolas 7NF";
        names[1] = "Consolas";
        break :blk Config{ .font = .{ .names = names } };
    };

    const opt: windowgrid.PlacementOptions = .{
        .columns = 137,
        .rows = 32,
    };

    const maybe_monitor: ?win32.HMONITOR = win32.MonitorFromPoint(.{ .x = 0, .y = 0 }, win32.MONITOR_DEFAULTTOPRIMARY);

    const dpi: XY(u32) = blk: {
        const monitor = maybe_monitor orelse break :blk .{ .x = 96, .y = 96 };
        var d: XY(u32) = undefined;
        if (win32.GetDpiForMonitor(monitor, win32.MDT_EFFECTIVE_DPI, &d.x, &d.y) < 0) break :blk .{ .x = 96, .y = 96 };
        break :blk d;
    };

    Procedure.global.icons = IconResources.load(dpi.x, dpi.y);
    Procedure.global.renderer = try TerminalRenderer.init(@max(dpi.x, dpi.y), &Procedure.global.config);
    defer Procedure.global.renderer.deinit();
    Procedure.global.renderer.prewarmAsciiGlyphs();

    const cell_size = Procedure.global.renderer.cell_size;
    const placement = windowgrid.calcPlacement(maybe_monitor, @max(dpi.x, dpi.y), cell_size, opt);

    const CLASS_NAME = win32.L("MiteWindow");
    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{},
            .lpfnWndProc = Procedure.proc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = Procedure.global.icons.large,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = Procedure.global.icons.small,
        };
        _ = win32.RegisterClassExW(&wc);
    }

    const hwnd = win32.CreateWindowExW(
        window.window_style_ex,
        CLASS_NAME,
        win32.L("Mite"),
        window.window_style,
        placement.pos.x,
        placement.pos.y,
        placement.size.cx,
        placement.size.cy,
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse return error.CreateWindowFailed;

    window.applyWindowTheme(hwnd, Procedure.global.config);

    _ = win32.UpdateWindow(hwnd);
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });
    _ = win32.SetForegroundWindow(hwnd);

    runMessageLoop();
}

fn runMessageLoop() noreturn {
    while (true) {
        const state = blk: {
            while (Procedure.global.state == null) {
                var msg: win32.MSG = undefined;
                const res = win32.GetMessageW(&msg, null, 0, 0);
                if (res <= 0) Procedure.onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            break :blk &Procedure.global.state.?;
        };

        var handles: [100]win32.HANDLE = undefined;
        var tab_indices: [100]usize = undefined;
        var handle_count: u32 = 0;
        for (state.tabs.items, 0..) |maybe_tab, i| {
            if (maybe_tab) |tab| {
                handles[handle_count] = tab.child_process.process_handle;
                tab_indices[handle_count] = i;
                handle_count += 1;
            }
        }

        const wait_result = win32.MsgWaitForMultipleObjectsEx(handle_count, &handles, win32.INFINITE, win32.QS_ALLINPUT, .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 });
        if (wait_result < handle_count) {
            Procedure.handleTabDestroyResult(state, TabLifecycle.handleExitedTab(Procedure.tabLifecycleContext(), state, tab_indices[wait_result]));
        } else if (wait_result == 0xffff_ffff) {
            log.err("MsgWaitForMultipleObjectsEx failed: {any}", .{win32.GetLastError()});
        }

        Procedure.flushMessages();
    }
}

fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
