const std = @import("std");
const TextPos = @import("types").TextPos;

pub const LineSpan = struct {
    first: usize,
    count: usize,
};

pub const Viewport = struct {
    top_line: usize,
    left_col: usize,
    height: usize,
    width: usize,

    overscroll: usize = 16,
    caret_margin: usize = 8,

    pub fn ensureCaretVisible(self: *Viewport, caret: TextPos, max_line: usize, max_col: usize) void {
        // adjust the viewport so the caret always remains visible
        if (self.height == 0 or self.width == 0) return;
        // caret may hug top edge
        if (caret.line < self.top_line) {
            self.top_line = caret.line;
        }
        // try to keep bottom some distance from caret
        const bottom_edge = self.top_line + (self.height - 1);
        if (caret.line > bottom_edge - @min(self.caret_margin, bottom_edge)) {
            const base = caret.line + self.caret_margin + 1;
            const top = if (base <= self.height) 0 else base - self.height;
            const max_top = self.maxTop(max_line);
            self.top_line = @min(top, max_top);
        }
        // caret may hug left edge
        if (caret.col < self.left_col) {
            self.left_col = caret.col;
        }
        // try to keep right edge some distance from caret
        const right_edge = self.left_col + (self.width - 1);
        if (caret.col > right_edge - @min(self.caret_margin, right_edge)) {
            const base = caret.col + self.caret_margin + 1;
            const left = if (base <= self.width) 0 else base - self.width;
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

    pub fn resize(self: *Viewport, new_height: usize, new_width: usize) void {
        self.height = new_height;
        self.width = new_width;
    }

    // -------------------- CLAMPING HELPERS --------------------

    fn maxTop(self: *const Viewport, max_line: usize) usize {
        if (self.height == 0) return 0;
        const content = max_line + @min(self.overscroll, self.height - 1);
        return if (content < self.height) 0 else content - self.height;
    }

    fn maxLeft(self: *const Viewport, max_col: usize) usize {
        if (self.width == 0) return 0;
        const content = max_col + @min(self.overscroll, self.width - 1);
        return if (content < self.width) 0 else content - self.width;
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
