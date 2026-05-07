const win32 = @import("win32").everything;

const cimport = @cImport({
    @cInclude("resourcenames.h");
});

pub const Pair = struct {
    small: win32.HICON,
    large: win32.HICON,
};

pub fn load(dpi_x: u32, dpi_y: u32) Pair {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi_x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi_y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi_x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi_y);

    const small = @as(?win32.HICON, @ptrCast(win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ))) orelse win32.LoadIconW(null, win32.IDI_APPLICATION);
    const large = @as(?win32.HICON, @ptrCast(win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ))) orelse win32.LoadIconW(null, win32.IDI_APPLICATION);

    return .{ .small = small.?, .large = large.? };
}
