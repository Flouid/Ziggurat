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

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{OutOfMemory}!Document {
        return .{ 
            .buffer = try TextBuffer.init(alloc, original),
            .cursor = .{ .byte = 0, .pos = .{ 0, 0 }, .preferred_col = 0, }
        };
    }

    pub fn deinit(self: *Document) void {
        self.buffer.deinit();
    }

    // pass-through length helpers

    pub fn size(self: *Document) usize { return self.buffer.doc_len; }
    pub fn lineCount(self: *Document) usize { return self.buffer.root.weight_lines + 1; }

    // navigation helpers

    pub fn lineStart(self: *Document, line: usize) error{OutOfMemory}!usize {
        debug.dassert(line < self.lineCount(), "line outside of document");
        return self.buffer.byteOfLine(line);
    }

    pub fn lineEnd(self: *Document, line: usize) error{OutOfMemory}!usize {
        debug.dassert(line < self.lineCount(), "line outside of document");
        return if (line + 1 < self.lineCount()) self.buffer.byteOfLine(line + 1) else self.size();
    }

    pub fn lineSpan(self: *Document, line: usize) error{OutOfMemory}!Span {
        debug.dassert(line < self.lineCount(), "line outside of document");
        const start = try self.lineStart(line);
        const end = try self.lineEnd(line);
        return .{ .start = start, .end = end };
    }

    pub fn lineLen(self: *Document, line: usize) error{OutOfMemory}!usize {
        debug.dassert(line < self.lineCount(), "line outside of document");
        const span = try self.lineSpan(line);
        return span.end - span.start;
    }

    pub fn byteToPos(self: *Document, at: usize) error{OutOfMemory}!Pos {
        debug.dassert(at <= self.size(), "index outside of document");
        // NOTE: this double traversal is technically unneccesary, but would require another big helper
        const line = try self.buffer.lineOfByte(at);
        const start = try self.buffer.byteOfLine(line);
        return .{ .line = line, .col = at - start };
    }

    pub fn posToByte(self: *Document, pos: Pos) error{OutOfMemory}!usize {
        const start = try self.buffer.byteOfLine(pos.line);
        // NOTE: implicit assumption that bytes and columns are interchangable
        return start + pos.col;
    }

    // editing and cursor traversal

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
    }

    // materialization and iteration over lines

    pub fn iterLines(self: *Document, first: usize, last: usize) SliceIter {
        debug.dassert(first <= last, "cannot iterate over a negative range");
        debug.dassert(last < self.lineCount(), "last line outside of document");
        const first_byte = self.lineStart(first) catch unreachable;
        const last_byte = self.lineEnd(last) catch unreachable;
        return self.buffer.getSliceIter(first_byte, last_byte - first_byte);
    }

    pub fn materializeLines(self: *Document, w: anytype, first: usize, last: usize) @TypeOf(w).Error!void {
        debug.dassert(first <= last, "cannot materialize a negative range");
        debug.dassert(last < self.lineCount(), "last line outside of document");
        const first_byte = self.lineStart(first) catch unreachable;
        const last_byte = self.lineEnd(last) catch unreachable;
        try self.buffer.materializeRange(w, first_byte, last_byte - first_byte);
    }

    pub fn materialize(self: *Document, w: anytype) @TypeOf(w).Error!void {
        // pass-through method for materializing a full document
        try self.buffer.materialize(w);
    }
};
