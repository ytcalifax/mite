const std = @import("std");
const builtin = @import("builtin");

pub const CursorStyle = enum {
    block,
    pipe,
};

pub const Config = struct {
    font: Font = .{},
    colors: Colors = .{},
    cursor: Cursor = .{},
    shell: Shell = .{},
    window: Window = .{},

    pub const Font = struct {
        size: f32 = 14.0,
        names: [][]const u8 = &.{},
    };

    pub const Colors = struct {
        foreground: []const u8 = "0xc8c4d0",
        background: []const u8 = "0x140f1a",
        cursor: []const u8 = "0xffffff",
    };

    pub const Cursor = struct {
        style: CursorStyle = .block,
        blink: bool = true,
        fade_in: u32 = 400,
        fade_out: u32 = 400,
    };

    pub const Shell = struct {
        program: []const u8 = "cmd.exe",
        args: [][]const u8 = &.{},
    };

    pub const Window = struct {
        opacity: f32 = 0.94,
    };

    pub fn load(allocator: std.mem.Allocator) !Config {
        const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return error.HomeNotFound;
            }
            return err;
        };
        defer allocator.free(home);

        const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "mite" });
        defer allocator.free(config_dir);

        try std.fs.cwd().makePath(config_dir);

        const config_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
        defer allocator.free(config_path);

        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const default_config =
                    \\{
                    \\  "font": {
                    \\    "size": 14.0,
                    \\    "names": ["Consolas 7NF", "Consolas"]
                    \\  },
                    \\  "colors": {
                    \\    "foreground": "0xc8c4d0",
                    \\    "background": "0x140f1a",
                    \\    "cursor": "0xffffff"
                    \\  },
                    \\  "cursor": {
                    \\    "style": "block",
                    \\    "blink": true,
                    \\    "fade_in": 400,
                    \\    "fade_out": 400
                    \\  },
                    \\  "shell": {
                    \\    "program": "cmd.exe",
                    \\    "args": []
                    \\  },
                    \\  "window": {
                    \\    "opacity": 0.94
                    \\  }
                    \\}
                ;
                var new_file = try std.fs.createFileAbsolute(config_path, .{});
                defer new_file.close();
                try new_file.writeAll(default_config);
                return try load(allocator);
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var parsed = try std.json.parseFromSlice(Config, allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var result = parsed.value;

        // Colors
        result.colors.foreground = try allocator.dupe(u8, parsed.value.colors.foreground);
        errdefer allocator.free(result.colors.foreground);
        result.colors.background = try allocator.dupe(u8, parsed.value.colors.background);
        errdefer allocator.free(result.colors.background);
        result.colors.cursor = try allocator.dupe(u8, parsed.value.colors.cursor);
        errdefer allocator.free(result.colors.cursor);

        // Shell
        result.shell.program = try allocator.dupe(u8, parsed.value.shell.program);
        errdefer allocator.free(result.shell.program);

        const args = try allocator.alloc([]const u8, parsed.value.shell.args.len);
        errdefer allocator.free(args);
        var arg_idx: usize = 0;
        errdefer {
            for (0..arg_idx) |j| allocator.free(args[j]);
        }
        while (arg_idx < parsed.value.shell.args.len) : (arg_idx += 1) {
            args[arg_idx] = try allocator.dupe(u8, parsed.value.shell.args[arg_idx]);
        }
        result.shell.args = args;

        // Font names
        const names = try allocator.alloc([]const u8, parsed.value.font.names.len);
        errdefer allocator.free(names);
        var i: usize = 0;
        errdefer {
            for (0..i) |j| allocator.free(names[j]);
        }
        while (i < parsed.value.font.names.len) : (i += 1) {
            names[i] = try allocator.dupe(u8, parsed.value.font.names[i]);
        }
        result.font.names = names;

        return result;
    }

    pub fn parseColor(hex: []const u8) !u24 {
        var start: usize = 0;
        if (std.mem.startsWith(u8, hex, "0x")) {
            start = 2;
        } else if (std.mem.startsWith(u8, hex, "#")) {
            start = 1;
        }
        if (hex.len <= start) return error.InvalidColor;
        return std.fmt.parseInt(u24, hex[start..], 16);
    }

    pub fn calculateCursorAlpha(phase_ms: f32, config: Config) f32 {
        if (!config.cursor.blink) return 1.0;

        const fade_in = @as(f32, @floatFromInt(config.cursor.fade_in));
        const fade_out = @as(f32, @floatFromInt(config.cursor.fade_out));
        const total_ms = fade_in + fade_out;
        if (total_ms <= 0) return 1.0;

        const p = @mod(phase_ms, total_ms);
        if (p < fade_in) {
            const x = p / fade_in;
            return 0.5 * (1.0 - std.math.cos(std.math.pi * x));
        } else {
            const x = (p - fade_in) / fade_out;
            return 0.5 * (1.0 + std.math.cos(std.math.pi * x));
        }
    }
};
