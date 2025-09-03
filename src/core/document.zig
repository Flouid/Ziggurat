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

    const begin: Caret = .{ .byte = 0, .pos = .{ .row = 0, .col = 0 }, .preferred_col = 0 };
};

pub const Document = struct {
    buffer: TextBuffer,
    caret: Caret,
    anchor: ?Caret = null,
    src: []const u8,
    alloc: std.mem.Allocator,
    max_cols: usize = 0,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{ OutOfMemory, FileTooBig }!Document {
        return .{
            .buffer = try TextBuffer.init(alloc, original),
            .caret = .begin,
            .src = original,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Document) void {
        self.buffer.deinit();
    }

    // pass-through length helpers

    pub fn size(self: *const Document) usize {
        return self.buffer.doc_len;
    }
    pub fn revealUpTo(self: *Document, line: usize) error{OutOfMemory}!void {
        _ = try self.buffer.scanFrontierUntil(line);
    }
    pub fn lineCount(self: *const Document) usize {
        return self.buffer.root.weight_lines + 1;
    }
    pub fn lineLength(self: *const Document) usize {
        return self.max_cols + 1;
    }

    // editing around the cursor

    pub fn caretInsert(self: *Document, text: []const u8) error{OutOfMemory}!void {
        debug.dassert(text.len > 0, "cannot insert empty text at cursor");
        // when there is a selection, delete the selected range prior to insertion
        if (self.hasSelection()) try self.caretBackspace();
        // update the text buffer
        try self.buffer.insert(self.caret.byte, text);
        // update the cursor cheaply
        const c = &self.caret;
        const newlines = utils.countNewlinesInSlice(text);
        if (newlines == 0) {
            c.pos.col += text.len;
        } else {
            c.pos.row += newlines;
            // figure out how many characters were after the last newline in the inserted text
            var i = text.len - 1;
            while (i > 0 and text[i] != '\n') : (i -= 1) {}
            c.pos.col = text.len - i - 1;
        }
        c.byte += text.len;
        c.preferred_col = c.pos.col;
    }

    pub fn caretBackspace(self: *Document) error{OutOfMemory}!void {
        // default case, delete from the caret and one at a time
        var c = self.caret;
        var take: usize = 1;
        // handle selections
        if (self.selectionSpan()) |span| {
            // if caret is behind span start, delete from the start instead
            if (self.anchor.?.byte > c.byte) c = self.anchor.?;
            take = span.len;
        }
        // special case, delete entire document
        if (take == self.size()) {
            try self.buffer.reset();
            self.caret = .begin;
            self.resetSelection();
            return;
        }
        // if the cursor is at the start of the document, silently do nothing
        if (c.byte == 0) return;
        const start = c.byte - take;
        const span: Span = .{ .start = start, .len = take };
        // use a slice iterator to look at what's getting deleted and count newlines
        var it = self.buffer.getSliceIter(span);
        var newlines: usize = 0;
        while (it.next()) |slice| newlines += utils.countNewlinesInSlice(slice);
        // actually delete from the textbuffer
        try self.buffer.delete(span);
        // perform cursor update
        c.byte -= take;
        if (newlines == 0) {
            c.pos.col -= take;
        } else {
            c.pos.row -= newlines;
            const line_start = try self.lineStart(c.pos.row);
            c.pos.col = c.byte - line_start;
        }
        c.preferred_col = c.pos.col;
        self.caret = c;
        self.resetSelection();
    }

    pub fn deleteForward(self: *Document) error{OutOfMemory}!void {
        try self.moveRight(false);
        try self.caretBackspace();
    }

    pub fn deleteWordLeft(self: *Document) error{OutOfMemory}!void {
        self.startSelection();
        try self.moveWordLeft(false);
        try self.caretBackspace();
    }

    pub fn deleteWordRight(self: *Document) error{OutOfMemory}!void {
        self.startSelection();
        try self.moveWordRight(false);
        try self.caretBackspace();
    }

    // cursor traversal

    pub fn moveTo(self: *Document, pos: TextPos) error{OutOfMemory}!void {
        const c = &self.caret;
        c.byte = try self.posToByte(pos);
        c.pos = pos;
        c.preferred_col = c.pos.col;
    }

    pub fn moveLeft(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move left should just put the caret at the anchor position
            debug.dassert(self.hasSelection(), "moveLeft: can only cancel selection if one exists");
            self.caret = self.anchor.?;
            self.resetSelection();
            return;
        }
        const c = &self.caret;
        if (c.byte == 0) return;
        c.byte -= 1;
        if (c.pos.col > 0) {
            c.pos.col -= 1;
        } else {
            c.pos = try self.byteToPos(c.byte);
        }
        c.preferred_col = c.pos.col;
    }

    pub fn moveRight(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move right should just clear the selection without moving
            debug.dassert(self.hasSelection(), "moveRight: can only cancel selection if one exists");
            self.resetSelection();
            return;
        }
        const c = &self.caret;
        if (c.byte >= self.size()) return;
        const line_end = try self.lineEnd(c.pos.row);
        // move to next line, account for EOF special case
        if (c.byte + 1 == line_end and line_end < self.size()) {
            c.pos.row += 1;
            c.pos.col = 0;
        } else {
            c.pos.col += 1;
        }
        c.byte += 1;
        c.preferred_col = c.pos.col;
    }

    pub fn moveHome(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move home should just clear the selection before moving normally
            debug.dassert(self.hasSelection(), "moveHome: can only cancel selection if one exists");
            self.resetSelection();
        }
        const c = &self.caret;
        c.byte = try self.lineStart(c.pos.row);
        c.pos.col = 0;
        c.preferred_col = 0;
    }

    pub fn moveEnd(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move end should just clear the selection before moving normally
            debug.dassert(self.hasSelection(), "moveEnd: can only cancel selection if one exists");
            self.resetSelection();
        }
        const c = &self.caret;
        const span = try self.lineSpan(c.pos.row);
        c.byte = span.start + span.len;
        c.pos.col = span.len;
        c.preferred_col = c.pos.col;
    }

    pub fn moveUp(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move up should move up from the anchor
            debug.dassert(self.hasSelection(), "moveUp: can only cancel selection if one exists");
            self.caret = self.anchor.?;
            self.resetSelection();
        }
        const c = &self.caret;
        if (c.pos.row == 0) {
            try self.moveHome(false);
            return;
        }
        c.pos.row -= 1;
        const span = try self.lineSpan(c.pos.row);
        c.pos.col = @min(c.preferred_col, span.len);
        c.byte = span.start + c.pos.col;
    }

    pub fn moveDown(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move down should move down from the caret
            debug.dassert(self.hasSelection(), "moveDown: can only cancel selection if one exists");
            self.resetSelection();
        }
        const c = &self.caret;
        if (c.pos.row + 1 >= self.lineCount()) {
            try self.moveEnd(false);
            return;
        }
        c.pos.row += 1;
        const span = try self.lineSpan(c.pos.row);
        c.pos.col = @min(c.preferred_col, span.len);
        c.byte = span.start + c.pos.col;
    }

    pub fn moveWordLeft(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move word left should behave normally
            debug.dassert(self.hasSelection(), "moveWordLeft: can only cancel selection if one exists");
            self.resetSelection();
        }
        const c = &self.caret;
        const at = self.prevWordBoundary(c.byte);
        c.byte = at;
        c.pos = try self.byteToPos(at);
        c.preferred_col = c.pos.col;
    }

    pub fn moveWordRight(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move word right should behave normally
            debug.dassert(self.hasSelection(), "moveWordRight: can only cancel selection if one exists");
            self.resetSelection();
        }
        const c = &self.caret;
        const at = self.nextWordBoundary(c.byte);
        c.byte = at;
        c.pos = try self.byteToPos(at);
        c.preferred_col = c.pos.col;
    }

    // selection handling

    pub fn startSelection(self: *Document) void {
        self.anchor = self.caret;
    }

    pub fn resetSelection(self: *Document) void {
        self.anchor = null;
    }

    pub fn hasSelection(self: *const Document) bool {
        return (self.anchor != null and self.anchor.?.byte != self.caret.byte);
    }

    pub fn selectionSpan(self: *const Document) ?Span {
        if (!self.hasSelection()) return null;
        const a = self.anchor.?.byte;
        const b = self.caret.byte;
        const start = if (a < b) a else b;
        const len = if (a < b) b - a else a - b;
        return .{ .start = start, .len = len };
    }

    pub fn selectWord(self: *Document) error{OutOfMemory}!void {
        const start = self.prevWordBoundary(self.caret.byte);
        const end = self.nextWordBoundary(self.caret.byte);
        // move caret to word start, copy it as the anchor
        self.caret.byte = start;
        self.caret.pos = try self.byteToPos(start);
        self.caret.preferred_col = self.caret.pos.col;
        self.anchor = self.caret;
        // move caret to word end
        self.caret.byte = end;
        self.caret.pos = try self.byteToPos(end);
        self.caret.preferred_col = self.caret.pos.col;
    }

    pub fn selectLine(self: *Document) error{OutOfMemory}!void {
        const span = try self.lineSpan(self.caret.pos.row);
        // if the line is empty, skip straight to document select
        if (self.buffer.peek(span.start) == '\n') {
            try self.selectDocument();
            return;
        }
        // move caret to line start, copy it as the anchor
        self.caret.byte = span.start;
        self.caret.pos = try self.byteToPos(span.start);
        self.caret.preferred_col = self.caret.pos.col;
        self.anchor = self.caret;
        // move caret to line end
        self.caret.byte = span.end();
        self.caret.pos = try self.byteToPos(span.end());
        self.caret.preferred_col = self.caret.pos.col;
    }

    pub fn selectDocument(self: *Document) error{OutOfMemory}!void {
        // move caret to document start
        self.caret.byte = 0;
        self.caret.pos = .{ .row = 0, .col = 0 };
        self.caret.preferred_col = self.caret.pos.col;
        self.anchor = self.caret;
        // move caret to document end
        self.caret.byte = self.size();
        self.caret.pos = try self.byteToPos(self.caret.byte);
        self.caret.preferred_col = self.caret.pos.col;
    }

    // materialization and span generation

    pub fn materializeRange(self: *Document, w: anytype, span: Span) !void {
        // pass-through method for materializing a range of bytes
        try self.buffer.materializeRange(w, span);
    }

    pub fn materialize(self: *Document, w: anytype) !void {
        // pass-through method for materializing a full document
        try self.buffer.materialize(w);
    }

    pub fn lineSpan(self: *Document, line: usize) error{OutOfMemory}!Span {
        const start = try self.lineStart(line);
        const end = try self.lineEnd(line);
        debug.dassert(end >= start, "line cannot have negative length");
        // subtracts newline for all lines except the last (no newline) and empty lines (0 length)
        const len = if (start < end and line + 1 < self.lineCount()) end - start - 1 else end - start;
        if (len > self.max_cols) self.max_cols = len;
        return .{ .start = start, .len = len };
    }

    // navigation helpers

    fn lineStart(self: *Document, line: usize) error{OutOfMemory}!usize {
        return self.buffer.byteOfLine(line);
    }

    fn lineEnd(self: *Document, line: usize) error{OutOfMemory}!usize {
        return if (line + 1 < self.lineCount()) self.buffer.byteOfLine(line + 1) else self.size();
    }

    // NOTE: both of these functions carry an implicit assumption that bytes == columns

    fn byteToPos(self: *Document, at: usize) error{OutOfMemory}!TextPos {
        debug.dassert(at <= self.size(), "index outside of document");
        // NOTE: this double traversal is technically unneccesary, but would require another big helper
        const line = try self.buffer.lineOfByte(at);
        const start = try self.buffer.byteOfLine(line);
        return .{ .row = line, .col = at - start };
    }

    fn posToByte(self: *Document, pos: TextPos) error{OutOfMemory}!usize {
        const span = try self.lineSpan(pos.row);
        debug.dassert(pos.col <= span.len, "column outside of line");
        const start = try self.buffer.byteOfLine(pos.row);
        return start + pos.col;
    }

    fn prevWordBoundary(self: *const Document, at: usize) usize {
        var i = at;
        while (i > 0 and classify(self.buffer.peek(i - 1)) == .space) : (i -= 1) {}
        if (i == 0) return 0;
        i -= 1;
        const class = classify(self.buffer.peek(i));
        if (class == .newline) return i + 1;
        while (i > 0 and classify(self.buffer.peek(i - 1)) == class) : (i -= 1) {}
        return i;
    }

    fn nextWordBoundary(self: *const Document, at: usize) usize {
        var i = at;
        const n = self.size();
        while (i < n and classify(self.buffer.peek(i)) == .space) : (i += 1) {}
        if (i == n) return i;
        const class = classify(self.buffer.peek(i));
        if (class == .newline) return i + 1;
        while (i < n and classify(self.buffer.peek(i)) == class) : (i += 1) {}
        return i;
    }
};

const WordClass = enum { space, ident, punct, newline };

fn classify(byte: u8) WordClass {
    const is_char = (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
    const is_digit = (byte >= '0' and byte <= '9');
    if (is_char or is_digit or byte == '_') return .ident;
    if (byte == '\r' or byte == '\n') return .newline;
    if (byte == ' ' or byte == '\t') return .space;
    return .punct;
}
