const std = @import("std");
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const Geometry = @import("geometry").Geometry;
const TextPos = @import("types").TextPos;
const ScreenPos = @import("types").ScreenPos;
const Span = @import("types").Span;

pub const Layout = struct {
    first_row: usize,
    width: usize,
    lines: []Span,
    caret: ?ScreenPos,

    pub fn init(arena: std.mem.Allocator, doc: *Document, vp: *const Viewport) error{OutOfMemory}!Layout {
        const bottom_line = vp.top_line + vp.dims.h;
        try doc.revealUpTo(bottom_line);
        const total = doc.lineCount();
        const visible_rows = @min(vp.dims.h, total - vp.top_line);
        var lines = try arena.alloc(Span, visible_rows);
        var i: usize = 0;
        while (i < visible_rows) : (i += 1) {
            const full_line = try doc.lineSpan(vp.top_line + i);
            const len = full_line.len;
            const left = vp.left_col;
            const col_start = if (left > len) len else left;
            const remaining_cols = len - col_start;
            const col_count = @min(vp.dims.w, remaining_cols);
            lines[i] = .{ .start = full_line.start + col_start, .len = col_count };
        }
        return .{ .first_row = vp.top_line, .width = vp.dims.w, .lines = lines, .caret = Geometry.textPosToScreenPos(doc.caret.pos, vp) };
    }
};
