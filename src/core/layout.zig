const std = @import("std");
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const TextPos = @import("types").TextPos;
const ScreenPos = @import("types").ScreenPos;
const Span = @import("types").Span;

pub const Layout = struct {
    first_row: usize,
    width: usize,
    lines: []Span,
    caret: ?ScreenPos,

    pub fn init(arena: std.mem.Allocator, doc: *Document, vp: *const Viewport) error{OutOfMemory}!Layout {
        const total = doc.lineCount();
        // vertical clamping
        const first = if (total == 0) 0 else (if (vp.top_line < total) vp.top_line else total - 1);
        const remaining = if (total > first) total - first else 0;
        const visible_rows = @min(vp.height, remaining);
        // line creation
        var lines = try arena.alloc(Span, visible_rows);
        var i: usize = 0;
        while (i < visible_rows) : (i += 1) {
            const full_line = try doc.lineSpan(first + i);
            const len = full_line.len;
            const left = vp.left_col;
            const col_start = if (left > len) len else left;
            const remaining_cols = len - col_start;
            const col_count = @min(vp.width, remaining_cols);
            lines[i] = .{ .start = full_line.start + col_start, .len = col_count };
        }
        return .{ .first_row = first, .width = vp.width, .lines = lines, .caret = textPosToScreenPos(doc.caret.pos, vp) };
    }
};

pub fn textPosToScreenPos(tp: TextPos, vp: *const Viewport) ?ScreenPos {
    if (vp.height == 0 or vp.width == 0) return null;
    if (tp.row < vp.top_line or tp.row >= vp.top_line + vp.height) return null;
    if (tp.col < vp.left_col or tp.col >= vp.left_col + vp.width) return null;
    return .{
        .row = tp.row - vp.top_line,
        .col = tp.col - vp.left_col,
    };
}

test "Layout: first line clipped horizontally" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const alloc = a.allocator();
    var doc = try Document.init(std.testing.allocator, "abc\ndef\n");
    defer doc.deinit();
    var vp = Viewport{ .top_line = 0, .left_col = 0, .height = 1, .width = 2 };
    const layout = try Layout.init(alloc, &doc, &vp);
    try std.testing.expectEqual(@as(usize, 0), layout.first_row);
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    const L = layout.lines[0];
    try std.testing.expectEqual(@as(usize, 0), L.start);
    try std.testing.expectEqual(@as(usize, 2), L.len);
    try std.testing.expect(layout.caret != null);
    try std.testing.expectEqual(@as(usize, 0), layout.caret.?.row);
    try std.testing.expectEqual(@as(usize, 0), layout.caret.?.col);
}

test "Layout: horizontal scroll past EOL yields empty slice" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const alloc = a.allocator();
    var doc = try Document.init(std.testing.allocator, "abc\n");
    defer doc.deinit();
    var vp = Viewport{ .top_line = 0, .left_col = 5, .height = 1, .width = 4 };
    const layout = try Layout.init(alloc, &doc, &vp);
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[0].start);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].len);
}

test "Layout: vertical clamp at end of document" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const alloc = a.allocator();
    var doc = try Document.init(std.testing.allocator, "aa\nbb\ncc\n");
    defer doc.deinit();
    var vp = Viewport{ .top_line = 2, .left_col = 0, .height = 10, .width = 80 };
    const layout = try Layout.init(alloc, &doc, &vp);
    try std.testing.expectEqual(@as(usize, 2), layout.first_row);
    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].len);
}

test "Layout: last line with no trailing newline" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const alloc = a.allocator();
    var doc = try Document.init(std.testing.allocator, "hello\nX");
    defer doc.deinit();
    var vp = Viewport{ .top_line = 1, .left_col = 0, .height = 1, .width = 10 };
    const layout = try Layout.init(alloc, &doc, &vp);
    try std.testing.expectEqual(@as(usize, 1), layout.first_row);
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 1), layout.lines[0].len);
}

test "textPosToScreenPos: null when caret is off-screen" {
    var vp = Viewport{ .top_line = 10, .left_col = 20, .height = 3, .width = 5 };
    const tp1 = TextPos{ .row = 9, .col = 20 };
    const tp2 = TextPos{ .row = 10, .col = 19 };
    const tp3 = TextPos{ .row = 13, .col = 24 };
    try std.testing.expect(textPosToScreenPos(tp1, &vp) == null);
    try std.testing.expect(textPosToScreenPos(tp2, &vp) == null);
    try std.testing.expect(textPosToScreenPos(tp3, &vp) == null);
}

test "textPosToScreenPos: maps visible caret to screen coords" {
    var vp = Viewport{ .top_line = 10, .left_col = 20, .height = 3, .width = 5 };
    const tp = TextPos{ .row = 11, .col = 22 };
    const sp = textPosToScreenPos(tp, &vp).?;
    try std.testing.expectEqual(@as(usize, 1), sp.row);
    try std.testing.expectEqual(@as(usize, 2), sp.col);
}
