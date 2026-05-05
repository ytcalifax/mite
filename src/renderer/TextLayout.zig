const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../config/Config.zig").Config;

const log = std.log.scoped(.text_layout);

pub fn measureCellSize(dwrite_factory: *win32.IDWriteFactory, text_format: *win32.IDWriteTextFormat) !win32.SIZE {
    var text_layout: *win32.IDWriteTextLayout = undefined;
    {
        const hr = dwrite_factory.CreateTextLayout(
            win32.L("\u{2588}"),
            1,
            text_format,
            std.math.floatMax(f32),
            std.math.floatMax(f32),
            &text_layout,
        );
        if (hr < 0) return error.CreateTextLayoutFailed;
    }
    defer _ = text_layout.IUnknown.Release();

    var metrics: win32.DWRITE_TEXT_METRICS = undefined;
    {
        const hr = text_layout.GetMetrics(&metrics);
        if (hr < 0) return error.GetMetricsFailed;
    }
    return .{
        .cx = @intFromFloat(@floor(metrics.width)),
        .cy = @intFromFloat(@floor(metrics.height)),
    };
}

pub fn createTextFormat(dwrite_factory: *win32.IDWriteFactory, dpi: u32, config: *const Config) !*win32.IDWriteTextFormat {
    var text_format: *win32.IDWriteTextFormat = undefined;
    for (config.font_names) |name| {
        const max_u16 = 256;
        var name_u16: [max_u16:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(name_u16[0..max_u16], name) catch continue;
        name_u16[len] = 0;

        const hr = dwrite_factory.CreateTextFormat(
            &name_u16,
            null,
            .NORMAL,
            .NORMAL,
            .NORMAL,
            win32.scaleDpi(f32, config.font_size, dpi),
            win32.L(""),
            &text_format,
        );
        if (hr >= 0) return text_format;
    }

    const hr = dwrite_factory.CreateTextFormat(
        win32.L(""),
        null,
        .NORMAL,
        .NORMAL,
        .NORMAL,
        win32.scaleDpi(f32, config.font_size, dpi),
        win32.L(""),
        &text_format,
    );
    if (hr < 0) return error.CreateTextFormatFailed;
    return text_format;
}
