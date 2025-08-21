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

    pub fn ensureCaretVisible(self: *Viewport, caret: TextPos) void {
        // adjust the viewport so the caret always remains visible
        if (self.height == 0 or self.width == 0) return;       
        // NOTE: it is the caller's responsibility to validate the caret position
        if (caret.line < self.top_line) { self.top_line = caret.line; }
        if (caret.line >= self.top_line + self.height) { self.top_line = caret.line - self.height + 1; }
        if (caret.col < self.left_col) { self.left_col = caret.col; }
        if (caret.col >= self.left_col + self.width) { self.left_col = caret.col - self.width + 1; }
    }

    pub fn scrollBy(self: *Viewport, d_lines: isize, d_cols: isize) void {
        // NOTE: it is the caller's responsibility to bound scrolling
        if (d_lines < 0) {
            const delta: usize = @intCast(-d_lines);
            self.top_line = if (delta > self.top_line) 0 else self.top_line - delta;
        } else if (d_lines > 0) { self.top_line += @intCast(d_lines); }
        if (d_cols < 0) {
            const delta: usize = @intCast(-d_cols);
            self.left_col = if (delta > self.left_col) 0 else self.left_col - delta;
        } else if (d_cols > 0) { self.left_col += @intCast(d_cols); }
    }

    pub fn clampVert(self: *Viewport, line_count: usize) void {
        // allows a caller to clamp vertical scrolling
        if (line_count == 0) { self.top_line = 0; return; }
        if (self.height == 0) {
            self.top_line = if (self.top_line >= line_count) line_count - 1 else self.top_line;
            return;
        }
        const max_top = if (self.height >= line_count) 0 else line_count - self.height;
        if (self.top_line >= max_top) self.top_line = max_top;
    }

    pub fn clampHorz(self: *Viewport, line_len: usize) void {
        // allows a caller to clamp horizontal scrolling
        if (self.width == 0) { self.left_col = 0; return; }
        const max_left = if (self.width >= line_len) 0 else line_len - self.width;
        if (self.left_col > max_left) self.left_col = max_left;
    }

    pub fn resize(self: *Viewport, new_height: usize, new_width: usize) void {
        self.height = new_height;
        self.width = new_width;
    }

    pub fn visibleLineSpan(self: *Viewport) LineSpan {
        return .{ .first = self.top_line, .count = self.height };
    }
};

test "ensureCaretVisible: no change when caret already visible" {
    var vp = Viewport{ .top_line = 10, .left_col = 5, .height = 4, .width = 6 };
    const caret = TextPos{ .line = 12, .col = 8 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 10), vp.top_line);
    try std.testing.expectEqual(@as(usize, 5), vp.left_col);
}

test "ensureCaretVisible: caret above top scrolls up" {
    var vp = Viewport{ .top_line = 10, .left_col = 5, .height = 4, .width = 6 };
    const caret = TextPos{ .line = 9, .col = 8 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 9), vp.top_line);
    try std.testing.expectEqual(@as(usize, 5), vp.left_col);
}

test "ensureCaretVisible: caret below bottom moves caret to last visible row" {
    var vp = Viewport{ .top_line = 10, .left_col = 0, .height = 3, .width = 10 };
    const caret = TextPos{ .line = 13, .col = 0 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 11), vp.top_line);
}

test "ensureCaretVisible: caret exactly on last visible row is still visible (no change)" {
    var vp = Viewport{ .top_line = 7, .left_col = 0, .height = 4, .width = 10 };
    const caret = TextPos{ .line = 10 - 1, .col = 0 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 7), vp.top_line);
}

test "ensureCaretVisible: caret left of viewport scrolls left" {
    var vp = Viewport{ .top_line = 0, .left_col = 10, .height = 5, .width = 8 };
    const caret = TextPos{ .line = 0, .col = 7 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 7), vp.left_col);
}

test "ensureCaretVisible: caret beyond right edge moves caret to last visible col" {
    var vp = Viewport{ .top_line = 0, .left_col = 10, .height = 5, .width = 8 };
    const caret = TextPos{ .line = 0, .col = 18 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 11), vp.left_col);
}

test "ensureCaretVisible: zero-sized viewport is a no-op" {
    var vp = Viewport{ .top_line = 10, .left_col = 10, .height = 0, .width = 0 };
    const caret = TextPos{ .line = 999, .col = 999 };
    vp.ensureCaretVisible(caret);
    try std.testing.expectEqual(@as(usize, 10), vp.top_line);
    try std.testing.expectEqual(@as(usize, 10), vp.left_col);
}

test "scrollBy: negative deltas saturate at zero; positive are unbounded" {
    var vp = Viewport{ .top_line = 3, .left_col = 2, .height = 5, .width = 5 };
    vp.scrollBy(-10, -1);
    try std.testing.expectEqual(@as(usize, 0), vp.top_line);
    try std.testing.expectEqual(@as(usize, 1), vp.left_col);
    vp.scrollBy(7, 100);
    try std.testing.expectEqual(@as(usize, 7), vp.top_line);
    try std.testing.expectEqual(@as(usize, 101), vp.left_col);
}

test "visibleLineSpan: returns (first, count) with half-open semantics" {
    var vp = Viewport{ .top_line = 42, .left_col = 0, .height = 3, .width = 80 };
    const span = vp.visibleLineSpan();
    try std.testing.expectEqual(@as(usize, 42), span.first);
    try std.testing.expectEqual(@as(usize, 3), span.count);
}

test "resize: updates dimensions" {
    var vp = Viewport{ .top_line = 0, .left_col = 0, .height = 10, .width = 10 };
    vp.resize(25, 100);
    try std.testing.expectEqual(@as(usize, 25), vp.height);
    try std.testing.expectEqual(@as(usize, 100), vp.width);
}

test "clampVert: empty document clamps top_line to 0" {
    var vp = Viewport{ .top_line = 99, .left_col = 0, .height = 5, .width = 5 };
    vp.clampVert(0);
    try std.testing.expectEqual(@as(usize, 0), vp.top_line);
}

test "clampVert: height==0 keeps top_line within [0, line_count-1]" {
    var vp = Viewport{ .top_line = 123, .left_col = 0, .height = 0, .width = 5 };
    vp.clampVert(10);
    try std.testing.expectEqual(@as(usize, 9), vp.top_line);
    vp.top_line = 3;
    vp.clampVert(10);
    try std.testing.expectEqual(@as(usize, 3), vp.top_line);
}

test "clampVert: height >= line_count -> top_line becomes 0" {
    var vp = Viewport{ .top_line = 50, .left_col = 0, .height = 10, .width = 5 };
    vp.clampVert(7); // all lines fit
    try std.testing.expectEqual(@as(usize, 0), vp.top_line);
}

test "clampVert: general case clamps to max_top = line_count - height" {
    var vp = Viewport{ .top_line = 98, .left_col = 0, .height = 3, .width = 5 };
    vp.clampVert(100);
    try std.testing.expectEqual(@as(usize, 97), vp.top_line);
    vp.top_line = 80;
    vp.clampVert(100);
    try std.testing.expectEqual(@as(usize, 80), vp.top_line);
}

test "clampHorz: width==0 forces left_col to 0" {
    var vp = Viewport{ .top_line = 0, .left_col = 99, .height = 5, .width = 0 };
    vp.clampHorz(100);
    try std.testing.expectEqual(@as(usize, 0), vp.left_col);
}

test "clampHorz: width >= line_len -> left_col becomes 0" {
    var vp = Viewport{ .top_line = 0, .left_col = 50, .height = 5, .width = 80 };
    vp.clampHorz(10);
    try std.testing.expectEqual(@as(usize, 0), vp.left_col);
}

test "clampHorz: general case clamps to max_left = line_len - width" {
    var vp = Viewport{ .top_line = 0, .left_col = 200, .height = 5, .width = 12 };
    vp.clampHorz(100);
    try std.testing.expectEqual(@as(usize, 88), vp.left_col);
    vp.left_col = 20;
    vp.clampHorz(100);
    try std.testing.expectEqual(@as(usize, 20), vp.left_col);
}

test "integration: ensureCaretVisible then clampVert clamps overscroll at bottom" {
    var vp = Viewport{ .top_line = 10, .left_col = 0, .height = 4, .width = 10 };
    vp.ensureCaretVisible(TextPos{ .line = 20, .col = 0 });
    try std.testing.expectEqual(@as(usize, 17), vp.top_line);
    vp.clampVert(18);
    try std.testing.expectEqual(@as(usize, 14), vp.top_line);
}

test "integration: horizontal ensureCaretVisible then clampHorz" {
    var vp = Viewport{ .top_line = 0, .left_col = 10, .height = 5, .width = 8 };
    vp.ensureCaretVisible(TextPos{ .line = 0, .col = 50 });
    try std.testing.expectEqual(@as(usize, 43), vp.left_col);
    vp.clampHorz(45);
    try std.testing.expectEqual(@as(usize, 37), vp.left_col);
}