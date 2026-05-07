const std = @import("std");

const CommandLine = @import("commandline.zig");

test "make quotes program and arguments for CreateProcess command lines" {
    const allocator = std.testing.allocator;
    const command_line = try CommandLine.make(allocator, "C:\\Program Files\\shell.exe", &.{ "arg with spaces", "quote\"here", "tail\\" });
    defer allocator.free(command_line);

    try std.testing.expectEqualStrings(
        "\"C:\\Program Files\\shell.exe\" \"arg with spaces\" \"quote\\\"here\" \"tail\\\\\"",
        command_line,
    );
}
