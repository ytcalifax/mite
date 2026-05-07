const std = @import("std");
const win32 = @import("win32").everything;

const Grid = @import("grid.zig");

test "calcGridSize clamps to supported terminal bounds" {
    const cell_size = win32.SIZE{ .cx = 10, .cy = 20 };

    const minimum = Grid.calcGridSize(.{ .cx = 1, .cy = 1 }, cell_size, 96);
    try std.testing.expectEqual(@as(u16, Grid.MIN_COLS), minimum.col);
    try std.testing.expectEqual(@as(u16, Grid.MIN_ROWS), minimum.row);

    const exact = Grid.calcGridSize(.{ .cx = 414, .cy = 402 }, cell_size, 96);
    try std.testing.expectEqual(@as(u16, 40), exact.col);
    try std.testing.expectEqual(@as(u16, 20), exact.row);

    const maximum = Grid.calcGridSize(.{ .cx = 20_000, .cy = 20_002 }, cell_size, 96);
    try std.testing.expectEqual(@as(u16, Grid.MAX_COLS), maximum.col);
    try std.testing.expectEqual(@as(u16, Grid.MAX_ROWS), maximum.row);
}
