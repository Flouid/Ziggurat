const std = @import("std");
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const Types = @import("types");

pub const Geometry = struct {
    cell_w_px: f32,
    cell_h_px: f32,
    pad_x_cells: f32,
    pad_y_cells: f32,

    pub fn mouseToTextPos(self: *const Geometry, doc: *Document, vp: *const Viewport, mouse_x: f32, mouse_y: f32) !?Types.TextPos {
        if (vp.dims.h == 0 or vp.dims.w == 0) return null;
        // account for padding
        const x = mouse_x - self.pad_x_cells * self.cell_w_px;
        const y = mouse_y - self.pad_y_cells * self.cell_h_px;
        // convert to col and row, this rounding behavior "feels" pretty right
        const col_offset: usize = if (x < 0) 0 else @intFromFloat(std.math.round(x / self.cell_w_px));
        const row_offset: usize = if (y < 0) 0 else @intFromFloat(@divFloor(y, self.cell_h_px));
        // clamp row to document length
        var row = vp.top_line + row_offset;
        if (row >= doc.lineCount()) row = doc.lineCount() - 1;
        // clamp col to line length
        const span = try doc.lineSpan(row);
        var col = vp.left_col + col_offset;
        if (col > span.len) col = span.len;
        return .{ .row = row, .col = col };
    }

    pub fn screenPosToPixelPos(self: *const Geometry, pos: Types.ScreenPos) Types.PixelPos {
        const x = (self.pad_x_cells + @as(f32, @floatFromInt(pos.col))) * self.cell_w_px;
        const y = (self.pad_y_cells + @as(f32, @floatFromInt(pos.row))) * self.cell_h_px;
        return .{ .x = x, .y = y };
    }

    pub fn appDimsToScreenDims(self: *const Geometry, dims: Types.PixelDims) Types.ScreenDims {
        const avail_w = dims.w - 2.0 * self.pad_x_cells * self.cell_w_px;
        const avail_h = dims.h - 2.0 * self.pad_y_cells * self.cell_h_px;
        const w: usize = if (avail_w <= 0) 0 else @intFromFloat(@floor(avail_w / self.cell_h_px));
        const h: usize = if (avail_h <= 0) 0 else @intFromFloat(@floor(avail_h / self.cell_w_px));
        return .{ .w = w, .h = h };
    }

    pub fn pixelPosToClipPos(pos: Types.PixelPos, dims: Types.PixelDims) Types.ClipPos {
        return .{
            .x = (pos.x / dims.w) * 2.0 - 1.0,
            .y = 1.0 - (pos.y / dims.h) * 2.0,
        };
    }

    pub fn textPosToScreenPos(tp: Types.TextPos, vp: *const Viewport) ?Types.ScreenPos {
        if (vp.dims.h == 0 or vp.dims.w == 0) return null;
        if (tp.row < vp.top_line or tp.row >= vp.top_line + vp.dims.h) return null;
        if (tp.col < vp.left_col or tp.col >= vp.left_col + vp.dims.w) return null;
        return .{
            .row = tp.row - vp.top_line,
            .col = tp.col - vp.left_col,
        };
    }
};

