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

    pub fn ensureCaretVisible(self: *Viewport, caret: TextPos, max_line: usize, max_col: usize) void {
        // adjust the viewport so the caret always remains visible
        if (self.height == 0 or self.width == 0) return;
        if (caret.line < self.top_line) {
            self.top_line = caret.line;
        }
        if (caret.line >= self.top_line + self.height) {
            self.top_line = caret.line - self.height + 1;
        }
        if (caret.col < self.left_col) {
            self.left_col = caret.col;
        }
        if (caret.col >= self.left_col + self.width) {
            self.left_col = caret.col - self.width + 1;
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

    pub fn clampVert(self: *Viewport, line_count: usize) void {
        // allows a caller to clamp vertical scrolling
        if (line_count == 0) {
            self.top_line = 0;
            return;
        }
        if (self.height == 0) {
            self.top_line = if (self.top_line >= line_count) line_count - 1 else self.top_line;
            return;
        }
        const max_top = if (self.height >= line_count) 0 else line_count - self.height;
        if (self.top_line >= max_top) self.top_line = max_top;
    }

    pub fn clampHorz(self: *Viewport, line_len: usize) void {
        // allows a caller to clamp horizontal scrolling
        if (self.width == 0) {
            self.left_col = 0;
            return;
        }
        const max_left = if (self.width >= line_len) 0 else line_len - self.width;
        if (self.left_col > max_left) self.left_col = max_left;
    }

    pub fn resize(self: *Viewport, new_height: usize, new_width: usize) void {
        self.height = new_height;
        self.width = new_width;
    }
};
