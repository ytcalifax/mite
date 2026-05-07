const std = @import("std");

const Config = @import("config.zig").Config;

test "parseColor accepts supported prefixes" {
    try std.testing.expectEqual(@as(u24, 0x123456), try Config.parseColor("0x123456"));
    try std.testing.expectEqual(@as(u24, 0xabcdef), try Config.parseColor("#abcdef"));
    try std.testing.expectEqual(@as(u24, 0x010203), try Config.parseColor("010203"));
}

test "cursor alpha stays visible when blinking is disabled or duration is zero" {
    try std.testing.expectEqual(@as(f32, 1.0), Config.calculateCursorAlpha(200, .{ .cursor = .{ .blink = false } }));
    try std.testing.expectEqual(@as(f32, 1.0), Config.calculateCursorAlpha(200, .{ .cursor = .{ .fade_in = 0, .fade_out = 0 } }));
}
