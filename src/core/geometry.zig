const std = @import("std");
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const TextPos = @import("types").TextPos;
const ScreenPos = @import("types").ScreenPos;
const PixelPos = @import("types").PixelPos;
const ClipPos = @import("types").ClipPos;

pub const Geometry = struct {
    cell_w_px: f32,
    cell_h_px: f32,
    pad_x_cells: f32,
    pad_y_cells: f32,

    pub fn mouseToTextPos(self: *Geometry, doc: *Document, vp: *const Viewport, mouse_x: f32, mouse_y: f32) !?TextPos {
        if (vp.height == 0 or vp.width == 0) return null;
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

    pub fn screenPosToPixelPos(self: *Geometry, pos: ScreenPos) PixelPos {
        const x = (self.pad_x_cells + @as(f32, @floatFromInt(pos.col))) * self.cell_w_px;
        const y = (self.pad_y_cells + @as(f32, @floatFromInt(pos.row))) * self.cell_h_px;
        return .{ .x = x, .y = y };
    }
};

pub fn pixelPosToClipPos(pos: PixelPos, app_dims: PixelPos) ClipPos {
    return .{
        .x = (pos.x / app_dims.x) * 2.0 - 1.0,
        .y = 1.0 - (pos.y / app_dims.y) * 2.0,
    };
}

pub fn textPosToScreenPos(tp: TextPos, vp: *const Viewport) ?ScreenPos {
    if (vp.height == 0 or vp.width == 0) return null;
    if (tp.row < vp.top_line or tp.row >= vp.top_line + vp.height) return null;
    if (tp.col < vp.left_col or tp.col >= vp.left_col + vp.width) return null;
    return .{
        .row = tp.row - vp.top_line,
        .col = tp.col - vp.left_col,
    };
}
