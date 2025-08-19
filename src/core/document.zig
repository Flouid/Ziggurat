const std = @import("std");
const debug = @import("debug");
const utils = @import("utils");
const TextBuffer = @import("buffer").TextBuffer;
const SliceIter = @import("buffer").SliceIter;

// The logical document layer.
// The text buffer sits below and operates purely in terms of bytes.
// The document adds abstraction and operates in terms of lines, columns, and characters.

pub const Pos = struct {
    // a logical position in the document
    line: usize,
    col: usize,
};

pub const Span = struct {
    // an exclusive span [start, end) for use within a line
    start: usize,
    end: usize,
};

pub const Cursor = struct {
    // the logical cursor inside the document
    byte: usize,
    pos: Pos,
    preferred_col: usize,
};

pub const Document = struct {
    buffer: TextBuffer,
    cursor: Cursor,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{ OutOfMemory, FileTooBig }!Document {
        return .{ 
            .buffer = try TextBuffer.init(alloc, original),
            .cursor = .{ .byte = 0, .pos = .{ .line = 0, .col = 0 }, .preferred_col = 0, }
        };
    }

    pub fn deinit(self: *Document) void {
        self.buffer.deinit();
    }

    // pass-through length helpers

    pub fn size(self: *Document) usize { return self.buffer.doc_len; }
    pub fn lineCount(self: *Document) usize { return self.buffer.root.weight_lines + 1; }

    // editing around the cursor

    pub fn cursorInsert(self: *Document, text: []const u8) error{OutOfMemory}!void {
        debug.dassert(text.len > 0, "cannot insert empty text at cursor");
        // update the text buffer
        try self.buffer.insert(self.cursor.byte, text);
        // update the cursor cheaply
        const c = &self.cursor;
        const newlines = utils.countNewlinesInSlice(text);
        if (newlines == 0) { c.pos.col += text.len; }
        else {
            c.pos.line += newlines;
            // figure out how many characters were after the last newline in the inserted text
            var last_newline: usize = 0;
            for (text, 0..) |b, i| { if (b == '\n') last_newline = i; }
            c.pos.col = text.len - last_newline - 1;
        }
        c.byte += text.len;
        c.preferred_col = c.pos.col;
    }

    pub fn cursorBackspace(self: *Document, n: usize) error{OutOfMemory}!void {
        debug.dassert(n > 0, "cannot delete nothing at cursor");
        const c = &self.cursor;
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

    pub fn moveTo(self: *Document, pos: Pos) error{OutOfMemory}!void {
        const c = &self.cursor;
        c.byte = try self.posToByte(pos);
        c.pos = pos;
        c.preferred_col = c.pos.col;
    }

    pub fn moveLeft(self: *Document) error{OutOfMemory}!void {
        const c = &self.cursor;
        if (c.byte == 0) return;
        c.byte -= 1;
        if (c.pos.col > 0) { c.pos.col -= 1; }
        else { c.pos = try self.byteToPos(c.byte); }
        c.preferred_col = c.pos.col;
    }

    pub fn moveRight(self: *Document) error{OutOfMemory}!void {
        const c = &self.cursor;
        if (c.byte >= self.size()) return;
        c.byte += 1;
        const line_end = try self.lineEnd(c.pos.line);
        if (c.byte < line_end) { c.pos.col += 1; }
        else {
            c.pos.line += 1;
            c.pos.col = 0;
        }
        c.preferred_col = c.pos.col;
    }

    pub fn moveHome(self: *Document) error{OutOfMemory}!void {
        const c = &self.cursor;
        c.byte = try self.lineStart(c.pos.line);
        c.pos.col = 0;
        c.preferred_col = 0;
    }

    pub fn moveEnd(self: *Document) error{OutOfMemory}!void {
        const c = &self.cursor;
        const span = try self.lineSpan(c.pos.line);
        c.byte = span.end;
        c.pos.col = span.end - span.start;
        c.preferred_col = c.pos.col;
    }

    pub fn moveUp(self: *Document) error{OutOfMemory}!void {
        const c = &self.cursor;
        if (c.pos.line == 0) { self.moveHome(); return; }
        c.pos.line -= 1;
        const span = try self.lineSpan(c.pos.line);
        c.pos.col = @min(c.preferred_col, span.end - span.start);
        c.byte = span.start + c.pos.col;
    }

    pub fn moveDown(self: *Document) error{OutOfMemory}!void {
        const c = &self.cursor;
        if (c.pos.line + 1 >= self.lineCount()) { self.moveEnd(); return; }
        c.pos.line += 1;
        const span = try self.lineSpan(c.pos.line);
        c.pos.col = @min(c.preferred_col, span.end - span.start);
        c.byte = span.start + c.pos.col;
    }

    // materialization and iteration over lines

    pub fn iterLines(self: *Document, first: usize, last: usize) error{OutOfMemory}!SliceIter {
        debug.dassert(first <= last, "cannot iterate over a negative range");
        debug.dassert(last < self.lineCount(), "last line outside of document");
        const first_byte = try self.lineStart(first);
        const last_byte = try self.lineEnd(last);
        return self.buffer.getSliceIter(first_byte, last_byte - first_byte);
    }

    pub fn materializeLines(self: *Document, w: anytype, first: usize, last: usize) !void {
        debug.dassert(first <= last, "cannot materialize a negative range");
        debug.dassert(last < self.lineCount(), "last line outside of document");
        const first_byte = try self.lineStart(first);
        const last_byte = try self.lineEnd(last);
        try self.buffer.materializeRange(w, first_byte, last_byte - first_byte);
    }

    pub fn materialize(self: *Document, w: anytype) @TypeOf(w).Error!void {
        // pass-through method for materializing a full document
        try self.buffer.materialize(w);
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

    fn lineSpan(self: *Document, line: usize) error{OutOfMemory}!Span {
        debug.dassert(line < self.lineCount(), "line outside of document");
        const start = try self.lineStart(line);
        const end = try self.lineEnd(line);
        return .{ .start = start, .end = end };
    }

    fn lineLen(self: *Document, line: usize) error{OutOfMemory}!usize {
        debug.dassert(line < self.lineCount(), "line outside of document");
        const span = try self.lineSpan(line);
        return span.end - span.start;
    }

    fn byteToPos(self: *Document, at: usize) error{OutOfMemory}!Pos {
        debug.dassert(at <= self.size(), "index outside of document");
        // NOTE: this double traversal is technically unneccesary, but would require another big helper
        const line = try self.buffer.lineOfByte(at);
        const start = try self.buffer.byteOfLine(line);
        return .{ .line = line, .col = at - start };
    }

    fn posToByte(self: *Document, pos: Pos) error{OutOfMemory}!usize {
        debug.dassert(pos.line <= self.lineCount(), "line outside of document");
        const span = try self.lineSpan(pos.line);
        debug.dassert(pos.col <= span.end - span.start, "column outside of line");
        const start = try self.buffer.byteOfLine(pos.line);
        // NOTE: implicit assumption that bytes and columns are interchangable
        return start + pos.col;
    }
};

test "compiles" {
    const alloc = std.testing.allocator;
    var doc = try Document.init(alloc, "text");
    defer doc.deinit();
    try std.testing.expect(true);
}