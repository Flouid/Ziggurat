const std = @import("std");
const debug = @import("debug");
const Span = @import("types").Span;

// The piece-table implementation for storing edits to a document efficiently in memory.
// This was a relatively simple first pass implementation to understand the idea and get it working.
// It's now kept as a correctness reference.
// This is easy to verify, so it is used to create ground truth test artifacts.

const BufferType = enum { original, add };

const Piece = struct {
    // one entry in the piece table.
    // pieces are a 3-tuple with
    //  1. buffer identifier
    //  2. starting index in source buffer
    //  3. sequence length
    // the working document can be assembled by iterating through the piece table
    // and concatenating the "pieces" from each buffer.
    buf: BufferType,
    off: usize,
    len: usize,
};

pub const TextBuffer = struct {
    // piece table collection object.
    // holds a pointer to the original document as well as a working append-only buffer.
    // holds a collection of ordered "pieces" which describe how to build a final document
    // using the two buffers.
    // Some scheme for efficiently mapping indices into the piece table is required.
    // current implementation maintains and uses a prefix sum and searches it in O(log n) time.
    // However, since the pieces are stored in array, insertions and deletions are O(n).
    original: []const u8,
    add: std.ArrayList(u8) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    prefix: std.ArrayList(usize) = .empty,
    doc_len: usize,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{OutOfMemory}!TextBuffer {
        var table = TextBuffer{ .original = original, .doc_len = original.len, .alloc = alloc };
        if (original.len == 0) return table; // empty document, no pieces
        try table.pieces.append(alloc, .{ .buf = .original, .off = 0, .len = original.len });
        try table.prefix.append(alloc, 0);
        return table;
    }

    pub fn deinit(self: *TextBuffer) void {
        self.add.deinit(self.alloc);
        self.pieces.deinit(self.alloc);
        self.prefix.deinit(self.alloc);
    }

    pub fn insert(self: *TextBuffer, at: usize, text: []const u8) error{OutOfMemory}!void {
        debug.dassert(at <= self.doc_len, "cannot insert outside of the document");
        debug.dassert(text.len > 0, "cannot insert empty text");
        // invariants, these are needed regardless of case
        const add_offset = self.add.items.len;
        try self.add.appendSlice(self.alloc, text);
        // case for empty doc
        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.alloc, .{ .buf = .add, .off = 0, .len = text.len });
            try self.prefix.append(self.alloc, 0);
            self.doc_len += text.len;
            return;
        }
        // simple case without search only for appending at the end when last piece is the end of the add buffer.
        if (at == self.doc_len) {
            const last_piece = &self.pieces.items[self.pieces.items.len - 1];
            // imagine you append "abc" to the doc, then "x" to the start.
            // the add buffer now contains "abcx", but the last piece will be "abc"
            // the "x" in that example means you can't assume the bytes are contiguous unless you check
            if (last_piece.buf == .add and last_piece.off + last_piece.len == add_offset) {
                last_piece.len += text.len;
                self.doc_len += text.len;
                return;
            }
        }
        // locate the piece containing the split position
        var idx = self.findPiece(at);
        // split the existing piece into a prefix and posfix
        const old = self.pieces.items[idx];
        const start_idx = self.prefix.items[idx];
        const len_prefix = at - start_idx;
        var prefix = old;
        var posfix = old;
        prefix.len = len_prefix;
        posfix.off += len_prefix;
        posfix.len -= len_prefix;
        // build 1-3 replacement pieces and insert them into the piece table
        var buf: [3]Piece = undefined;
        var n: usize = 0;
        if (prefix.len != 0) {
            buf[n] = prefix;
            n += 1;
        }
        buf[n] = .{ .buf = .add, .off = add_offset, .len = text.len };
        n += 1;
        if (posfix.len != 0) {
            buf[n] = posfix;
            n += 1;
        }
        self.pieces.items[idx] = buf[0];
        if (n >= 2) try self.pieces.insertSlice(self.alloc, idx + 1, buf[1..n]);
        self.doc_len += text.len;
        // see if there are any pieces than can be merged, then rebuild the prefix
        idx = self.mergeAround(idx);
        try self.rebuildPrefix(idx);
    }

    pub fn delete(self: *TextBuffer, span: Span) error{OutOfMemory}!void {
        debug.dassert(span.end() <= self.doc_len, "cannot delete outside of document");
        debug.dassert(span.len > 0, "cannot delete 0 characters");
        debug.dassert(self.pieces.items.len > 0, "cannot delete from empty document");
        var idx = self.findPiece(span.start);
        const old = &self.pieces.items[idx];
        const start_idx = self.prefix.items[idx];
        const len_prefix = span.start - start_idx;
        // case 1: deletion localized in a single piece
        if (span.len <= old.len - len_prefix) {
            const len_posfix = old.len - len_prefix - span.len;
            // delete the entire piece
            if (len_prefix == 0 and len_posfix == 0) {
                _ = self.pieces.orderedRemove(idx);
            }
            // keep just the prefix
            else if (len_prefix > 0 and len_posfix == 0) {
                old.len = len_prefix;
            }
            // keep just the posfix
            else if (len_prefix == 0 and len_posfix > 0) {
                old.off += span.len;
                old.len = len_posfix;
            }
            // split piece into prefix and posfix
            else {
                old.len = len_prefix;
                const posfix = Piece{ .buf = old.buf, .off = old.off + len_prefix + span.len, .len = len_posfix };
                try self.pieces.insert(self.alloc, idx + 1, posfix);
            }
        }
        // case 2: deletion spans multiple pieces
        else {
            var remain = span.len;
            // lucky edge case: deletion lines up with current piece start
            if (len_prefix == 0) {
                remain -= old.len;
                _ = self.pieces.orderedRemove(idx);
                // general case: some prefix is left over, modify the current piece in-place
            } else {
                remain -= old.len - len_prefix;
                old.len = len_prefix;
                idx += 1;
            }
            // delete pieces until there are no characters left to delete
            while (remain > 0) {
                const curr = &self.pieces.items[idx];
                if (remain >= curr.len) {
                    remain -= curr.len;
                    // NOTE: SLOW! Repeated O(n) deletions
                    _ = self.pieces.orderedRemove(idx);
                } else {
                    curr.off += remain;
                    curr.len -= remain;
                    remain = 0;
                }
            }
        }
        self.doc_len -= span.len;
        // last piece deleted, early return
        if (self.pieces.items.len == 0) {
            try self.rebuildPrefix(0);
            return;
        }
        // deleted pieces at the end, clamp idx down for merging and rebuilding
        if (idx >= self.pieces.items.len) idx = self.pieces.items.len - 1;
        idx = self.mergeAround(idx);
        try self.rebuildPrefix(idx);
    }

    pub fn materialize(self: *const TextBuffer, w: anytype) !void {
        // given any generic writing interface, stream the full working document
        for (self.pieces.items) |piece| {
            const src = switch (piece.buf) {
                .original => self.original,
                .add => self.add.items,
            };
            debug.dassert(piece.off <= src.len, "piece offset must be inside it's source buffer");
            debug.dassert(piece.len <= src.len - piece.off, "full piece slice must be inside source buffer");
            try w.writeAll(src[piece.off .. piece.off + piece.len]);
        }
    }

    pub fn ensureScanned(self: *TextBuffer, line: usize) error{OutOfMemory}!void {
        // match API with the current faster text buffer, this is a noop here thop
        _ = self;
        _ = line;
    }

    fn findPiece(self: *const TextBuffer, idx: usize) usize {
        // given an index into the WORKING DOCUMENT, find the index of the piece that index belongs to.
        // do this via a bog-standard O(log n) binary search
        debug.dassert(idx <= self.doc_len, "cannot find piece for index outside working document");
        debug.dassert(self.pieces.items.len > 0, "document must contain at least one piece to find");
        debug.dassert(self.prefix.items.len == self.pieces.items.len, "number of pieces and prefixes must match");
        debug.dassert(self.prefix.items[0] == 0, "first element of prefix must be 0");
        var lo: usize = 0;
        var hi: usize = self.pieces.items.len;
        while (lo + 1 < hi) {
            const mid = lo + ((hi - lo) >> 1);
            if (self.prefix.items[mid] <= idx) lo = mid else hi = mid;
        }
        return lo;
    }

    fn rebuildPrefix(self: *TextBuffer, from: usize) error{OutOfMemory}!void {
        // inserting in the middle of the piece table invalidates the prefix array AFTER the insertion point.
        // starting from the insertion point, rebuild the prefix array.
        try self.prefix.resize(self.alloc, self.pieces.items.len);
        if (self.pieces.items.len == 0) return;
        if (from == 0) self.prefix.items[0] = 0;
        var i: usize = if (from == 0) 1 else from;
        while (i < self.pieces.items.len) : (i += 1) {
            self.prefix.items[i] = self.prefix.items[i - 1] + self.pieces.items[i - 1].len;
        }
    }

    fn canMerge(self: *TextBuffer, a: usize, b: usize) bool {
        // given an index to a "left" and "right" piece, see if they are contiguous and from the same buffer
        debug.dassert(a < self.pieces.items.len, "left merge must be inside piece table");
        debug.dassert(b < self.pieces.items.len, "right merge must be inside piece table");
        const piece_a = self.pieces.items[a];
        const piece_b = self.pieces.items[b];
        return piece_a.buf == piece_b.buf and piece_a.off + piece_a.len == piece_b.off;
    }

    fn merge(self: *TextBuffer, a: usize, b: usize) void {
        // merge two pieces by summing their lengths into the left one and deleting the right
        self.pieces.items[a].len += self.pieces.items[b].len;
        _ = self.pieces.orderedRemove(b);
    }

    fn mergeAround(self: *TextBuffer, idx: usize) usize {
        // given a "center" index, attempt to merge it's left and right neighbors
        debug.dassert(idx < self.pieces.items.len, "merge index must be inside piece table");
        var i = idx;
        if (i > 0 and self.canMerge(i - 1, i)) {
            self.merge(i - 1, i);
            i -= 1;
        }
        if (i + 1 < self.pieces.items.len and self.canMerge(i, i + 1)) self.merge(i, i + 1);
        // the center index might have changed, so return it for rebuilding the prefix
        return i;
    }
};
