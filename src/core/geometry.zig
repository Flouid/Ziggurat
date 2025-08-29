const std = @import("std");
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const TextPos = @import("types").TextPos;

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
        var line = vp.top_line + row_offset;
        if (line >= doc.lineCount()) line = doc.lineCount() - 1;
        // clamp col to line length
        const span = try doc.lineSpan(line);
        var col = vp.left_col + col_offset;
        if (col > span.len) col = span.len;
        return .{ .line = line, .col = col };
    }
};
