const Cmdline = @This();

const std = @import("std");

font_path: ?[]const u8 = null,
font_size: f32 = 16.0,

pub const Error = error{
    MissingArgument,
    InvalidArgument,
    UnknownOption,
};

pub fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: mite [options]
        \\
        \\Font Options:
        \\  --ttf <path>              Use TrueType font at <path>
        \\  --font-size <float>       Font size (scaled by DPI, default: 16.0)
        \\
        \\General Options:
        \\  -h, --help                Show this help message
        \\
    );
}

pub fn parse(args: *std.process.ArgIterator) !?Cmdline {
    var result: Cmdline = .{};
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ttf")) {
            result.font_path = args.next() orelse {
                std.log.err("--ttf requires a path argument", .{});
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            const size_str = args.next() orelse {
                std.log.err("--font-size requires an argument", .{});
                return error.MissingArgument;
            };
            result.font_size = std.fmt.parseFloat(f32, size_str) catch {
                std.log.err("invalid --font-size '{s}'", .{size_str});
                return error.InvalidArgument;
            };
            if (result.font_size <= 0) {
                std.log.err("invalid --font-size  '{d}' (must be positive)", .{result.font_size});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return null;
        } else {
            std.log.err("unknown cmdline option '{s}'", .{arg});
            return error.UnknownOption;
        }
    }
    return result;
}
