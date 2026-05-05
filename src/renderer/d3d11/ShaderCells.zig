const std = @import("std");
const win32 = @import("win32").everything;
const types = @import("types.zig");

pub const ShaderCells = struct {
    count: u32 = 0,
    cell_buf: *win32.ID3D11Buffer = undefined,
    cell_view: *win32.ID3D11ShaderResourceView = undefined,

    pub fn updateCount(self: *ShaderCells, device: *win32.ID3D11Device, count: u32) !void {
        if (count == self.count) return;
        self.release();
        if (count > 0) {
            const buf_desc: win32.D3D11_BUFFER_DESC = .{
                .ByteWidth = count * @sizeOf(types.Cell),
                .Usage = .DYNAMIC,
                .BindFlags = .{ .SHADER_RESOURCE = 1 },
                .CPUAccessFlags = .{ .WRITE = 1 },
                .MiscFlags = .{ .BUFFER_STRUCTURED = 1 },
                .StructureByteStride = @sizeOf(types.Cell),
            };
            const hr = device.CreateBuffer(&buf_desc, null, &self.cell_buf);
            if (hr < 0) return error.CreateCellBufferFailed;

            const view_desc: win32.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
                .Format = .UNKNOWN,
                .ViewDimension = ._SRV_DIMENSION_BUFFER,
                .Anonymous = .{
                    .Buffer = .{
                        .Anonymous1 = .{ .FirstElement = 0 },
                        .Anonymous2 = .{ .NumElements = count },
                    },
                },
            };
            const hr2 = device.CreateShaderResourceView(
                &self.cell_buf.ID3D11Resource,
                &view_desc,
                &self.cell_view,
            );
            if (hr2 < 0) return error.CreateCellViewFailed;
        }
        self.count = count;
    }

    pub fn release(self: *ShaderCells) void {
        if (self.count != 0) {
            _ = self.cell_view.IUnknown.Release();
            _ = self.cell_buf.IUnknown.Release();
            self.count = 0;
        }
    }
};
