const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.d3d_core);

pub fn createDevice() !struct { *win32.ID3D11Device, *win32.ID3D11DeviceContext } {
    const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;
    const hr = win32.D3D11CreateDevice(
        null,
        .HARDWARE,
        null,
        .{ .BGRA_SUPPORT = 1, .SINGLETHREADED = 1 },
        &levels,
        levels.len,
        win32.D3D11_SDK_VERSION,
        &device,
        null,
        &context,
    );
    if (hr < 0) return error.D3D11DeviceCreationFailed;
    log.info("D3D11 device created", .{});
    return .{ device, context };
}

pub fn compileShaderBlob(
    source: []const u8,
    entry: [*:0]const u8,
    target: [*:0]const u8,
) !*win32.ID3DBlob {
    var blob: *win32.ID3DBlob = undefined;
    var error_blob: ?*win32.ID3DBlob = null;
    const hr = win32.D3DCompile(
        source.ptr,
        source.len,
        "terminal.hlsl",
        null,
        null,
        entry,
        target,
        0,
        0,
        @ptrCast(&blob),
        @ptrCast(&error_blob),
    );
    if (error_blob) |err| {
        defer _ = err.IUnknown.Release();
        if (err.GetBufferPointer()) |buf_ptr| {
            const ptr: [*]const u8 = @ptrCast(buf_ptr);
            const str = ptr[0..err.GetBufferSize()];
            log.err("shader error:\n{s}", .{str});
        }
    }
    if (hr < 0) return error.ShaderCompilationFailed;
    return blob;
}
