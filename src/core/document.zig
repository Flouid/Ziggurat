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

    const begin: Caret = .{ .byte = 0, .pos = .{ .row = 0, .col = 0 } };
};

pub const Selection = struct {
    // the logical selection inside the document at any given moment
    anchor: ?Caret,
    caret: Caret,
    preferred_col: usize,

    pub const begin: Selection = .{ .anchor = null, .caret = .begin, .preferred_col = 0 };

    pub fn active(self: *const Selection) bool {
        return self.anchor != null and self.anchor.?.byte != self.caret.byte;
    }

    pub fn dropAnchor(self: *Selection) void {
        self.anchor = self.caret;
    }

    pub fn resetAnchor(self: *Selection) void {
        self.anchor = null;
    }

    pub fn resetPreferredCol(self: *Selection) void {
        self.preferred_col = self.caret.pos.col;
    }

    pub fn span(self: *const Selection) ?Span {
        if (!self.active()) return null;
        const a = self.anchor.?.byte;
        const b = self.caret.byte;
        const start = if (a < b) a else b;
        const len = if (a < b) b - a else a - b;
        return .{ .start = start, .len = len };
    }
};

pub const Document = struct {
    buffer: TextBuffer,
    sel: Selection = .begin,
    src: []const u8,
    alloc: std.mem.Allocator,
    max_cols: usize = 0,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{ OutOfMemory, FileTooBig }!Document {
        return .{
            .buffer = try TextBuffer.init(alloc, original),
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
        if (self.sel.active()) try self.caretBackspace();
        // update the text buffer
        try self.buffer.insert(self.sel.caret.byte, text);
        // update the cursor cheaply
        const c = &self.sel.caret;
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
        self.sel.resetPreferredCol();
    }

    pub fn caretBackspace(self: *Document) error{OutOfMemory}!void {
        // default case, delete from the caret and one at a time
        var c = self.sel.caret;
        var take: usize = 1;
        // handle selections
        if (self.sel.span()) |span| {
            // if caret is behind span start, delete from the start instead
            if (self.sel.anchor.?.byte > c.byte) c = self.sel.anchor.?;
            take = span.len;
        }
        // special case, delete entire document
        if (take == self.size()) {
            try self.buffer.reset();
            self.sel = .begin;
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
        self.sel.caret = c;
        self.sel.resetPreferredCol();
        self.sel.resetAnchor();
    }

    // cursor traversal

    pub fn moveTo(self: *Document, pos: TextPos) error{OutOfMemory}!void {
        const c = &self.sel.caret;
        c.byte = try self.posToByte(pos);
        c.pos = pos;
        self.sel.resetPreferredCol();
    }

    pub fn moveLeft(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move left should just put the caret at the anchor position
            debug.dassert(self.sel.active(), "moveLeft: can only cancel selection if one exists");
            self.sel.caret = self.sel.anchor.?;
            self.sel.resetPreferredCol();
            return;
        }
        const c = &self.sel.caret;
        if (c.byte == 0) return;
        c.byte -= 1;
        if (c.pos.col > 0) {
            c.pos.col -= 1;
        } else c.pos = try self.byteToPos(c.byte);
        self.sel.resetPreferredCol();
    }

    pub fn moveRight(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move right should just clear the selection without moving
            debug.dassert(self.sel.active(), "moveRight: can only cancel selection if one exists");
            self.sel.resetAnchor();
            return;
        }
        const c = &self.sel.caret;
        if (c.byte >= self.size()) return;
        const line_end = try self.lineEnd(c.pos.row);
        // move to next line, account for EOF special case
        if (c.byte + 1 == line_end and line_end < self.size()) {
            c.pos.row += 1;
            c.pos.col = 0;
        } else c.pos.col += 1;
        c.byte += 1;
        self.sel.resetPreferredCol();
    }

    pub fn moveHome(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move home should just clear the selection before moving normally
            debug.dassert(self.sel.active(), "moveHome: can only cancel selection if one exists");
            self.sel.resetAnchor();
        }
        const c = &self.sel.caret;
        c.byte = try self.lineStart(c.pos.row);
        c.pos.col = 0;
        self.sel.resetPreferredCol();
    }

    pub fn moveEnd(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move end should just clear the selection before moving normally
            debug.dassert(self.sel.active(), "moveEnd: can only cancel selection if one exists");
            self.sel.resetAnchor();
        }
        const c = &self.sel.caret;
        const span = try self.lineSpan(c.pos.row);
        c.byte = span.start + span.len;
        c.pos.col = span.len;
        self.sel.resetPreferredCol();
    }

    pub fn moveUp(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move up should move up from the anchor
            debug.dassert(self.sel.active(), "moveUp: can only cancel selection if one exists");
            self.sel.caret = self.sel.anchor.?;
            self.sel.resetAnchor();
            self.sel.resetPreferredCol();
        }
        const c = &self.sel.caret;
        if (c.pos.row == 0) {
            try self.moveHome(false);
            return;
        }
        c.pos.row -= 1;
        const span = try self.lineSpan(c.pos.row);
        c.pos.col = @min(self.sel.preferred_col, span.len);
        c.byte = span.start + c.pos.col;
    }

    pub fn moveDown(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move down should move down from the caret
            debug.dassert(self.sel.active(), "moveDown: can only cancel selection if one exists");
            self.sel.resetAnchor();
        }
        const c = &self.sel.caret;
        if (c.pos.row + 1 >= self.lineCount()) {
            try self.moveEnd(false);
            return;
        }
        c.pos.row += 1;
        const span = try self.lineSpan(c.pos.row);
        c.pos.col = @min(self.sel.preferred_col, span.len);
        c.byte = span.start + c.pos.col;
    }

    pub fn moveWordLeft(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move word left should behave normally
            debug.dassert(self.sel.active(), "moveWordLeft: can only cancel selection if one exists");
            self.sel.resetAnchor();
        }
        const c = &self.sel.caret;
        const at = self.prevWordBoundary(c.byte);
        c.byte = at;
        c.pos = try self.byteToPos(at);
        self.sel.resetPreferredCol();
    }

    pub fn moveWordRight(self: *Document, cancel_select: bool) error{OutOfMemory}!void {
        if (cancel_select) {
            // a selection cancelling move word right should behave normally
            debug.dassert(self.sel.active(), "moveWordRight: can only cancel selection if one exists");
            self.sel.resetAnchor();
        }
        const c = &self.sel.caret;
        const at = self.nextWordBoundary(c.byte);
        c.byte = at;
        c.pos = try self.byteToPos(at);
        self.sel.resetPreferredCol();
    }

    // selection handling

    pub fn selectWord(self: *Document) error{OutOfMemory}!void {
        const start = self.prevWordBoundary(self.sel.caret.byte);
        const end = self.nextWordBoundary(self.sel.caret.byte);
        // move caret to word start, copy it as the anchor
        self.sel.caret.byte = start;
        self.sel.caret.pos = try self.byteToPos(start);
        self.sel.dropAnchor();
        // move caret to word end
        self.sel.caret.byte = end;
        self.sel.caret.pos = try self.byteToPos(end);
        self.sel.resetPreferredCol();
    }

    pub fn selectLine(self: *Document) error{OutOfMemory}!void {
        const span = try self.lineSpan(self.sel.caret.pos.row);
        // if the line is empty, skip straight to document select
        if (self.buffer.peek(span.start) == '\n') {
            try self.selectDocument();
            return;
        }
        // move caret to line start, copy it as the anchor
        self.sel.caret.byte = span.start;
        self.sel.caret.pos = try self.byteToPos(span.start);
        self.sel.dropAnchor();
        // move caret to line end
        self.sel.caret.byte = span.end();
        self.sel.caret.pos = try self.byteToPos(span.end());
        self.sel.resetPreferredCol();
    }

    pub fn selectDocument(self: *Document) error{OutOfMemory}!void {
        // move anchor to document start
        self.sel.anchor = .begin;
        // move caret to document end
        self.sel.caret.byte = self.size();
        self.sel.caret.pos = try self.byteToPos(self.sel.caret.byte);
        self.sel.resetPreferredCol();
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
        var end = try self.lineEnd(line);
        debug.dassert(end >= start, "line cannot have negative length");
        // subtracts any newline characters from the end
        while (end > start) : (end -= 1) {
            const b = self.buffer.peek(end - 1);
            if (b != '\n' and b != '\r') break;
        }
        const len = end - start;
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

    pub fn byteToPos(self: *Document, at: usize) error{OutOfMemory}!TextPos {
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
