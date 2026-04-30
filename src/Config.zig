const std = @import("std");

pub const Config = struct {
    font_size: f32 = 14.0,
    font_names: [][]const u8,
    foreground: []const u8 = "0xc8c4d0",
    background: []const u8 = "0x140f1a",
    cursor: []const u8 = "0xffffff",
    opacity: f32 = 0.94,

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
                    \\  "opacity": 0.94
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

        // Copy everything out of the parsed arena into our allocator
        var result = parsed.value;
        result.foreground = try allocator.dupe(u8, parsed.value.foreground);
        result.background = try allocator.dupe(u8, parsed.value.background);
        result.cursor = try allocator.dupe(u8, parsed.value.cursor);
        
        const names = try allocator.alloc([]const u8, parsed.value.font_names.len);
        for (parsed.value.font_names, 0..) |name, i| {
            names[i] = try allocator.dupe(u8, name);
        }
        result.font_names = names;

        return result;
    }

    pub fn parseColor(hex: []const u8) u24 {
        var start: usize = 0;
        if (std.mem.startsWith(u8, hex, "0x")) {
            start = 2;
        } else if (std.mem.startsWith(u8, hex, "#")) {
            start = 1;
        }
        if (hex.len <= start) return 0;
        return std.fmt.parseInt(u24, hex[start..], 16) catch 0;
    }
};
