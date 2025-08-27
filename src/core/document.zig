const std = @import("std");
const debug = @import("debug");
const utils = @import("utils");
const TextBuffer = @import("buffer").TextBuffer;
const SliceIter = @import("buffer").SliceIter;
const TextPos = @import("types").TextPos;
const Span = @import("types").Span;

// The logical document layer.
// The text buffer sits below and operates purely in terms of bytes.
// The document adds abstraction and operates in terms of lines, columns, and characters.

pub const Caret = struct {
    // the logical caret inside the document
    byte: usize,
    pos: TextPos,
    preferred_col: usize,
};

pub const Document = struct {
    buffer: TextBuffer,
    caret: Caret,
    owned_src: []const u8,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{ OutOfMemory, FileTooBig }!Document {
        // creating an owned copy gives the document full ownership, even over string literals
        const owned = try alloc.dupe(u8, original);
        return .{ 
            .buffer = try TextBuffer.init(alloc, owned),
            .caret = .{ .byte = 0, .pos = .{ .line = 0, .col = 0 }, .preferred_col = 0, },
            .owned_src = owned,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Document) void {
        self.alloc.free(self.owned_src);
        self.buffer.deinit();
    }

    // pass-through length helpers

    pub fn size(self: *const Document) usize { return self.buffer.doc_len; }
    pub fn lineCount(self: *const Document) usize { return self.buffer.root.weight_lines + 1; }

    // editing around the cursor

    pub fn caretInsert(self: *Document, text: []const u8) error{OutOfMemory}!void {
        debug.dassert(text.len > 0, "cannot insert empty text at cursor");
        // update the text buffer
        try self.buffer.insert(self.caret.byte, text);
        // update the cursor cheaply
        const c = &self.caret;
        const newlines = utils.countNewlinesInSlice(text);
        if (newlines == 0) { c.pos.col += text.len; }
        else {
            c.pos.line += newlines;
            // figure out how many characters were after the last newline in the inserted text
            var i = text.len - 1;
            while (i > 0 and text[i] != '\n') : (i -= 1) {}
            c.pos.col = text.len - i - 1;
        }
        c.byte += text.len;
        c.preferred_col = c.pos.col;
    }

    pub fn caretBackspace(self: *Document, n: usize) error{OutOfMemory}!void {
        debug.dassert(n > 0, "cannot delete nothing at cursor");
        const c = &self.caret;
        // if the cursor is at the start of the document, silently do nothing
        if (c.byte == 0) return;
        const take = @min(n, c.byte);
        const start = c.byte - take;
        // use a slice iterator to look at what's getting deleted and count newlines
        var it = self.buffer.getSliceIter(start, take);
        var newlines: usize = 0;
        while (it.next()) |slice| newlines += utils.countNewlinesInSlice(slice);
        // actually delete from the textbuffer
        try self.buffer.delete(start, take);
        // perform cursor update
        c.byte -= take;
        if (newlines == 0) { c.pos.col -= take; }
        else {
            c.pos.line -= newlines;
            const line_start = try self.lineStart(c.pos.line);
            c.pos.col = c.byte - line_start;
        }
        c.preferred_col = c.pos.col;
    }

    // cursor traversal

    pub fn moveTo(self: *Document, pos: TextPos) error{OutOfMemory}!void {
        const c = &self.caret;
        c.byte = try self.posToByte(pos);
        c.pos = pos;
        c.preferred_col = c.pos.col;
    }

    pub fn moveLeft(self: *Document) error{OutOfMemory}!void {
        const c = &self.caret;
        if (c.byte == 0) return;
        c.byte -= 1;
        if (c.pos.col > 0) { c.pos.col -= 1; }
        else { c.pos = try self.byteToPos(c.byte); }
        c.preferred_col = c.pos.col;
    }

    pub fn moveRight(self: *Document) error{OutOfMemory}!void {
        const c = &self.caret;
        if (c.byte >= self.size()) return;
        const line_end = try self.lineEnd(c.pos.line);
        // move to next line, account for EOF special case
        if (c.byte + 1 == line_end and line_end < self.size()) {
            c.pos.line += 1; 
            c.pos.col = 0;
        }
        else { c.pos.col += 1; }
        c.byte += 1;
        c.preferred_col = c.pos.col;
    }

    pub fn moveHome(self: *Document) error{OutOfMemory}!void {
        const c = &self.caret;
        c.byte = try self.lineStart(c.pos.line);
        c.pos.col = 0;
        c.preferred_col = 0;
    }

    pub fn moveEnd(self: *Document) error{OutOfMemory}!void {
        const c = &self.caret;
        const span = try self.lineSpan(c.pos.line);
        c.byte = span.start + span.len;
        c.pos.col = span.len;
        c.preferred_col = c.pos.col;
    }

    pub fn moveUp(self: *Document) error{OutOfMemory}!void {
        const c = &self.caret;
        if (c.pos.line == 0) { try self.moveHome(); return; }
        c.pos.line -= 1;
        const span = try self.lineSpan(c.pos.line);
        c.pos.col = @min(c.preferred_col, span.len);
        c.byte = span.start + c.pos.col;
    }

    pub fn moveDown(self: *Document) error{OutOfMemory}!void {
        const c = &self.caret;
        if (c.pos.line + 1 >= self.lineCount()) { try self.moveEnd(); return; }
        c.pos.line += 1;
        const span = try self.lineSpan(c.pos.line);
        c.pos.col = @min(c.preferred_col, span.len);
        c.byte = span.start + c.pos.col;
    }

    // materialization and span generation

    pub fn materializeRange(self: *Document, w: anytype, start: usize, len: usize) !void {
        // pass-through method for materializing a range of bytes
        try self.buffer.materializeRange(w, start, len);
    }

    pub fn materialize(self: *Document, w: anytype) !void {
        // pass-through method for materializing a full document
        try self.buffer.materialize(w);
    }

    pub fn lineSpan(self: *Document, line: usize) error{OutOfMemory}!Span {
        debug.dassert(line < self.lineCount(), "line outside of document");
        const start = try self.lineStart(line);
        const end = try self.lineEnd(line);
        debug.dassert(end >= start, "line cannot have negative length");
        // subtracts newline for all lines except the last (no newline)
        const len = if (line + 1 < self.lineCount()) end - start - 1 else end - start;
        return .{ .start = start, .len = len };
    }

    // navigation helpers

    fn lineStart(self: *Document, line: usize) error{OutOfMemory}!usize {
        debug.dassert(line < self.lineCount(), "line outside of document");
        return self.buffer.byteOfLine(line);
    }

    fn lineEnd(self: *Document, line: usize) error{OutOfMemory}!usize {
        debug.dassert(line < self.lineCount(), "line outside of document");
        return if (line + 1 < self.lineCount()) self.buffer.byteOfLine(line + 1) else self.size();
    }

    fn byteToPos(self: *Document, at: usize) error{OutOfMemory}!TextPos {
        debug.dassert(at <= self.size(), "index outside of document");
        // NOTE: this double traversal is technically unneccesary, but would require another big helper
        const line = try self.buffer.lineOfByte(at);
        const start = try self.buffer.byteOfLine(line);
        return .{ .line = line, .col = at - start };
    }

    fn posToByte(self: *Document, pos: TextPos) error{OutOfMemory}!usize {
        debug.dassert(pos.line < self.lineCount(), "line outside of document");
        const span = try self.lineSpan(pos.line);
        debug.dassert(pos.col <= span.len, "column outside of line");
        const start = try self.buffer.byteOfLine(pos.line);
        // NOTE: implicit assumption that bytes and columns are interchangable
        return start + pos.col;
    }
};

test "moveRight at EOL without trailing newline clamps at EOF" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "abc");
    defer doc.deinit();
    try doc.moveEnd();
    try std.testing.expectEqual(@as(usize, 3), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 3), doc.caret.pos.col);
    try doc.moveRight();
    try std.testing.expectEqual(@as(usize, 3), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 3), doc.caret.pos.col);
}

test "moveRight off EOF clamps" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "a");
    defer doc.deinit();
    try doc.moveRight();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.col);
    try doc.moveRight();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.col);
}

test "moveRight at EOL with trailing newline enters next line start" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "ab\nc");
    defer doc.deinit();
    try doc.moveEnd();
    try std.testing.expectEqual(@as(usize, 2), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.col);
    try doc.moveRight();
    try std.testing.expectEqual(@as(usize, 3), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
}

test "moveLeft at SOL moves to end of previous col" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "ab\nc");
    defer doc.deinit();
    try doc.moveDown();
    try std.testing.expectEqual(@as(usize, 3), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.moveLeft();
    try std.testing.expectEqual(@as(usize, 2), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.col);
}

test "vertical movement preserves preferred_col across shorter lines" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "abcdef\nxy\npqrst");
    defer doc.deinit();
    try doc.moveTo(.{ .line = 0, .col = 5 });
    try std.testing.expectEqual(@as(usize, 5), doc.caret.pos.col);
    try std.testing.expectEqual(doc.caret.pos.col, doc.caret.preferred_col);
    try doc.moveDown();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.col);
    try std.testing.expectEqual(@as(usize, 5), doc.caret.preferred_col);
    try doc.moveDown();
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 5), doc.caret.pos.col);
    try std.testing.expectEqual(@as(usize, 5), doc.caret.preferred_col);
    try doc.moveUp();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.col);
    try std.testing.expectEqual(@as(usize, 5), doc.caret.preferred_col);
    try doc.moveUp();
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 5), doc.caret.pos.col);
}

test "cursorBackspace across newline updates line/col correctly" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "ab\nc");
    defer doc.deinit();
    try doc.moveDown();
    try doc.moveEnd();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.col);
    try doc.caretBackspace(1);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.caretBackspace(1);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.col); // end of "ab"
    try std.testing.expectEqual(@as(usize, 2), doc.caret.byte);
}

test "empty lines handled correctly" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "\n\n\n");
    defer doc.deinit();
    try doc.moveDown();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.moveRight();
    try std.testing.expectEqual(@as(usize, 2), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.caretInsert("\n");
    try std.testing.expectEqual(@as(usize, 3), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 3), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.caretBackspace(1);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
    try doc.moveUp();
    try std.testing.expectEqual(@as(usize, 0), doc.caret.byte);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.col);
}

test "cursorInsert updates line/col and preferred_col" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "");
    defer doc.deinit();
    try doc.caretInsert("hi");
    try std.testing.expectEqual(@as(usize, 0), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 2), doc.caret.pos.col);
    try std.testing.expectEqual(doc.caret.pos.col, doc.caret.preferred_col);
    try doc.caretInsert("\nxyz");
    try std.testing.expectEqual(@as(usize, 1), doc.caret.pos.line);
    try std.testing.expectEqual(@as(usize, 3), doc.caret.pos.col);
    try std.testing.expectEqual(doc.caret.pos.col, doc.caret.preferred_col);
}
