const std = @import("std");
const win32 = @import("win32").everything;
const types = @import("types.zig");

pub const GlyphTexture = struct {
    size: ?types.CellXY = null,
    obj: ?*win32.ID3D11Texture2D = null,
    view: ?*win32.ID3D11ShaderResourceView = null,

    pub fn updateSize(self: *GlyphTexture, device: *win32.ID3D11Device, size: types.CellXY) !bool {
        if (self.size) |s| {
            if (s.eql(size)) return true;
            self.release();
        }

        const desc: win32.D3D11_TEXTURE2D_DESC = .{
            .Width = size.x,
            .Height = size.y,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = .A8_UNORM,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = .{ .SHADER_RESOURCE = 1 },
            .CPUAccessFlags = .{},
            .MiscFlags = .{},
        };
        var obj: *win32.ID3D11Texture2D = undefined;
        const hr = device.CreateTexture2D(&desc, null, &obj);
        if (hr < 0) return error.CreateGlyphTextureFailed;
        self.obj = obj;

        var view: *win32.ID3D11ShaderResourceView = undefined;
        const hr2 = device.CreateShaderResourceView(&obj.ID3D11Resource, null, &view);
        if (hr2 < 0) return error.CreateGlyphViewFailed;
        self.view = view;

        self.size = size;
        return false;
    }

    pub fn release(self: *GlyphTexture) void {
        if (self.view) |v| _ = v.IUnknown.Release();
        if (self.obj) |o| _ = o.IUnknown.Release();
        self.view = null;
        self.obj = null;
        self.size = null;
    }
};

pub const StagingTexture = struct {
    pub const Cached = struct {
        size: types.CellXY,
        texture: *win32.ID3D11Texture2D,
        render_target: *win32.ID2D1RenderTarget,
        white_brush: *win32.ID2D1SolidColorBrush,
    };
    cached: ?Cached = null,

    pub fn getOrCreate(
        self: *StagingTexture,
        device: *win32.ID3D11Device,
        d2d_factory: *win32.ID2D1Factory,
        size: types.CellXY,
    ) !*Cached {
        if (self.cached) |*c| {
            if (c.size.eql(size)) return c;
            self.release();
        }

        var texture: *win32.ID3D11Texture2D = undefined;
        {
            const desc: win32.D3D11_TEXTURE2D_DESC = .{
                .Width = size.x,
                .Height = size.y,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = .A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = .DEFAULT,
                .BindFlags = .{ .RENDER_TARGET = 1 },
                .CPUAccessFlags = .{},
                .MiscFlags = .{},
            };
            const hr = device.CreateTexture2D(&desc, null, &texture);
            if (hr < 0) return error.CreateStagingTextureFailed;
        }

        const dxgi_surface = try queryInterface(texture, win32.IDXGISurface);
        defer _ = dxgi_surface.IUnknown.Release();

        var render_target: *win32.ID2D1RenderTarget = undefined;
        {
            const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .A8_UNORM, .alphaMode = .PREMULTIPLIED },
                .dpiX = 0,
                .dpiY = 0,
                .usage = .{},
                .minLevel = .DEFAULT,
            };
            const hr = d2d_factory.CreateDxgiSurfaceRenderTarget(dxgi_surface, &props, &render_target);
            if (hr < 0) return error.CreateDxgiSurfaceRenderTargetFailed;
        }

        // Set pixel unit mode
        const dc = try queryInterface(render_target, win32.ID2D1DeviceContext);
        defer _ = dc.IUnknown.Release();
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);

        var white_brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const hr = render_target.CreateSolidColorBrush(
                &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                null,
                &white_brush,
            );
            if (hr < 0) return error.CreateBrushFailed;
        }

        self.cached = .{
            .size = size,
            .texture = texture,
            .render_target = render_target,
            .white_brush = white_brush,
        };
        return &self.cached.?;
    }

    pub fn release(self: *StagingTexture) void {
        if (self.cached) |*c| {
            _ = c.white_brush.IUnknown.Release();
            _ = c.render_target.IUnknown.Release();
            _ = c.texture.IUnknown.Release();
            self.cached = null;
        }
    }
};

fn queryInterface(obj: anytype, comptime Interface: type) !*Interface {
    const iid_name = comptime blk: {
        const name = @typeName(Interface);
        const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| (i + 1) else 0;
        break :blk "IID_" ++ name[start..];
    };
    const iid = @field(win32, iid_name);
    var iface: *Interface = undefined;
    const hr = obj.IUnknown.QueryInterface(iid, @ptrCast(&iface));
    if (hr < 0) return error.QueryInterfaceFailed;
    return iface;
}
