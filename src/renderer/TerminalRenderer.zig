const D3d11Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;
const GlyphCache = @import("glyph/GlyphCache.zig");
const Config = @import("../config/Config.zig").Config;
const TextLayout = @import("TextLayout.zig");
const d3d_core = @import("d3d11/core.zig");
const types = @import("d3d11/types.zig");
const ShaderCells = @import("d3d11/ShaderCells.zig").ShaderCells;
const Texture = @import("d3d11/Texture.zig");

const log = std.log.scoped(.terminal_renderer);

// D3D11 core
device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,

// Shaders
vertex_shader: *win32.ID3D11VertexShader,
pixel_shader: *win32.ID3D11PixelShader,
const_buf: *win32.ID3D11Buffer,

// DirectWrite
dwrite_factory: *win32.IDWriteFactory,
d2d_factory: *win32.ID2D1Factory,
text_format: *win32.IDWriteTextFormat,
dpi: u32,

// DirectComposition
dcomp_device: ?*win32.IDCompositionDevice = null,
dcomp_target: ?*win32.IDCompositionTarget = null,
dcomp_visual: ?*win32.IDCompositionVisual = null,

// Per-window state (lazily initialized)
swap_chain: ?*win32.IDXGISwapChain2 = null,
target_view: ?*win32.ID3D11RenderTargetView = null,
shader_cells: ShaderCells = .{},
glyph_texture: Texture.GlyphTexture = .{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphCache = null,
glyph_cache_cell_size: ?types.CellXY = null,
staging_texture: Texture.StagingTexture = .{},

cell_size: win32.SIZE,
cell_size_xy: types.CellXY,

config: *const Config,

const scrollbar_logical_width: u16 = 14;

pub fn scrollbarWidth(dpi: u32) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(scrollbar_logical_width)) * @as(f32, @floatFromInt(dpi)) / 96.0));
}

pub fn cellSizeForDpi(self: *D3d11Renderer, dpi: u32) win32.SIZE {
    if (dpi == self.dpi) return self.cell_size;
    const text_format = TextLayout.createTextFormat(self.dwrite_factory, dpi, self.config) catch |err| {
        log.err("failed to create text format for dpi {any}: {any}", .{ dpi, err });
        return self.cell_size;
    };
    defer _ = text_format.IUnknown.Release();
    return TextLayout.measureCellSize(self.dwrite_factory, text_format) catch |err| {
        log.err("failed to measure cell size for dpi {any}: {any}", .{ dpi, err });
        return self.cell_size;
    };
}

pub fn init(dpi: u32, config: *const Config) !D3d11Renderer {
    const device, const context = try d3d_core.createDevice();

    // Compile shaders
    const shader_source = @embedFile("../shaders/terminal.hlsl");

    const vs_blob = try d3d_core.compileShaderBlob(shader_source, "VertexMain", "vs_5_0");
    defer _ = vs_blob.IUnknown.Release();
    var vertex_shader: *win32.ID3D11VertexShader = undefined;
    {
        const hr = device.CreateVertexShader(
            @ptrCast(vs_blob.GetBufferPointer()),
            vs_blob.GetBufferSize(),
            null,
            &vertex_shader,
        );
        if (hr < 0) return error.VertexShaderCreationFailed;
    }

    const ps_blob = try d3d_core.compileShaderBlob(shader_source, "PixelMain", "ps_5_0");
    defer _ = ps_blob.IUnknown.Release();
    var pixel_shader: *win32.ID3D11PixelShader = undefined;
    {
        const hr = device.CreatePixelShader(
            @ptrCast(ps_blob.GetBufferPointer()),
            ps_blob.GetBufferSize(),
            null,
            &pixel_shader,
        );
        if (hr < 0) return error.PixelShaderCreationFailed;
    }

    // Constant buffer
    var const_buf: *win32.ID3D11Buffer = undefined;
    {
        const desc: win32.D3D11_BUFFER_DESC = .{
            .ByteWidth = std.mem.alignForward(u32, @sizeOf(types.GridConfig), 16),
            .Usage = .DYNAMIC,
            .BindFlags = .{ .CONSTANT_BUFFER = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{},
            .StructureByteStride = 0,
        };
        const hr = device.CreateBuffer(&desc, null, &const_buf);
        if (hr < 0) return error.ConstantBufferCreationFailed;
    }

    // DirectWrite
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&dwrite_factory),
        );
        if (hr < 0) return error.DWriteFactoryCreationFailed;
    }

    const text_format = try TextLayout.createTextFormat(dwrite_factory, dpi, config);

    const cell_size = try TextLayout.measureCellSize(dwrite_factory, text_format);
    const cell_size_xy: types.CellXY = .{
        .x = @intCast(cell_size.cx),
        .y = @intCast(cell_size.cy),
    };

    // Direct2D factory for glyph rendering
    var d2d_factory: *win32.ID2D1Factory = undefined;
    {
        const hr = win32.D2D1CreateFactory(
            .SINGLE_THREADED,
            win32.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr < 0) return error.D2D1FactoryCreationFailed;
    }

    return .{
        .device = device,
        .context = context,
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .const_buf = const_buf,
        .dwrite_factory = dwrite_factory,
        .d2d_factory = d2d_factory,
        .text_format = text_format,
        .cell_size = .{
            .cx = cell_size_xy.x,
            .cy = cell_size_xy.y,
        },
        .cell_size_xy = cell_size_xy,
        .dpi = dpi,
        .config = config,
    };
}

pub fn updateDpi(self: *D3d11Renderer, dpi: u32) void {
    if (dpi == self.dpi) return;
    _ = self.text_format.IUnknown.Release();
    self.text_format = TextLayout.createTextFormat(self.dwrite_factory, dpi, self.config) catch |err| {
        log.err("failed to create text format for dpi {any}: {any}", .{ dpi, err });
        return;
    };
    self.dpi = dpi;

    const new_cs = TextLayout.measureCellSize(self.dwrite_factory, self.text_format) catch |err| {
        log.err("failed to measure cell size for dpi {any}: {any}", .{ dpi, err });
        return;
    };
    self.cell_size = new_cs;
    self.cell_size_xy = .{
        .x = @intCast(new_cs.cx),
        .y = @intCast(new_cs.cy),
    };

    // Invalidate glyph cache since font size changed.
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
}

pub fn deinit(self: *D3d11Renderer) void {
    self.staging_texture.release();
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_texture.release();
    self.shader_cells.release();

    self.context.ClearState();
    if (self.target_view) |tv| _ = tv.IUnknown.Release();
    self.target_view = null;
    self.context.Flush();

    // Release DComp objects to prevent COM leaks
    if (self.dcomp_visual) |dv| _ = dv.IUnknown.Release();
    if (self.dcomp_target) |dt| _ = dt.IUnknown.Release();
    if (self.dcomp_device) |dd| _ = dd.IUnknown.Release();

    if (self.swap_chain) |sc| _ = sc.IUnknown.Release();
    _ = self.d2d_factory.IUnknown.Release();
    _ = self.text_format.IUnknown.Release();
    _ = self.dwrite_factory.IUnknown.Release();
    _ = self.const_buf.IUnknown.Release();
    _ = self.pixel_shader.IUnknown.Release();
    _ = self.vertex_shader.IUnknown.Release();
    _ = self.context.IUnknown.Release();
    _ = self.device.IUnknown.Release();
    self.* = undefined;
}

pub fn render(
    self: *D3d11Renderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    resizing: bool,
    mouse_in_scrollbar: bool,
    selection_fade: f32,
    cursor_alpha: f32,
) void {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);

    // Lazy swap chain init
    if (self.swap_chain == null) {
        self.swap_chain = self.initSwapChain(hwnd, client_w, client_h) catch |err| {
            log.err("failed to initialize swap chain: {any}", .{err});
            return;
        };
    }
    const swap_chain = self.swap_chain.?;
    if (client_w == 0 or client_h == 0) return;

    // Resize swap chain if needed
    {
        var sc_w: u32 = undefined;
        var sc_h: u32 = undefined;
        const hr = swap_chain.GetSourceSize(&sc_w, &sc_h);
        if (hr < 0) {
            log.err("GetSourceSize failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return;
        }
        if (sc_w != client_w or sc_h != client_h) {
            self.context.ClearState();
            if (self.target_view) |tv| {
                _ = tv.IUnknown.Release();
                self.target_view = null;
            }
            self.context.Flush();
            const rhr = swap_chain.IDXGISwapChain.ResizeBuffers(
                0,
                client_w,
                client_h,
                .UNKNOWN,
                @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT),
            );
            if (rhr < 0) {
                log.err("ResizeBuffers failed, hr=0x{x}", .{@as(u32, @bitCast(rhr))});
                return;
            }
        }
    }

    const cs = self.cell_size_xy;
    const shader_col: u32 = term.cols;
    const shader_row: u32 = term.rows;

    const grid_w: u32 = client_w -| @as(u32, @intCast(scrollbarWidth(win32.dpiFromHwnd(hwnd))));

    const default_fg = Config.parseColor(self.config.foreground) catch 0xc8c4d0;
    const default_bg = Config.parseColor(self.config.background) catch 0x140f1a;
    const cursor_color = Config.parseColor(self.config.cursor) catch 0xffffff;

    const screen = term.screens.active;

    // Update constant buffer
    {
        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = self.context.Map(
            &self.const_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) {
            log.err("MapConstBuffer failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return;
        }
        defer self.context.Unmap(&self.const_buf.ID3D11Resource, 0);
        const grid_config: *types.GridConfig = @ptrCast(@alignCast(mapped.pData));
        grid_config.cell_size[0] = cs.x;
        grid_config.cell_size[1] = cs.y;
        grid_config.col_count = shader_col;
        grid_config.row_count = shader_row;
        grid_config.background = types.Rgba8.fromU24(default_bg, 255);
        grid_config.foreground = types.Rgba8.fromU24(default_fg, 255);
        grid_config.cursor_color = types.Rgba8.fromU24(cursor_color, 255);
        grid_config.opacity = self.config.opacity;
        grid_config.cursor_x = if (screen.viewportIsBottom() and term.modes.get(.cursor_visible)) screen.cursor.x else 0xffff_ffff;
        grid_config.cursor_y = screen.cursor.y;
        grid_config.cursor_alpha = cursor_alpha;
        grid_config.cursor_style = @intFromEnum(self.config.cursor_style);

        // Compute scrollbar geometry in pixels (within the reserved scrollbar area)
        // Only show the thumb when scrolled up or mouse is hovering over the scrollbar
        const sb = screen.pages.scrollbar();
        const show_scrollbar = sb.total > sb.len and (!screen.viewportIsBottom() or mouse_in_scrollbar);
        if (show_scrollbar) {
            const sb_x: f32 = @floatFromInt(grid_w);
            const sb_w: f32 = @floatFromInt(scrollbarWidth(win32.dpiFromHwnd(hwnd)));
            const win_h: f32 = @floatFromInt(client_h);
            const min_track_height: f32 = 20.0;
            const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
            const max_offset = sb.total - sb.len;
            const track_y = @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);

            grid_config.scrollbar_x = sb_x;
            grid_config.scrollbar_width = sb_w;
            grid_config.scrollbar_y = track_y;
            grid_config.scrollbar_height = track_height;
        } else {
            grid_config.scrollbar_x = 0;
            grid_config.scrollbar_width = 0;
            grid_config.scrollbar_y = 0;
            grid_config.scrollbar_height = 0;
        }
    }

    // Build cell buffer from terminal state
    const cell_count = shader_col * shader_row;
    const blank_glyph = self.generateGlyph(.{ .codepoint = ' ', .half = .single });
    const bg_rgba: types.Rgba8 = .{
        .r = @intCast((default_bg >> 16) & 0xFF),
        .g = @intCast((default_bg >> 8) & 0xFF),
        .b = @intCast(default_bg & 0xFF),
        .a = 0,
    };

    self.shader_cells.updateCount(self.device, cell_count) catch |err| {
        log.err("failed to update shader cells: {any}", .{err});
        return;
    };
    if (cell_count > 0) {
        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = self.context.Map(
            &self.shader_cells.cell_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) {
            log.err("MapCellBuffer failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return;
        }
        defer self.context.Unmap(&self.shader_cells.cell_buf.ID3D11Resource, 0);

        const cells_out: [*]types.Cell = @ptrCast(@alignCast(mapped.pData));

        const palette = &term.colors.palette.current;
        var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var screen_row: u32 = 0;
        while (row_it.next()) |row_pin| {
            defer screen_row += 1;
            if (screen_row >= shader_row) break;

            const page = &row_pin.node.data;
            const page_cells = page.getCells(row_pin.rowAndCell().row);
            const dst_row_offset = screen_row * shader_col;

            var col: u32 = 0;
            for (page_cells) |cell| {
                if (col >= shader_col) break;
                if (cell.wide == .spacer_tail) {
                    // Already written by the .wide cell handler
                    continue;
                }

                const raw_cp: u21 = switch (cell.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.content.codepoint,
                    .bg_color_palette, .bg_color_rgb => ' ',
                };
                const codepoint: u21 = if (raw_cp == 0) ' ' else raw_cp;

                var cell_fg: u24 = default_fg;
                var cell_bg: u24 = default_bg;

                if (cell.style_id != 0) {
                    const style = page.styles.get(page.memory, cell.style_id).*;
                    cell_fg = resolveColor(style.fg_color, palette, default_fg);
                    cell_bg = resolveColor(style.bg_color, palette, default_bg);
                    if (style.flags.inverse) {
                        const tmp = cell_fg;
                        cell_fg = cell_bg;
                        cell_bg = tmp;
                    }
                }

                switch (cell.content_tag) {
                    .bg_color_palette => cell_bg = rgbToU24(palette[cell.content.color_palette]),
                    .bg_color_rgb => {
                        const rgb = cell.content.color_rgb;
                        cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
                    },
                    else => {},
                }

                var bg = if (cell_bg == default_bg) bg_rgba else types.Rgba8.fromU24(cell_bg, 255);
                var fg = types.Rgba8.fromU24(cell_fg, 255);

                // Highlight selected cells (with fade)
                if (screen.selection) |sel| {
                    var cell_pin = row_pin;
                    cell_pin.x = @intCast(col);
                    if (sel.contains(screen, cell_pin)) {
                        const orig_bg = bg;
                        var sel_bg = fg;
                        sel_bg.a = 255;
                        var sel_fg = orig_bg;
                        sel_fg.a = 255;
                        bg = lerpRgba8(orig_bg, sel_bg, selection_fade);
                        fg = lerpRgba8(fg, sel_fg, selection_fade);
                    }
                }

                if (cell.wide == .wide) {
                    cells_out[dst_row_offset + col] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = codepoint, .half = .wide_left }),
                        .background = bg,
                        .foreground = fg,
                    };
                    col += 1;
                    if (col < shader_col) {
                        cells_out[dst_row_offset + col] = .{
                            .glyph_index = self.generateGlyph(.{ .codepoint = codepoint, .half = .wide_right }),
                            .background = bg,
                            .foreground = fg,
                        };
                    }
                } else {
                    cells_out[dst_row_offset + col] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = codepoint, .half = .single }),
                        .background = bg,
                        .foreground = fg,
                    };
                }
                col += 1;
            }
            // Fill remaining columns with blanks
            while (col < shader_col) : (col += 1) {
                cells_out[dst_row_offset + col] = .{
                    .glyph_index = blank_glyph,
                    .background = bg_rgba,
                    .foreground = bg_rgba,
                };
            }
        }
        // Fill remaining rows with blanks
        while (screen_row < shader_row) : (screen_row += 1) {
            const dst_row_offset = screen_row * shader_col;
            @memset(cells_out[dst_row_offset..][0..shader_col], types.Cell{
                .glyph_index = blank_glyph,
                .background = bg_rgba,
                .foreground = bg_rgba,
            });
        }

        // Draw resize overlay (e.g. "80x25")
        if (resizing) {
            const overlay_bg = types.Rgba8.fromU24(0x333333, 255);
            const overlay_fg = types.Rgba8.fromU24(0xffffff, 255);

            var text_buf: [20]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "{any}x{any}", .{ term.cols, term.rows }) catch "??x??";

            const text_len: u32 = @intCast(text.len);
            const pad: u32 = 2;
            const box_w = text_len + pad;
            const box_h: u32 = 3;
            const box_x = (shader_col -| box_w) / 2;
            const box_y = (shader_row -| box_h) / 2;

            // Draw background box
            var by: u32 = box_y;
            while (by < box_y + box_h and by < shader_row) : (by += 1) {
                var bx: u32 = box_x;
                while (bx < box_x + box_w and bx < shader_col) : (bx += 1) {
                    cells_out[by * shader_col + bx] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = ' ', .half = .single }),
                        .background = overlay_bg,
                        .foreground = overlay_fg,
                    };
                }
            }

            // Draw text centered
            const tx = box_x + (box_w -| text_len) / 2;
            const ty = box_y + 1;
            if (ty < shader_row) {
                for (text, 0..) |ch, i| {
                    const col = tx + @as(u32, @intCast(i));
                    if (col < shader_col) {
                        cells_out[ty * shader_col + col] = .{
                            .glyph_index = self.generateGlyph(.{ .codepoint = ch, .half = .single }),
                            .background = overlay_bg,
                            .foreground = overlay_fg,
                        };
                    }
                }
            }
        }
    }

    // Create render target view if needed
    if (self.target_view == null) {
        self.target_view = self.createRenderTargetView(swap_chain, client_w, client_h) catch |err| {
            log.err("failed to create render target view: {any}", .{err});
            return;
        };
    }

    // Draw
    {
        var target_views = [_]?*win32.ID3D11RenderTargetView{self.target_view.?};
        self.context.OMSetRenderTargets(target_views.len, &target_views, null);
    }
    // Clear to transparent black for DWM glass compositing
    {
        const clear_color = [4]f32{ 0, 0, 0, 0 };
        self.context.ClearRenderTargetView(self.target_view.?, @ptrCast(&clear_color));
    }
    self.context.PSSetConstantBuffers(0, 1, @ptrCast(@constCast(&self.const_buf)));
    var resources = [_]?*win32.ID3D11ShaderResourceView{
        if (cell_count > 0) self.shader_cells.cell_view else null,
        self.glyph_texture.view,
    };
    self.context.PSSetShaderResources(0, resources.len, &resources);
    self.context.VSSetShader(self.vertex_shader, null, 0);
    self.context.PSSetShader(self.pixel_shader, null, 0);
    self.context.Draw(4, 0);

    {
        const hr = swap_chain.IDXGISwapChain.Present(0, 0);
        if (hr < 0) {
            log.err("Present failed, hr=0x{x}", .{@as(u32, @bitCast(hr))});
        }
    }
}

// --- Glyph generation ---

fn generateGlyph(self: *D3d11Renderer, key: GlyphCache.Key) u32 {
    const cs = self.cell_size_xy;
    const tex_cell_count = getTextureMaxCellCount(cs);
    const tex_total: u32 = @as(u32, tex_cell_count.x) * @as(u32, tex_cell_count.y);

    const tex_pixel: types.CellXY = .{
        .x = tex_cell_count.x * cs.x,
        .y = tex_cell_count.y * cs.y,
    };
    const tex_retained = self.glyph_texture.updateSize(self.device, tex_pixel) catch |err| {
        log.err("failed to update glyph texture size: {any}", .{err});
        return 0;
    };

    const cache_valid = if (self.glyph_cache_cell_size) |s| s.eql(cs) else false;
    self.glyph_cache_cell_size = cs;

    if (!tex_retained or !cache_valid) {
        if (self.glyph_cache) |*c| {
            c.deinit(self.glyph_cache_arena.allocator());
            _ = self.glyph_cache_arena.reset(.retain_capacity);
            self.glyph_cache = null;
        }
    }

    const cache = blk: {
        if (self.glyph_cache) |*c| break :blk c;
        self.glyph_cache = GlyphCache.init(
            self.glyph_cache_arena.allocator(),
            tex_total,
        ) catch |err| {
            log.err("failed to initialize glyph cache: {any}", .{err});
            return 0;
        };
        break :blk &(self.glyph_cache.?);
    };

    switch (cache.reserve(self.glyph_cache_arena.allocator(), key) catch |err| {
        log.err("failed to reserve glyph in cache: {any}", .{err});
        return 0;
    }) {
        .newly_reserved => |reserved| {
            const pos = cellPosFromIndex(reserved.index, tex_cell_count.x);
            const coord: types.CellXY = .{ .x = cs.x * pos.x, .y = cs.y * pos.y };

            // Render glyph to staging texture (2 cells wide to accommodate wide chars).
            const staging_size: types.CellXY = .{ .x = cs.x * 2, .y = cs.y };
            const staging = self.staging_texture.getOrCreate(self.device, self.d2d_factory, staging_size) catch |err| {
                log.err("failed to get staging texture: {any}", .{err});
                return 0;
            };

            const codepoint = key.codepoint;
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 1;

            var utf16_buf: [2]u16 = undefined;
            const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8_buf[0..utf8_len]) catch 0;

            // Measure actual glyph width to scale it to the target cell width.
            // This handles both narrow chars rendered too wide (scale down) and
            // wide chars rendered too narrow (scale up).
            const target_width: f32 = @floatFromInt(
                if (key.half != .single) cs.x * @as(u16, 2) else cs.x,
            );
            var scale_x: f32 = 1.0;
            {
                var text_layout: *win32.IDWriteTextLayout = undefined;
                {
                    const lhr = self.dwrite_factory.CreateTextLayout(
                        @ptrCast(utf16_buf[0..utf16_len].ptr),
                        @intCast(utf16_len),
                        self.text_format,
                        std.math.floatMax(f32),
                        std.math.floatMax(f32),
                        &text_layout,
                    );
                    if (lhr < 0) {
                        log.err("CreateTextLayout failed, hr=0x{x}", .{@as(u32, @bitCast(lhr))});
                        return 0;
                    }
                }
                defer _ = text_layout.IUnknown.Release();

                var metrics: win32.DWRITE_TEXT_METRICS = undefined;
                {
                    const mhr = text_layout.GetMetrics(&metrics);
                    if (mhr < 0) {
                        log.err("GetMetrics failed, hr=0x{x}", .{@as(u32, @bitCast(mhr))});
                        return 0;
                    }
                }
                if (metrics.width > 0) {
                    scale_x = target_width / metrics.width;
                }
            }

            staging.render_target.BeginDraw();
            {
                const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                staging.render_target.Clear(&color);
            }
            // Scale the glyph to fit the target width
            staging.render_target.SetTransform(&.{
                .Anonymous = .{ .Anonymous1 = .{ .m11 = scale_x, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 } },
            });
            staging.render_target.DrawText(
                @ptrCast(utf16_buf[0..utf16_len].ptr),
                @intCast(utf16_len),
                self.text_format,
                &.{
                    .left = 0,
                    .top = 0,
                    .right = target_width / scale_x,
                    .bottom = @floatFromInt(cs.y),
                },
                &staging.white_brush.ID2D1Brush,
                .{},
                .NATURAL,
            );
            // Reset transform to identity
            staging.render_target.SetTransform(&.{
                .Anonymous = .{ .Anonymous1 = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 } },
            });
            var tag1: u64 = undefined;
            var tag2: u64 = undefined;
            _ = staging.render_target.EndDraw(&tag1, &tag2);

            // Copy the appropriate portion from staging to atlas
            const src_left: u32 = if (key.half == .wide_right) cs.x else 0;
            const box: win32.D3D11_BOX = .{
                .left = src_left,
                .top = 0,
                .front = 0,
                .right = src_left + cs.x,
                .bottom = cs.y,
                .back = 1,
            };
            self.context.CopySubresourceRegion(
                &self.glyph_texture.obj.?.ID3D11Resource,
                0,
                coord.x,
                coord.y,
                0,
                &staging.texture.ID3D11Resource,
                0,
                &box,
            );

            return reserved.index;
        },
        .already_reserved => |index| return index,
    }
}

// --- Swap chain ---

fn initSwapChain(self: *D3d11Renderer, hwnd: win32.HWND, width: u32, height: u32) !*win32.IDXGISwapChain2 {
    const dxgi_device = try queryInterface(self.device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();
    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) return error.GetAdapterFailed;
    }
    defer _ = adapter.IUnknown.Release();
    var factory: *win32.IDXGIFactory2 = undefined;
    {
        const hr = adapter.IDXGIObject.GetParent(win32.IID_IDXGIFactory2, @ptrCast(&factory));
        if (hr < 0) return error.GetDxgiFactoryFailed;
    }
    defer _ = factory.IUnknown.Release();

    const swap_chain_flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
    var swap_chain1: *win32.IDXGISwapChain1 = undefined;
    {
        const desc = win32.DXGI_SWAP_CHAIN_DESC1{
            .Width = width,
            .Height = height,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = swap_chain_flags,
        };
        const hr = factory.CreateSwapChainForComposition(
            &self.device.IUnknown,
            &desc,
            null,
            &swap_chain1,
        );
        if (hr < 0) return error.CreateSwapChainFailed;
    }
    defer _ = swap_chain1.IUnknown.Release();

    // DirectComposition: bind swap chain to window
    {
        const hr = win32.DCompositionCreateDevice(dxgi_device, win32.IID_IDCompositionDevice, @ptrCast(&self.dcomp_device));
        if (hr < 0) return error.DCompositionCreateDeviceFailed;
    }
    {
        const hr = self.dcomp_device.?.CreateTargetForHwnd(hwnd, 1, @ptrCast(&self.dcomp_target));
        if (hr < 0) return error.CreateTargetForHwndFailed;
    }
    {
        const hr = self.dcomp_device.?.CreateVisual(@ptrCast(&self.dcomp_visual));
        if (hr < 0) return error.CreateVisualFailed;
    }
    {
        const hr = self.dcomp_visual.?.SetContent(&swap_chain1.IUnknown);
        if (hr < 0) return error.SetContentFailed;
    }
    {
        const hr = self.dcomp_target.?.SetRoot(self.dcomp_visual.?);
        if (hr < 0) return error.SetRootFailed;
    }
    {
        const hr = self.dcomp_device.?.Commit();
        if (hr < 0) return error.DCompCommitFailed;
    }

    var swap_chain2: *win32.IDXGISwapChain2 = undefined;
    {
        const hr = swap_chain1.IUnknown.QueryInterface(win32.IID_IDXGISwapChain2, @ptrCast(&swap_chain2));
        if (hr < 0) return error.QuerySwapChainFailed;
    }
    return swap_chain2;
}

fn createRenderTargetView(
    self: *D3d11Renderer,
    swap_chain: *win32.IDXGISwapChain2,
    width: u32,
    height: u32,
) !*win32.ID3D11RenderTargetView {
    var back_buffer: *win32.ID3D11Texture2D = undefined;
    {
        const hr = swap_chain.IDXGISwapChain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
        if (hr < 0) return error.GetBufferFailed;
    }
    defer _ = back_buffer.IUnknown.Release();

    var target_view: *win32.ID3D11RenderTargetView = undefined;
    {
        const hr = self.device.CreateRenderTargetView(&back_buffer.ID3D11Resource, null, &target_view);
        if (hr < 0) return error.CreateRenderTargetViewFailed;
    }

    var viewport = win32.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(width),
        .Height = @floatFromInt(height),
        .MinDepth = 0.0,
        .MaxDepth = 0.0,
    };
    self.context.RSSetViewports(1, @ptrCast(&viewport));
    self.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

    return target_view;
}

// --- Helpers ---

fn getTextureMaxCellCount(cell_size: types.CellXY) types.CellXY {
    return .{
        .x = @intCast(@divTrunc(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION, cell_size.x)),
        .y = @intCast(@divTrunc(win32.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION, cell_size.y)),
    };
}

fn cellPosFromIndex(index: u32, column_count: u16) types.CellXY {
    return .{
        .x = @intCast(index % column_count),
        .y = @intCast(@divTrunc(index, column_count)),
    };
}

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

fn resolveColor(c: vt.Style.Color, palette: *const vt.color.Palette, default: u24) u24 {
    return switch (c) {
        .none => default,
        .palette => |idx| rgbToU24(palette[idx]),
        .rgb => |rgb| rgbToU24(rgb),
    };
}

fn rgbToU24(rgb: vt.color.RGB) u24 {
    return @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
}

fn lerpRgba8(a: types.Rgba8, b: types.Rgba8, t: f32) types.Rgba8 {
    return .{
        .r = lerpU8(a.r, b.r, t),
        .g = lerpU8(a.g, b.g, t),
        .b = lerpU8(a.b, b.b, t),
        .a = lerpU8(a.a, b.a, t),
    };
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(af + (bf - af) * t);
}
