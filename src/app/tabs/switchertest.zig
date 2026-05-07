const std = @import("std");
const win32 = @import("win32").everything;

const AppState = @import("../state.zig");
const Switcher = @import("switcher.zig");

test "hitTest maps sparse physical tabs to visible tab slots" {
    const allocator = std.testing.allocator;
    var state = AppState.State{
        .hwnd = @ptrFromInt(1),
        .tabs = .empty,
        .active_tab_index = 1,
    };
    defer state.tabs.deinit(allocator);

    try state.tabs.append(allocator, null);
    const tab: AppState.Tab = undefined;
    try state.tabs.append(allocator, tab);
    try state.tabs.append(allocator, null);

    const client_size = win32.SIZE{ .cx = 240, .cy = 120 };

    switch (Switcher.hitTest(&state, client_size, 200, .top_left, 9, 1)) {
        .tab => |index| try std.testing.expectEqual(@as(usize, 1), index),
        else => return error.ExpectedTabHit,
    }

    try std.testing.expectEqual(Switcher.Hit.add_tab, Switcher.hitTest(&state, client_size, 200, .top_left, 33, 1));
    try std.testing.expectEqual(Switcher.Hit.none, Switcher.hitTest(&state, client_size, 200, .top_left, 27, 1));
}

test "bounds supports bottom and right aligned switcher locations" {
    const client_size = win32.SIZE{ .cx = 300, .cy = 100 };
    const b = Switcher.bounds(client_size, 250, 3, .bottom_right);

    try std.testing.expectEqual(@as(f32, 178.0), b.x);
    try std.testing.expectEqual(@as(f32, 70.0), b.y);
    try std.testing.expectEqual(@as(f32, 64.0), b.width);
    try std.testing.expectEqual(@as(f32, 30.0), b.height);
}
