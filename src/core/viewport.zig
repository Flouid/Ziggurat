const std = @import("std");
const Types = @import("types");

pub const LineSpan = struct {
    first: usize,
    count: usize,
};

pub const Viewport = struct {
    top_line: usize,
    left_col: usize,
    dims: Types.ScreenDims,

    const overscroll: usize = 16;
    const caret_margin: usize = 8;

    pub fn posNearEdge(self: *const Viewport, pos: Types.TextPos, max_line: usize, max_col: usize) bool {
        if (self.dims.h == 0 or self.dims.w == 0) return false;
        // visible edges
        const bottom_edge = self.top_line + self.dims.h - 1;
        const right_edge = self.left_col + self.dims.w - 1;
        // Same band math as ensureCaretVisible
        const top_band_end = self.top_line + caret_margin;
        const bottom_band_start = bottom_edge - @min(caret_margin, bottom_edge);
        const left_band_end = self.left_col + caret_margin;
        const right_band_start = right_edge - @min(caret_margin, right_edge);
        // is there room to scroll, including overscroll
        const can_up = self.top_line > 0;
        const can_down = self.top_line < self.maxTop(max_line);
        const can_left = self.left_col > 0;
        const can_right = self.left_col < self.maxLeft(max_col);
        // Near an edge AND there is room to scroll in that direction
        if (pos.row < top_band_end and can_up) return true;
        if (pos.row > bottom_band_start and can_down) return true;
        if (pos.col < left_band_end and can_left) return true;
        if (pos.col > right_band_start and can_right) return true;
        return false;
    }

    pub fn ensureCaretVisible(self: *Viewport, caret: Types.TextPos, max_line: usize, max_col: usize) void {
        // adjust the viewport so the caret always remains visible
        if (self.dims.h == 0 or self.dims.w == 0) return;
        // caret may hug top edge
        if (caret.row < self.top_line + caret_margin) {
            self.top_line = if (caret.row < caret_margin) 0 else caret.row - caret_margin;
        }
        // try to keep bottom some distance from caret
        const bottom_edge = self.top_line + self.dims.h - 1;
        if (caret.row > bottom_edge - @min(caret_margin, bottom_edge)) {
            const base = caret.row + caret_margin + 1;
            const top = if (base <= self.dims.h) 0 else base - self.dims.h;
            const max_top = self.maxTop(max_line);
            self.top_line = @min(top, max_top);
        }
        // caret may hug left edge
        if (caret.col < self.left_col + caret_margin) {
            self.left_col = if (caret.col < caret_margin) 0 else caret.col - caret_margin;
        }
        // try to keep right edge some distance from caret
        const right_edge = self.left_col + self.dims.w - 1;
        if (caret.col > right_edge - @min(caret_margin, right_edge)) {
            const base = caret.col + caret_margin + 1;
            const left = if (base <= self.dims.w) 0 else base - self.dims.w;
            const max_left = self.maxLeft(max_col);
            self.left_col = @min(left, max_left);
        }
        self.clampVert(max_line);
        self.clampHorz(max_col);
    }

    pub fn scrollBy(self: *Viewport, d_lines: isize, d_cols: isize, max_line: usize, max_col: usize) bool {
        // vertical scrolling
        const old_top = self.top_line;
        if (d_lines < 0) {
            const delta: usize = @intCast(-d_lines);
            self.top_line = if (delta > self.top_line) 0 else self.top_line - delta;
        } else if (d_lines > 0) {
            self.top_line += @intCast(d_lines);
        }
        self.clampVert(max_line);
        const y_scrolled = old_top == self.top_line;
        // horizontal scrolling
        const old_left = self.left_col;
        if (d_cols < 0) {
            const delta: usize = @intCast(-d_cols);
            self.left_col = if (delta > self.left_col) 0 else self.left_col - delta;
        } else if (d_cols > 0) {
            self.left_col += @intCast(d_cols);
        }
        self.clampHorz(max_col);
        const x_scrolled = old_left == self.left_col;
        return (y_scrolled or x_scrolled);
    }

    pub fn resize(self: *Viewport, new_dims: Types.ScreenDims) void {
        self.dims = new_dims;
    }

    // -------------------- CLAMPING HELPERS --------------------

    fn maxTop(self: *const Viewport, max_line: usize) usize {
        if (self.dims.h == 0) return 0;
        const content = max_line + @min(overscroll, self.dims.h - 1);
        return if (content < self.dims.h) 0 else content - self.dims.h;
    }

    fn maxLeft(self: *const Viewport, max_col: usize) usize {
        if (self.dims.w == 0) return 0;
        const content = max_col + @min(overscroll, self.dims.w - 1);
        return if (content < self.dims.w) 0 else content - self.dims.w;
    }

    fn clampVert(self: *Viewport, max_line: usize) void {
        const max_top = self.maxTop(max_line);
        if (self.top_line > max_top) self.top_line = max_top;
    }

    fn clampHorz(self: *Viewport, max_col: usize) void {
        const max_left = self.maxLeft(max_col);
        if (self.left_col > max_left) self.left_col = max_left;
    }
};
