const std = @import("std");

const default_config_json =
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
    \\    "style": "pipe",
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
    \\  },
    \\  "tabs": {
    \\    "switcher_location": "top_right"
    \\  }
    \\}
;

pub const CursorStyle = enum {
    block,
    pipe,
};

pub const SwitcherLocation = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

pub const Config = struct {
    font: Font = .{},
    colors: Colors = .{},
    cursor: Cursor = .{},
    shell: Shell = .{},
    window: Window = .{},
    tabs: Tabs = .{},

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

    pub const Tabs = struct {
        switcher_location: SwitcherLocation = .top_right,
    };

    pub fn load(allocator: std.mem.Allocator) !Config {
        const config_path = try configPath(allocator);
        defer allocator.free(config_path);

        const content = content: {
            const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                var new_file = try std.fs.createFileAbsolute(config_path, .{});
                defer new_file.close();
                try new_file.writeAll(default_config_json);
                break :content try allocator.dupe(u8, default_config_json);
            };
            defer file.close();
            break :content try file.readToEndAlloc(allocator, 1024 * 1024);
        };
        defer allocator.free(content);

        var parsed = try std.json.parseFromSlice(Config, allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        return try cloneParsedConfig(allocator, parsed.value);
    }

    fn configPath(allocator: std.mem.Allocator) ![]u8 {
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

        return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" });
    }

    fn cloneParsedConfig(allocator: std.mem.Allocator, parsed: Config) !Config {
        var result = parsed;

        result.colors.foreground = try allocator.dupe(u8, parsed.colors.foreground);
        errdefer allocator.free(result.colors.foreground);
        result.colors.background = try allocator.dupe(u8, parsed.colors.background);
        errdefer allocator.free(result.colors.background);
        result.colors.cursor = try allocator.dupe(u8, parsed.colors.cursor);
        errdefer allocator.free(result.colors.cursor);

        result.shell.program = try allocator.dupe(u8, parsed.shell.program);
        errdefer allocator.free(result.shell.program);
        result.shell.args = try cloneStringList(allocator, parsed.shell.args);
        result.font.names = try cloneStringList(allocator, parsed.font.names);

        return result;
    }

    fn cloneStringList(allocator: std.mem.Allocator, source: []const []const u8) ![][]const u8 {
        const result = try allocator.alloc([]const u8, source.len);
        errdefer allocator.free(result);

        var i: usize = 0;
        errdefer {
            for (result[0..i]) |item| allocator.free(item);
        }
        while (i < source.len) : (i += 1) {
            result[i] = try allocator.dupe(u8, source[i]);
        }
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

test "parseColor accepts supported prefixes" {
    try std.testing.expectEqual(@as(u24, 0x123456), try Config.parseColor("0x123456"));
    try std.testing.expectEqual(@as(u24, 0xabcdef), try Config.parseColor("#abcdef"));
    try std.testing.expectEqual(@as(u24, 0x010203), try Config.parseColor("010203"));
}

test "cursor alpha stays visible when blinking is disabled or duration is zero" {
    try std.testing.expectEqual(@as(f32, 1.0), Config.calculateCursorAlpha(200, .{ .cursor = .{ .blink = false } }));
    try std.testing.expectEqual(@as(f32, 1.0), Config.calculateCursorAlpha(200, .{ .cursor = .{ .fade_in = 0, .fade_out = 0 } }));
}
