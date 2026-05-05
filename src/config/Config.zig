const std = @import("std");
const builtin = @import("builtin");

pub const CursorStyle = enum {
    block,
    pipe,
};

pub const Config = struct {
    font_size: f32 = 14.0,
    font_names: [][]const u8,
    foreground: []const u8 = "0xc8c4d0",
    background: []const u8 = "0x140f1a",
    cursor: []const u8 = "0xffffff",
    cursor_style: CursorStyle = .block,
    cursor_blink: bool = true,
    cursor_fade_in: u32 = 400,
    cursor_fade_out: u32 = 400,
    opacity: f32 = 0.94,
    shell: []const u8 = "C:\\Windows\\System32\\cmd.exe",

    pub fn load(allocator: std.mem.Allocator) !Config {
        const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return error.HomeNotFound;
            }
            return err;
        };
        defer allocator.free(home);

        const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".mite" });
        defer allocator.free(config_dir);

        std.fs.makeDirAbsolute(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const config_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
        defer allocator.free(config_path);

        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const default_config =
                    \\{
                    \\  "font_size": 14.0,
                    \\  "font_names": ["Consolas 7NF", "Consolas"],
                    \\  "foreground": "0xc8c4d0",
                    \\  "background": "0x140f1a",
                    \\  "cursor": "0xffffff",
                    \\  "cursor_style": "block",
                    \\  "cursor_blink": true,
                    \\  "cursor_fade_in": 400,
                    \\  "cursor_fade_out": 400,
                    \\  "opacity": 0.94,
                    \\  "shell": "C:\\\\Windows\\\\System32\\\\cmd.exe"
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
        result.foreground = try allocator.dupe(u8, parsed.value.foreground);
        errdefer allocator.free(result.foreground);
        result.background = try allocator.dupe(u8, parsed.value.background);
        errdefer allocator.free(result.background);
        result.cursor = try allocator.dupe(u8, parsed.value.cursor);
        errdefer allocator.free(result.cursor);
        result.shell = try allocator.dupe(u8, parsed.value.shell);
        errdefer allocator.free(result.shell);

        const names = try allocator.alloc([]const u8, parsed.value.font_names.len);
        errdefer allocator.free(names);
        var i: usize = 0;
        errdefer {
            for (0..i) |j| allocator.free(names[j]);
        }
        while (i < parsed.value.font_names.len) : (i += 1) {
            names[i] = try allocator.dupe(u8, parsed.value.font_names[i]);
        }
        result.font_names = names;

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
        if (!config.cursor_blink) return 1.0;

        const fade_in = @as(f32, @floatFromInt(config.cursor_fade_in));
        const fade_out = @as(f32, @floatFromInt(config.cursor_fade_out));
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
