const std = @import("std");

pub fn make(allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) ![:0]u8 {
    var command_line: std.ArrayListUnmanaged(u8) = .empty;
    errdefer command_line.deinit(allocator);

    try appendQuotedArg(&command_line, allocator, program);
    for (args) |arg| {
        try command_line.append(allocator, ' ');
        try appendQuotedArg(&command_line, allocator, arg);
    }
    return try command_line.toOwnedSliceSentinel(allocator, 0);
}

fn appendQuotedArg(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, arg: []const u8) !void {
    try list.append(allocator, '"');

    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }

        if (c == '"') {
            try list.appendNTimes(allocator, '\\', backslashes * 2 + 1);
            try list.append(allocator, '"');
        } else {
            try list.appendNTimes(allocator, '\\', backslashes);
            try list.append(allocator, c);
        }
        backslashes = 0;
    }

    try list.appendNTimes(allocator, '\\', backslashes * 2);
    try list.append(allocator, '"');
}

test "make quotes program and arguments for CreateProcess command lines" {
    const allocator = std.testing.allocator;
    const command_line = try make(allocator, "C:\\Program Files\\shell.exe", &.{ "arg with spaces", "quote\"here", "tail\\" });
    defer allocator.free(command_line);

    try std.testing.expectEqualStrings(
        "\"C:\\Program Files\\shell.exe\" \"arg with spaces\" \"quote\\\"here\" \"tail\\\\\"",
        command_line,
    );
}
