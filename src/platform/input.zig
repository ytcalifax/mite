const std = @import("std");
const win32 = @import("win32").everything;

pub const KeyMapping = struct {
    vk: u16,
    seq: []const u8,
    app: ?[]const u8 = null,
};

pub const key_mappings = [_]KeyMapping{
    .{ .vk = @intFromEnum(win32.VK_BACK), .seq = "\x7f" },
    .{ .vk = @intFromEnum(win32.VK_UP), .seq = "\x1b[A", .app = "\x1bOA" },
    .{ .vk = @intFromEnum(win32.VK_DOWN), .seq = "\x1b[B", .app = "\x1bOB" },
    .{ .vk = @intFromEnum(win32.VK_RIGHT), .seq = "\x1b[C", .app = "\x1bOC" },
    .{ .vk = @intFromEnum(win32.VK_LEFT), .seq = "\x1b[D", .app = "\x1bOD" },
    .{ .vk = @intFromEnum(win32.VK_HOME), .seq = "\x1b[H", .app = "\x1bOH" },
    .{ .vk = @intFromEnum(win32.VK_END), .seq = "\x1b[F", .app = "\x1bOF" },
    .{ .vk = @intFromEnum(win32.VK_INSERT), .seq = "\x1b[2~" },
    .{ .vk = @intFromEnum(win32.VK_DELETE), .seq = "\x1b[3~" },
    .{ .vk = @intFromEnum(win32.VK_PRIOR), .seq = "\x1b[5~" },
    .{ .vk = @intFromEnum(win32.VK_NEXT), .seq = "\x1b[6~" },
    .{ .vk = @intFromEnum(win32.VK_F1), .seq = "\x1bOP" },
    .{ .vk = @intFromEnum(win32.VK_F2), .seq = "\x1bOQ" },
    .{ .vk = @intFromEnum(win32.VK_F3), .seq = "\x1bOR" },
    .{ .vk = @intFromEnum(win32.VK_F4), .seq = "\x1bOS" },
    .{ .vk = @intFromEnum(win32.VK_F5), .seq = "\x1b[15~" },
    .{ .vk = @intFromEnum(win32.VK_F6), .seq = "\x1b[17~" },
    .{ .vk = @intFromEnum(win32.VK_F7), .seq = "\x1b[18~" },
    .{ .vk = @intFromEnum(win32.VK_F8), .seq = "\x1b[19~" },
    .{ .vk = @intFromEnum(win32.VK_F9), .seq = "\x1b[20~" },
    .{ .vk = @intFromEnum(win32.VK_F10), .seq = "\x1b[21~" },
    .{ .vk = @intFromEnum(win32.VK_F12), .seq = "\x1b[24~" },
};

pub const ShortcutMapping = struct {
    vk: u16,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    action: enum { paste, fullscreen },
};

pub const shortcut_mappings = [_]ShortcutMapping{
    .{ .vk = @intFromEnum(win32.VK_V), .ctrl = true, .shift = true, .action = .paste },
    .{ .vk = @intFromEnum(win32.VK_INSERT), .shift = true, .action = .paste },
    .{ .vk = @intFromEnum(win32.VK_F11), .action = .fullscreen },
};

pub fn translateKey(wparam: win32.WPARAM, app_cursor: bool, buf: []u8) ?[]const u8 {
    const vk: u16 = @intCast(wparam);

    var modifier: u8 = 1;
    if (win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0) modifier += 1;
    if (win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0) modifier += 2;
    if (win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0) modifier += 4;

    for (key_mappings) |m| {
        if (m.vk == vk) {
            if (modifier > 1) {
                if (m.seq.len >= 3 and m.seq[0] == '\x1b' and m.seq[1] == '[') {
                    const last = m.seq[m.seq.len - 1];
                    if (last == '~') {
                        const code = m.seq[2 .. m.seq.len - 1];
                        return std.fmt.bufPrint(buf, "\x1b[{s};{d}~", .{ code, modifier }) catch null;
                    } else {
                        return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ modifier, last }) catch null;
                    }
                }
            }

            if (app_cursor) {
                return m.app orelse m.seq;
            }
            return m.seq;
        }
    }
    return null;
}
