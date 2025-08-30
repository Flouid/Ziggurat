const std = @import("std");
const debug = @import("debug");
const utils = @import("utils");

// The piece-tree implementation for storing edits to a document efficiently in memory.
// There are two distinct but highly coupled data structures implemented here.
// Top-level is a piece tree, but storing pieces in an array is SLOW! O(P)
// Pieces are stored in a rope implemented as a b-tree.
// With P = # pieces:
//   Locate index -> leaf:  O(log_{MIN_BRANCH} P)
//   Point edit (insert/delete at one index):
//     - Leaf mutation:     O(MAX_PIECES)
//     - Rebalance path:    O(log_{MIN_BRANCH} P * MAX_BRANCH)
//     => Overall:          O(log_{MIN_BRANCH} P) with small constants
//   Range edit spanning t pieces: O(log_{MIN_BRANCH} P + t)

// public interface at the top

pub const TextBuffer = struct {
    // The text buffer is a b-tree of pieces.
    // Holds a pointer to the original document as well as a working append-only buffer.
    // Holds a collection of ordered "pieces" which describe how to build a final document using the two buffers.
    // In order to find any given piece in O(log n) time, the collection of pieces is a tree.
    original: []const u8,
    add: std.ArrayList(u8) = .empty,
    o_idx: NewLineIndex = .{},
    a_idx: NewLineIndex = .{},
    root: *Node,
    doc_len: usize,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{ OutOfMemory, FileTooBig }!TextBuffer {
        // enforce the assertion about maximum file sizes even in release modes.
        const limit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
        if (original.len >= limit) return error.FileTooBig;
        // initialize the root of the tree
        const leaf = try initLeaf(alloc);
        if (original.len > 0) {
            try leafPieces(leaf).append(alloc, Piece.init(.Original, original.len, 0));
            leaf.weight_bytes = original.len;
        }
        var engine = TextBuffer{
            .original = original,
            .root = leaf,
            .doc_len = original.len,
            .alloc = alloc,
        };
        if (original.len > 0) leaf.weight_lines = try engine.o_idx.countRange(alloc, original, 0, original.len);
        return engine;
    }

    pub fn deinit(self: *TextBuffer) void {
        self.add.deinit(self.alloc);
        self.o_idx.deinit(self.alloc);
        self.a_idx.deinit(self.alloc);
        freeTree(self.alloc, self.root);
    }

    pub fn insert(self: *TextBuffer, at: usize, text: []const u8) error{OutOfMemory}!void {
        debug.dassert(at <= self.doc_len, "cannot insert outside of the document.");
        debug.dassert(text.len > 0, "cannot insert empty text");
        const add_offset = self.add.items.len;
        try self.add.appendSlice(self.alloc, text);
        // count how many newlines just got added
        const newlines = try self.a_idx.countRange(self.alloc, self.add.items, add_offset, text.len);
        // find the leaf node that corresponds to the insertion index
        const found = findAt(self.root, at);
        const leaf = found.leaf;
        const pieces = leafPieces(leaf);
        // under the ideal case, new edits are appended to the end and extend an existing piece
        if (fastAppendIfPossible(leaf, add_offset, text.len, at, self.doc_len)) {
            bubbleByteDelta(leaf, text.len, false);
            bubbleLineDelta(leaf, newlines, false);
            self.doc_len += text.len;
            return;
        }
        const loc = locateInLeaf(leaf, found.offset);
        const idx = try spliceIntoLeaf(pieces, self.alloc, loc, add_offset, text.len);
        mergeAround(leaf, idx);
        bubbleByteDelta(leaf, text.len, false);
        bubbleLineDelta(leaf, newlines, false);
        try self.bubbleOverflowUp(leaf);
        self.doc_len += text.len;
    }

    pub fn delete(self: *TextBuffer, at: usize, len: usize) error{OutOfMemory}!void {
        debug.dassert(at + len <= self.doc_len, "cannot delete outside of document");
        debug.dassert(len > 0, "cannot delete empty span");
        var remaining = len;
        const found = findAt(self.root, at);
        var leaf = found.leaf;
        var offset = found.offset;
        const left: *Node = leaf;
        while (remaining > 0) {
            const in_leaf = locateInLeaf(leaf, offset);
            const removed = try self.deleteFromLeaf(leaf, in_leaf, remaining);
            bubbleByteDelta(leaf, removed.bytes, true);
            bubbleLineDelta(leaf, removed.lines, true);
            remaining -= removed.bytes;
            offset = 0;
            const next_leaf = nextLeaf(leaf);
            if (remaining > 0) {
                debug.dassert(next_leaf != null, "reached rightmost leaf with non-empty deletion queue");
                leaf = next_leaf.?;
            }
        }
        try self.repairAfterDelete(left, leaf);
        self.doc_len -= len;
    }

    pub fn lineOfByte(self: *TextBuffer, at: usize) error{OutOfMemory}!usize {
        // map any index in the working document to a line number
        debug.dassert(at <= self.doc_len, "offset out of range");
        if (at == self.doc_len) return self.root.weight_lines;
        var node = self.root;
        var offset = at;
        var lines_before: usize = 0;
        var iter: usize = 0;
        while (iter < MAX_ITER) : (iter += 1) {
            switch (node.children) {
                .leaf => {
                    // count newlines in all full pieces before the offset
                    const pieces = leafPiecesConst(node).items;
                    var acc: usize = 0;
                    var i: usize = 0;
                    while (i < pieces.len and acc + pieces[i].len() <= offset) : (i += 1) {
                        lines_before += try self.countLinesInPiece(&pieces[i]);
                        acc += pieces[i].len();
                    }
                    debug.dassert(i < pieces.len, "failed to find line");
                    // add newlines inside the piece up to our offset
                    lines_before += try self.countLinesInPieceRange(&pieces[i], 0, offset - acc);
                    return lines_before;
                },
                .internal => |*children| {
                    var i: usize = 0;
                    while (i < children.items.len) : (i += 1) {
                        const child = children.items[i];
                        if (offset < child.weight_bytes) {
                            node = child;
                            break;
                        }
                        offset -= child.weight_bytes;
                        lines_before += child.weight_lines;
                    }
                    debug.dassert(i < children.items.len, "failed to find line");
                },
            }
        }
        @panic("max iterations reached without finding index in document");
    }

    pub fn byteOfLine(self: *TextBuffer, line: usize) error{OutOfMemory}!usize {
        // map any line number to an index in the working document
        debug.dassert(line <= self.root.weight_lines, "line out of range");
        var node = self.root;
        var remaining = line;
        var offset: usize = 0;
        var iter: usize = 0;
        while (iter < MAX_ITER) : (iter += 1) {
            switch (node.children) {
                .leaf => {
                    const pieces = leafPiecesConst(node).items;
                    var acc: usize = 0;
                    var i: usize = 0;
                    while (i < pieces.len and remaining > 0) : (i += 1) {
                        const piece = &pieces[i];
                        const lines_in_piece = try self.countLinesInPiece(piece);
                        if (remaining <= lines_in_piece) {
                            return offset + acc + (try self.findNthNewlineInPiece(piece, remaining)) + 1;
                        } else {
                            remaining -= lines_in_piece;
                            acc += piece.len();
                        }
                    }
                    // edge case, newline at the very end of the piece
                    return offset + acc;
                },
                .internal => |*children| {
                    var i: usize = 0;
                    while (i < children.items.len) : (i += 1) {
                        const child = children.items[i];
                        if (remaining <= child.weight_lines) {
                            node = child;
                            break;
                        }
                        remaining -= child.weight_lines;
                        offset += child.weight_bytes;
                    }
                    debug.dassert(i < children.items.len, "failed to find line");
                },
            }
        }
        @panic("max iterations reached without finding line in document");
    }

    pub fn peek(self: *const TextBuffer, at: usize) u8 {
        debug.dassert(at < self.doc_len, "peek out of bounds");
        const found = findAt(self.root, at);
        const loc = locateInLeaf(found.leaf, found.offset);
        const piece = leafPiecesConst(found.leaf).items[loc.piece_idx];
        const src = switch (piece.buf()) {
            .Original => self.original,
            .Add => self.add.items,
        };
        const pos = piece.off + loc.offset;
        debug.dassert(pos < src.len, "piece offset outside of source buffer");
        return src[pos]; 
    }

    pub fn materializeRange(self: *TextBuffer, w: anytype, start: usize, len: usize) !void {
        // when a view should be written directly to a writer
        if (len == 0) return;
        var it = self.getSliceIter(start, len);
        while (it.next()) |slice| try w.writeAll(slice);
    }

    pub fn materialize(self: *TextBuffer, w: anytype) !void {
        // when the entire document should be written directly to a writer (e.g. saving)
        try self.materializeRange(w, 0, self.doc_len);
    }

    pub fn getSliceIter(self: *TextBuffer, start: usize, len: usize) SliceIter {
        debug.dassert(start + len <= self.doc_len, "view out of bounds");
        debug.dassert(len > 0, "cannot provide an empty view");
        return SliceIter.init(self, start, len);
    }

    // -------------------- EVERYTHING BENEATH THIS LINE IS A PRIVATE IMPLEMENTATION DETAIL --------------------

    // -------------------- INSERT HELPERS --------------------

    fn bubbleOverflowUp(self: *TextBuffer, start: *Node) error{OutOfMemory}!void {
        // It's possible that a node split overflows it's parent, which splits and overflows IT'S parent...
        // Thus the logic needs to "bubble up" from the bottom of the tree until splits stop happening
        var cur: ?*Node = start;
        while (cur) |n| {
            const parent = try self.splitNodeIfOverflow(n);
            if (parent == null) return;
            cur = parent;
        }
    }

    fn splitNodeIfOverflow(self: *TextBuffer, node: *Node) error{OutOfMemory}!?*Node {
        // this function will look at ANY node and perform the following logic:
        //  1. if this node has less than the maximum number of children, do nothing
        //  2. if it DOES have less than the max, split it in half into a new node
        //  3. if it has a parent, it adds the new node as a sibling AND RETURNS IT
        //  4. if it doesn't have a parent, it creates a new internal node as root
        // if this function returns a non-null value, then parents must also be checked for overflow.
        // is agnostic to leaf/internal nodes, but the implementations are fairly different.
        switch (node.children) {
            .leaf => |*pieces| {
                if (pieces.items.len <= MAX_PIECES) return null;
                // split half of the pieces into a new sibling
                const mid = pieces.items.len / 2;
                const right = try initLeaf(self.alloc);
                // calculate exactly how many bytes and lines are moving
                const to_move = pieces.items[mid..];
                const moved = try self.countMovedPieces(to_move);
                // move them
                try leafPieces(right).appendSlice(self.alloc, to_move);
                pieces.shrinkRetainingCapacity(mid);
                // manually adjust node weights, faster than a full recompute
                debug.dassert(node.weight_bytes >= moved.bytes, "leaf split byte size underflow");
                debug.dassert(node.weight_lines >= moved.lines, "leaf split line size underflow");
                node.weight_bytes -= moved.bytes;
                node.weight_lines -= moved.lines;
                right.weight_bytes = moved.bytes;
                right.weight_lines = moved.lines;
                // add the newly split node into the tree
                return self.spliceNodeInTree(node, right);
            },
            .internal => |*children| {
                // same as leaf case above, but just different enough to not be one function call
                if (children.items.len <= MAX_BRANCH) return null;
                const mid = children.items.len / 2;
                const right = try initInternal(self.alloc);
                const to_move = children.items[mid..];
                const moved = countMovedNodes(to_move);
                try childList(right).appendSlice(self.alloc, to_move);
                children.shrinkRetainingCapacity(mid);
                // fix parent pointers
                for (childList(right).items) |child| child.parent = right;
                debug.dassert(node.weight_bytes >= moved.bytes, "node split byte size underflow");
                debug.dassert(node.weight_lines >= moved.lines, "node split line size underflow");
                node.weight_bytes -= moved.bytes;
                node.weight_lines -= moved.lines;
                right.weight_bytes = moved.bytes;
                right.weight_lines = moved.lines;
                return self.spliceNodeInTree(node, right);
            },
        }
    }

    fn spliceNodeInTree(self: *TextBuffer, old: *Node, new: *Node) error{OutOfMemory}!?*Node {
        // general case, add the new node one to the right of the old
        if (old.parent) |parent| {
            const siblings = childList(parent);
            const idx = indexOfChild(siblings.items, old);
            try siblings.insert(self.alloc, idx + 1, new);
            new.parent = parent;
            return parent;
            // edge case, old node was the root, create a new root and create both as siblings
        } else {
            const root = try initInternal(self.alloc);
            try childList(root).append(self.alloc, old);
            try childList(root).append(self.alloc, new);
            old.parent = root;
            new.parent = root;
            root.weight_bytes = old.weight_bytes + new.weight_bytes;
            root.weight_lines = old.weight_lines + new.weight_lines;
            self.root = root;
            return null;
        }
    }

    // -------------------- DELETE HELPERS --------------------

    const DeleteResult = struct { bytes: usize, lines: usize };

    fn deleteFromLeaf(self: *TextBuffer, leaf: *Node, start: InLeaf, max_remove: usize) error{OutOfMemory}!DeleteResult {
        // attempt to delete at most max_remove bytes from the current leaf.
        // return the total number that could be deleted, deletion may go into another node.
        var pieces = leafPieces(leaf);
        var removed_bytes: usize = 0;
        var removed_lines: usize = 0;
        var piece_idx = start.piece_idx;
        const prefix_len = start.offset;
        if (piece_idx >= pieces.items.len) return .{ .bytes = 0, .lines = 0 };
        // handle the current (first) piece
        var piece = &pieces.items[piece_idx];
        var take = @min(max_remove, piece.len() - prefix_len);
        // if we can't just delete the entire thing
        if (prefix_len > 0 or take < piece.len()) {
            removed_lines += try self.countLinesInPieceRange(piece, prefix_len, take);
            const suffix_len = piece.len() - prefix_len - take;
            // delete lands in the middle of the piece
            if (prefix_len > 0 and suffix_len > 0) {
                piece.setLen(prefix_len);
                var suffix = piece.*;
                suffix.off += prefix_len + take;
                suffix.setLen(suffix_len);
                try pieces.insert(self.alloc, piece_idx + 1, suffix);
                piece_idx += 1;
                // there is no suffix, trim the front
            } else if (prefix_len > 0) {
                piece.setLen(prefix_len);
                piece_idx += 1;
            }
            // there is no prefix, trim the tail
            else {
                piece.off += take;
                piece.setLen(suffix_len);
            }
            removed_bytes += take;
        }
        // if applicable, remove entire middle pieces, coalesce into one big delete at the end
        var end_range = piece_idx;
        while (end_range < pieces.items.len and removed_bytes < max_remove) : (end_range += 1) {
            piece = &pieces.items[end_range];
            const can_take = @min(piece.len(), max_remove - removed_bytes);
            if (can_take < piece.len()) break;
            removed_bytes += piece.len();
            removed_lines += try self.countLinesInPiece(piece);
        }
        if (end_range > piece_idx) utils.orderedRemoveRange(Piece, pieces, piece_idx, end_range - piece_idx);
        // we may still need to remove the front of one final piece
        if (piece_idx < pieces.items.len and removed_bytes < max_remove) {
            piece = &pieces.items[piece_idx];
            take = max_remove - removed_bytes;
            removed_lines += try self.countLinesInPieceRange(piece, 0, take);
            piece.off += take;
            piece.shrinkBy(take);
            removed_bytes += take;
        }
        // if there are still pieces left, perform a local coalesce before returning
        const removed = DeleteResult{ .bytes = removed_bytes, .lines = removed_lines };
        if (pieces.items.len == 0) return removed;
        if (piece_idx == pieces.items.len) piece_idx -= 1;
        mergeAround(leaf, piece_idx);
        return removed;
    }

    fn transferRangeBetweenSiblings(self: *TextBuffer, src: *Node, dst: *Node, start: usize, count: usize, side: enum { Front, Back }) error{OutOfMemory}!void {
        debug.dassert(count > 0, "cannot transfer 0 nodes between siblings");
        debug.dassert(std.meta.activeTag(src.children) == std.meta.activeTag(dst.children), "source and destination must be the same type of node");
        debug.dassert(start == 0 or start + count == nodeCount(src), "insertions must be contiguous with start or end of source");
        switch (src.children) {
            .leaf => {
                const src_pieces = leafPieces(src);
                const dst_pieces = leafPieces(dst);
                debug.dassert(src_pieces.items.len >= count, "source must contain enough items to transfer");
                debug.dassert(dst_pieces.items.len > 0, "destination must not start empty");
                // calculate exactly how many bytes and lines are moving
                const to_move = src_pieces.items[start .. start + count];
                const moved = try self.countMovedPieces(to_move);
                switch (side) {
                    .Front => try dst_pieces.insertSlice(self.alloc, 0, to_move),
                    .Back => try dst_pieces.appendSlice(self.alloc, to_move),
                }
                _ = utils.orderedRemoveRange(Piece, src_pieces, start, count);
                // check for new merge opportunities
                const center: usize = switch (side) {
                    .Front => count,
                    .Back => dst_pieces.items.len - count,
                };
                mergeAround(dst, center);
                bubbleByteDelta(src, moved.bytes, true);
                bubbleByteDelta(dst, moved.bytes, false);
                bubbleLineDelta(src, moved.lines, true);
                bubbleLineDelta(dst, moved.lines, false);
            },
            .internal => {
                const src_children = childList(src);
                const dst_children = childList(dst);
                debug.dassert(src_children.items.len >= count, "source must contain enough items to transfer");
                debug.dassert(dst_children.items.len > 0, "destination must not start empty");
                // calculate exactly how many bytes and lines are moving
                const to_move = src_children.items[start .. start + count];
                const moved = countMovedNodes(to_move);
                switch (side) {
                    .Front => try dst_children.insertSlice(self.alloc, 0, to_move),
                    .Back => try dst_children.appendSlice(self.alloc, to_move),
                }
                _ = utils.orderedRemoveRange(*Node, src_children, start, count);
                // fix parent pointers for moved children
                const adopted = switch (side) {
                    .Front => dst_children.items[0..count],
                    .Back => dst_children.items[dst_children.items.len - count ..],
                };
                for (adopted) |child| child.parent = dst;
                bubbleByteDelta(src, moved.bytes, true);
                bubbleByteDelta(dst, moved.bytes, false);
                bubbleLineDelta(src, moved.lines, true);
                bubbleLineDelta(dst, moved.lines, false);
            },
        }
    }

    fn tryBorrow(self: *TextBuffer, node: *Node, siblings: Siblings) error{OutOfMemory}!usize {
        // uses a borrow plan to take exactly as many nodes from neighbors as can be spared
        const plan = planBorrow(node, siblings);
        if (siblings.l) |left| {
            if (plan.take_left > 0) {
                try self.transferRangeBetweenSiblings(left, node, nodeCount(left) - plan.take_left, plan.take_left, .Front);
            }
        }
        if (siblings.r) |right| {
            if (plan.take_right > 0) {
                try self.transferRangeBetweenSiblings(right, node, 0, plan.take_right, .Back);
            }
        }
        return plan.take_left + plan.take_right;
    }

    fn repairAfterDelete(self: *TextBuffer, left: *Node, right: *Node) error{OutOfMemory}!void {
        try self.repairUpward(left);
        if (left != right) try self.repairUpward(right);
        // checks for cases where the root node is no longer needed and collapses if necessary
        switch (self.root.children) {
            .leaf => {},
            .internal => |*children| {
                if (children.items.len == 0) {
                    // internal node with no children becomes a leaf
                    const leaf = try initLeaf(self.alloc);
                    freeNode(self.alloc, self.root);
                    self.root = leaf;
                } else if (children.items.len == 1) {
                    // internal node with one child is replaced by that child
                    const child = children.items[0];
                    child.parent = null;
                    freeNode(self.alloc, self.root);
                    self.root = child;
                }
            },
        }
    }

    fn repairUpward(self: *TextBuffer, start: *Node) error{OutOfMemory}!void {
        var cur: ?*Node = start;
        while (cur) |node| {
            if (node.parent == null) return;
            // make next decisions based on how many children this node has
            const count = nodeCount(node);
            const min = nodeMin(node);
            if (count == 0) {
                const parent = node.parent.?;
                self.infanticide(parent, node);
                cur = parent;
            } else if (count < min) {
                // the node has less than the minimum amount of children...
                const demand = min - count;
                const siblings = getSiblings(node);
                // attempt to merge with neighbors
                if (siblings.l) |left| {
                    if (try self.mergeWithSibling(node, left)) |parent| {
                        cur = parent;
                        continue;
                    }
                }
                if (siblings.r) |right| {
                    if (try self.mergeWithSibling(right, node)) |parent| {
                        cur = parent;
                        continue;
                    }
                }
                // failing that, try and borrow children
                const borrowed = try self.tryBorrow(node, siblings);
                if (borrowed >= demand) {
                    cur = node.parent;
                    continue;
                }
            }
            cur = node.parent;
        }
    }

    fn infanticide(self: *TextBuffer, parent: *Node, child: *Node) void {
        // metal
        const siblings = childList(parent);
        const idx = indexOfChild(siblings.items, child);
        _ = siblings.orderedRemove(idx);
        freeTree(self.alloc, child);
    }

    fn mergeWithSibling(self: *TextBuffer, src: *Node, dst: *Node) error{OutOfMemory}!?*Node {
        if (nodeCount(src) + nodeCount(dst) > nodeMax(dst)) return null;
        try self.transferRangeBetweenSiblings(src, dst, 0, nodeCount(src), .Back);
        const parent = src.parent.?;
        self.infanticide(parent, src);
        return parent;
    }

    // -------------------- LINE COUNT HELPERS --------------------

    fn countLinesInPiece(self: *TextBuffer, p: *Piece) error{OutOfMemory}!usize {
        // count all newlines in a piece
        switch (p.buf()) {
            .Original => return self.o_idx.countRange(self.alloc, self.original, p.off, p.len()),
            .Add => return self.a_idx.countRange(self.alloc, self.add.items, p.off, p.len()),
        }
    }

    fn countLinesInPieceRange(self: *TextBuffer, p: *Piece, offset: usize, len: usize) error{OutOfMemory}!usize {
        // count newlines within some subset of a piece's bytes
        switch (p.buf()) {
            .Original => return self.o_idx.countRange(self.alloc, self.original, p.off + offset, len),
            .Add => return self.a_idx.countRange(self.alloc, self.add.items, p.off + offset, len),
        }
    }

    const MoveResult = struct { bytes: usize, lines: usize };

    fn countMovedPieces(self: *TextBuffer, to_move: []Piece) error{OutOfMemory}!MoveResult {
        var moved_bytes: usize = 0;
        var moved_lines: usize = 0;
        for (to_move) |*piece| {
            moved_bytes += piece.len();
            moved_lines += try self.countLinesInPiece(piece);
        }
        return .{ .bytes = moved_bytes, .lines = moved_lines };
    }

    fn countMovedNodes(to_move: []*Node) MoveResult {
        var moved_bytes: usize = 0;
        var moved_lines: usize = 0;
        for (to_move) |node| {
            moved_bytes += node.weight_bytes;
            moved_lines += node.weight_lines;
        }
        return .{ .bytes = moved_bytes, .lines = moved_lines };
    }

    fn findNthNewlineInPiece(self: *TextBuffer, p: *const Piece, n: usize) error{OutOfMemory}!usize {
        // return byte offset within a piece of the n-th newline
        const idx = switch (p.buf()) {
            .Original => try self.o_idx.NthNewlineAfter(self.alloc, self.original, p.off, n),
            .Add => try self.a_idx.NthNewlineAfter(self.alloc, self.add.items, p.off, n),
        };
        return idx - p.off;
    }
};

// -------------------- PIECE DATA TYPE --------------------

const Buffer = enum { Original, Add };

const Piece = struct {
    // one entry in the piece table.
    // pieces are logically a 3-tuple with
    //  1. buffer identifier
    //  2. starting index in source buffer
    //  3. sequence length
    // the working document can be assembled by walking through the piece table
    // and concatenating the "pieces" from each buffer.

    // HOWEVER...
    // On a 64-bit system, 2 usizes and an enum are 8 + 8 + 1 bytes, alignment rounds up to 24(!) bytes.
    // The buffer flag is really just one bit. Taking that bit from len and accepting that documents must
    // be at MOST 1/2 of the systems virtual memory (2GB on 32bit) allows us to do some packing.
    // With this implementation, pieces are now just 2 usizes, 16 bytes! 33% smaller.
    // This allows for better cache locality and in optimized releases speeds things up by 20-30%!
    off: usize,
    len_and_buf: usize,

    const hi_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const len_mask = ~hi_bit;

    fn len(self: Piece) usize {
        return self.len_and_buf & len_mask;
    }

    fn buf(self: Piece) Buffer {
        return if ((self.len_and_buf & hi_bit) == 0) .Original else .Add;
    }

    fn compose(length: usize, buffer: Buffer) usize {
        const flag: usize = if (buffer == .Add) hi_bit else 0;
        return (length & len_mask) | flag;
    }

    fn setLen(self: *Piece, new_len: usize) void {
        self.len_and_buf = compose(new_len, self.buf());
    }

    fn setBuf(self: *Piece, new_buf: Buffer) void {
        const len_only = self.len_and_buf & len_mask;
        self.len_and_buf = compose(len_only, new_buf);
    }

    fn growBy(self: *Piece, delta: usize) void {
        self.len_and_buf = compose(self.len() + delta, self.buf());
    }

    fn shrinkBy(self: *Piece, delta: usize) void {
        self.len_and_buf = compose(self.len() - delta, self.buf());
    }

    fn init(buffer: Buffer, length: usize, offset: usize) Piece {
        debug.dassert((length & hi_bit) == 0, "file size must be at most half of your system's virtual address space");
        const flag: usize = if (buffer == .Add) hi_bit else 0;
        return .{ .off = offset, .len_and_buf = length | flag };
    }
};

// -------------------- TREE (ROPE) IMPLEMENTATION --------------------

const MAX_BRANCH = 128;
const MIN_BRANCH = 8;
const MAX_PIECES = 128;
const MIN_PIECES = 8;
const MAX_ITER = 1_000;

const Node = struct {
    // This allows for O(log n) searching, insertion, and deletion anywhere
    parent: ?*Node = null,
    weight_bytes: usize = 0,
    weight_lines: usize = 0,
    // tagged union makes mutual exclusivity between node types explicit.
    // also keeps node size as small as possible by not storing two headers
    children: union(enum) { internal: std.ArrayList(*Node), leaf: std.ArrayList(Piece) },
};

// memory management: allocation and deallocation

fn initLeaf(alloc: std.mem.Allocator) error{OutOfMemory}!*Node {
    const node = try alloc.create(Node);
    node.* = .{
        .children = .{ .leaf = .empty },
    };
    return node;
}

fn initInternal(alloc: std.mem.Allocator) error{OutOfMemory}!*Node {
    const node = try alloc.create(Node);
    node.* = .{
        .children = .{ .internal = .empty },
    };
    return node;
}

fn freeTree(alloc: std.mem.Allocator, node: *Node) void {
    // recursive function to free all children of a given node
    switch (node.children) {
        .leaf => |*pieces| {
            pieces.deinit(alloc);
        },
        .internal => |*children| {
            for (children.items) |child| freeTree(alloc, child);
            children.deinit(alloc);
        },
    }
    alloc.destroy(node);
}

fn freeNode(alloc: std.mem.Allocator, node: *Node) void {
    // non-recursive function to free any single node
    debug.dassert(nodeCount(node) == 0, "cannot non-recursively free node with children");
    switch (node.children) {
        .leaf => |*pieces| pieces.deinit(alloc),
        .internal => |*chilren| chilren.deinit(alloc),
    }
    alloc.destroy(node);
}

// helper methods, good for debugging and provide readable aliases

fn leafPieces(leaf: *Node) *std.ArrayList(Piece) {
    debug.dassert(leaf.children == .leaf, "expected leaf node");
    return &leaf.children.leaf;
}

fn leafPiecesConst(leaf: *const Node) *const std.ArrayList(Piece) {
    debug.dassert(leaf.children == .leaf, "expected leaf node");
    return &leaf.children.leaf;
}

fn childList(internal: *Node) *std.ArrayList(*Node) {
    debug.dassert(internal.children == .internal, "expected internal node");
    return &internal.children.internal;
}

fn childListConst(internal: *const Node) *const std.ArrayList(*Node) {
    debug.dassert(internal.children == .internal, "expected internal node");
    return &internal.children.internal;
}

fn isLeaf(node: *const Node) bool {
    return node.children == .leaf;
}

fn nodeCount(node: *const Node) usize {
    return switch (node.children) {
        .leaf => |*pieces| pieces.items.len,
        .internal => |*children| children.items.len,
    };
}

fn nodeMin(node: *const Node) usize {
    return if (isLeaf(node)) MIN_PIECES else MIN_BRANCH;
}

fn nodeMax(node: *const Node) usize {
    return if (isLeaf(node)) MAX_PIECES else MAX_BRANCH;
}

fn spareNodes(node: *Node) usize {
    const count = nodeCount(node);
    const min = nodeMin(node);
    return if (count > min) count - min else 0;
}

// navigation within a document and within a leaf

const Found = struct {
    // for global navigation of the document from working index
    leaf: *Node, // leaf node containing the target
    offset: usize, // offset into that node's memory
};

fn findAt(root: *Node, at: usize) Found {
    var node = root;
    var idx = at;
    var iter: usize = 0;
    while (iter < MAX_ITER) : (iter += 1) {
        switch (node.children) {
            // if we've settled on a leaf, that's the one containing our index
            .leaf => return .{ .leaf = node, .offset = idx },
            // otherwise, iterate through children
            .internal => |*children| {
                const items = children.items;
                const len = items.len;
                debug.dassert(len > 0, "internal node must have at least one child");
                var i: usize = 0;
                // cumulatively subtract node weights from the index, we want an OFFSET
                while (i < len) : (i += 1) {
                    const weight = items[i].weight_bytes;
                    if (idx < weight) break;
                    idx -= weight;
                }
                debug.dassert(i < len, "failed to find index");
                node = items[i];
            },
        }
    }
    @panic("max iterations reached without finding index in document");
}

const InLeaf = struct {
    // for local navigation inside of a leaf
    piece_idx: usize, // index of piece containing the target
    offset: usize, // offset of the target in the leaf's memory
};

fn locateInLeaf(leaf: *const Node, offset: usize) InLeaf {
    const items = leafPiecesConst(leaf).items;
    const len = items.len;
    var acc: usize = 0;
    var idx: usize = 0;
    while (idx < len) : (idx += 1) {
        const piece = &items[idx];
        if (offset < acc + piece.len()) return .{ .piece_idx = idx, .offset = offset - acc };
        acc += piece.len();
    }
    @panic("couldn't find offset in leaf");
}

// navigation within the tree structure

const Siblings = struct { l: ?*Node, r: ?*Node };

fn indexOfChild(siblings: []const *Node, child: *const Node) usize {
    var idx: usize = 0;
    while (idx < siblings.len and siblings[idx] != child) : (idx += 1) {}
    debug.dassert(idx < siblings.len, "child not found under parent");
    return idx;
}

fn getSiblings(child: *const Node) Siblings {
    if (child.parent) |parent| {
        const siblings = childListConst(parent).items;
        const idx = indexOfChild(siblings, child);
        return .{ .l = if (idx > 0) siblings[idx - 1] else null, .r = if (idx + 1 < siblings.len) siblings[idx + 1] else null };
    }
    return .{ .l = null, .r = null };
}

fn leftmostDescendant(node: *Node) *Node {
    // find the leftmost descendant of any node
    var cur = node;
    while (!isLeaf(cur)) cur = childList(cur).items[0];
    return cur;
}

fn nextLeaf(node: *Node) ?*Node {
    // find the next leaf from ANYWHERE in the tree
    // This should be at most 2 * D hops where D is the depth of the tree
    // should be much faster than a full findAt call
    var cur = node;
    while (cur.parent) |parent| {
        const siblings = childList(parent).items;
        const idx = indexOfChild(siblings, cur);
        if (idx + 1 < siblings.len) return leftmostDescendant(siblings[idx + 1]);
        cur = parent;
    }
    return null;
}

// merging

fn canMerge(leaf: *const Node, a: usize, b: usize) bool {
    // given an index to a "left" and "right" piece, see if they are contiguous and from the same buffer
    const pieces = leafPiecesConst(leaf);
    debug.dassert(a < pieces.items.len, "left merge must be inside leaf");
    debug.dassert(b < pieces.items.len, "right merge must be inside leaf");
    const piece_a = pieces.items[a];
    const piece_b = pieces.items[b];
    return piece_a.buf() == piece_b.buf() and piece_a.off + piece_a.len() == piece_b.off;
}

fn merge(leaf: *Node, a: usize, b: usize) void {
    // merge two pieces by summing their lengths into the left one and deleting the right
    const pieces = leafPieces(leaf);
    pieces.items[a].growBy(pieces.items[b].len());
    _ = pieces.orderedRemove(b);
}

fn mergeAround(leaf: *Node, idx: usize) void {
    // given a "center" index, attempt to merge its left and right neighbors
    const pieces = leafPieces(leaf);
    debug.dassert(idx < pieces.items.len, "merge index must be inside piece table");
    var i = idx;
    if (i > 0 and canMerge(leaf, i - 1, i)) {
        merge(leaf, i - 1, i);
        i -= 1;
    }
    if (i + 1 < pieces.items.len and canMerge(leaf, i, i + 1)) merge(leaf, i, i + 1);
}

// helpers for editing nodes

fn fastAppendIfPossible(leaf: *Node, add_off: usize, add_len: usize, at: usize, doc_len: usize) bool {
    // happy path, appending to the end of the add buffer
    if (at != doc_len) return false;
    const pieces = leafPieces(leaf).items;
    if (pieces.len == 0) return false;
    const last = &pieces[pieces.len - 1];
    // only valid if the last piece is from the add buffer and contiguous with new entry
    if (last.buf() == .Add and last.off + last.len() == add_off) {
        last.growBy(add_len);
        return true;
    }
    return false;
}

fn spliceIntoLeaf(pieces: *std.ArrayList(Piece), alloc: std.mem.Allocator, loc: InLeaf, add_off: usize, add_len: usize) error{OutOfMemory}!usize {
    // generic path, build 1-3 replacement pieces and insert them into the piece table.
    // The return is the index of the newly inserted piece
    const new_piece = Piece.init(.Add, add_len, add_off);
    const len = pieces.items.len;
    if (loc.piece_idx < len) {
        const old = pieces.items[loc.piece_idx];
        const len_suffix = old.len() - loc.offset;
        // create a buffer that holds at most 3 new pieces and populate
        var buf: [3]Piece = undefined;
        var n: usize = 0;
        if (loc.offset != 0) {
            buf[n] = old;
            buf[n].setLen(loc.offset);
            n += 1;
        }
        buf[n] = new_piece;
        n += 1;
        if (len_suffix != 0) {
            buf[n] = old;
            buf[n].off += loc.offset;
            buf[n].setLen(len_suffix);
            n += 1;
        }
        // carefully splice that buffer into the piece array
        pieces.items[loc.piece_idx] = buf[0];
        if (n >= 2) try pieces.insertSlice(alloc, loc.piece_idx + 1, buf[1..n]);
        return loc.piece_idx + @intFromBool(loc.offset != 0);
    } else {
        try pieces.append(alloc, new_piece);
        return len;
    }
}

fn bubbleByteDelta(node: *Node, delta: usize, is_neg: bool) void {
    // propagate a change in byte weight up the tree
    var cur: ?*Node = node;
    while (cur) |n| {
        if (is_neg) {
            debug.dassert(n.weight_bytes >= delta, "cannot give a node a negative byte weight");
            n.weight_bytes -= delta;
        } else {
            n.weight_bytes += delta;
        }
        cur = n.parent;
    }
}

fn bubbleLineDelta(node: *Node, delta: usize, is_neg: bool) void {
    var cur: ?*Node = node;
    while (cur) |n| {
        if (is_neg) {
            debug.dassert(n.weight_lines >= delta, "cannot give a node a negative line weight");
            n.weight_lines -= delta;
        } else {
            n.weight_lines += delta;
        }
        cur = n.parent;
    }
}

const BorrowPlan = struct { take_left: usize, take_right: usize };

fn planBorrow(node: *Node, siblings: Siblings) BorrowPlan {
    // determines exactly how many children a node wants to borrow, and how many to take from each sibling
    const count = nodeCount(node);
    const min = nodeMin(node);
    const max = nodeMax(node);
    if (count >= min) return .{ .take_left = 0, .take_right = 0 };
    const demand = min - count;
    const capacity = max - count;
    const left_spare = if (siblings.l) |l| spareNodes(l) else 0;
    const right_spare = if (siblings.r) |r| spareNodes(r) else 0;
    // merge on new boundaries after borrowing might delete up to one piece per borrow
    var slack: usize = 0;
    const is_leaf = isLeaf(node);
    if (is_leaf and siblings.l != null) slack += 1;
    if (is_leaf and siblings.r != null) slack += 1;
    var total_want = @min(demand + slack, capacity);
    // preferentially borrow from the right sibling, it's faster
    const take_right = @min(total_want, right_spare);
    total_want -= take_right;
    const take_left = @min(total_want, left_spare);
    return .{ .take_left = take_left, .take_right = take_right };
}

// -------------------- LAZY LINE INDEXING IMPLEMENTATION --------------------
// Maintains a lazy way to map buffer indices to newline counts

const PAGE_SIZE = 16 * 1024;

const NewLineIndex = struct {
    // Real-world navigation in documents is generally line-centric.
    // Obviously then, we need a way of representing where the line breaks are to support O(log n) lookup.
    // So we lazily scan only the portions of the document that have been touched and cache results.
    // NOTE: on load the document is a single piece, and must be O(n) scanned to support line count metrics.
    done: std.ArrayList(bool) = .empty,
    prefix: std.ArrayList(usize) = .empty,

    fn deinit(self: *NewLineIndex, alloc: std.mem.Allocator) void {
        self.done.deinit(alloc);
        self.prefix.deinit(alloc);
    }

    fn ensureCapacityForLen(self: *NewLineIndex, alloc: std.mem.Allocator, buf_len: usize) error{OutOfMemory}!void {
        // make sure there are enough pages to account for a given buffer size
        const pages = std.math.divCeil(usize, buf_len, PAGE_SIZE) catch unreachable;
        const len = self.done.items.len;
        debug.dassert(self.prefix.items.len == len, "done and prefix length must match");
        if (pages > len) {
            const add = pages - len;
            const new_done = try self.done.addManyAsSlice(alloc, add);
            _ = try self.prefix.addManyAsSlice(alloc, add);
            // new pages have not been counted yet
            @memset(new_done, false);
        }
    }

    fn ensurePage(self: *NewLineIndex, buf: []const u8, page: usize) void {
        // ensure that the current page has been counted
        debug.dassert(page < self.done.items.len, "page index higher than cache length");
        debug.dassert(page < (buf.len + PAGE_SIZE - 1) / PAGE_SIZE, "page index higher than buffer maximum");
        debug.dassert(self.done.items.len == (buf.len + PAGE_SIZE - 1) / PAGE_SIZE, "done is not the correct length");
        debug.dassert(self.prefix.items.len == (buf.len + PAGE_SIZE - 1) / PAGE_SIZE, "done is not the correct length");
        if (self.done.items[page]) return;
        // previous pages may not be filled, walk backwards until we find the last one that was
        var idx = page;
        while (idx > 0 and !self.done.items[idx - 1]) : (idx -= 1) {}
        // now walk forwards again and fill until we fill the target page
        while (idx <= page) : (idx += 1) {
            const start = idx * PAGE_SIZE;
            const end = @min(start + PAGE_SIZE, buf.len);
            const count = utils.countNewlinesInSlice(buf[start..end]);
            const prev = if (idx == 0) 0 else self.prefix.items[idx - 1];
            self.prefix.items[idx] = prev + count;
            self.done.items[idx] = true;
        }
    }

    fn countRange(self: *NewLineIndex, alloc: std.mem.Allocator, buf: []const u8, start: usize, len: usize) error{OutOfMemory}!usize {
        if (len == 0) return 0;
        try self.ensureCapacityForLen(alloc, buf.len);
        const end = start + len;
        const page_0 = start / PAGE_SIZE;
        const page_1 = (end - 1) / PAGE_SIZE;
        // range inside a single page, count directly
        if (page_0 == page_1) return utils.countNewlinesInSlice(buf[start..end]);
        // generic case: we count left and right edges and middle is handled by precomputed prefixes
        var total: usize = 0;
        const left_edge = (page_0 + 1) * PAGE_SIZE;
        total += utils.countNewlinesInSlice(buf[start..left_edge]);
        // ensure prefixes are counted up to and including the end page
        self.ensurePage(buf, page_1);
        // use prefix differences for interior pages
        if (page_1 > page_0 + 1) {
            const prefix_end = self.prefix.items[page_1 - 1];
            const prefix_start = self.prefix.items[page_0];
            total += prefix_end - prefix_start;
        }
        // right partial page
        const right_edge = page_1 * PAGE_SIZE;
        total += utils.countNewlinesInSlice(buf[right_edge..end]);
        return total;
    }

    fn NthNewlineAfter(self: *NewLineIndex, alloc: std.mem.Allocator, buf: []const u8, start: usize, n: usize) error{OutOfMemory}!usize {
        if (n == 0) return start;
        try self.ensureCapacityForLen(alloc, buf.len);
        // calculate starting and ending indices for current page, offset within the page etc
        const page = start / PAGE_SIZE;
        const page_start = page * PAGE_SIZE;
        const page_end = @min(page_start + PAGE_SIZE, buf.len);
        self.ensurePage(buf, page);
        // number of newlines in the first partial page
        const in_partial = utils.countNewlinesInSlice(buf[start..page_end]);
        if (n <= in_partial) return utils.indexOfKthNewlineInRange(buf, start, page_end, n);
        // now ensure the whole buffer has been scanned
        const remaining = n - in_partial;
        const last_page = (buf.len - 1) / PAGE_SIZE;
        self.ensurePage(buf, last_page);
        const prefix = self.prefix.items;
        // binary search the prefilled pages until the page containing the nth newline is found
        var lo = page_start + 1;
        var hi = last_page;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const between = prefix[mid] - prefix[page_start];
            if (between >= remaining) hi = mid else lo = mid + 1;
        }
        const target_page = lo;
        const before_target = prefix[target_page - 1] - prefix[page_start];
        // need the kth newline inside the target page
        const k = remaining - before_target;
        const target_begin = target_page * PAGE_SIZE;
        const target_end = @min(target_begin + PAGE_SIZE, buf.len);
        return utils.indexOfKthNewlineInRange(buf, target_begin, target_end, k);
    }
};

// -------------------- SLICE ITERATOR IMPLEMENTATION --------------------
// Read-only no-copy views into the text buffer.
// This is how consumers recieve views into the document

pub const SliceIter = struct {
    buffer: *TextBuffer,
    leaf: *Node,
    piece_idx: usize,
    piece_offset: usize,
    remaining: usize,

    fn init(buffer: *TextBuffer, start: usize, len: usize) SliceIter {
        // find the location corresponding to the start of the range
        const found = findAt(buffer.root, start);
        const loc = locateInLeaf(found.leaf, found.offset);
        return .{
            .buffer = buffer,
            .leaf = found.leaf,
            .piece_idx = loc.piece_idx,
            .piece_offset = loc.offset,
            .remaining = len,
        };
    }

    pub fn next(self: *SliceIter) ?[]const u8 {
        // return the next slice in the range.
        // When there is nothing left, returns null
        if (self.remaining == 0) return null;
        var pieces = leafPiecesConst(self.leaf).items;
        // hop to the next leaf if we ran out of pieces in this one
        while (self.piece_idx >= pieces.len) {
            const nxt = nextLeaf(self.leaf) orelse return null;
            self.leaf = nxt;
            // now we're in a new leaf, reset the offsets
            pieces = leafPiecesConst(self.leaf).items;
            self.piece_idx = 0;
            self.piece_offset = 0;
        }
        // identify which buffer to slice from
        const piece = pieces[self.piece_idx];
        const src = switch (piece.buf()) {
            .Original => self.buffer.original,
            .Add => self.buffer.add.items,
        };
        // create the actual current slice
        const bytes_available = piece.len() - self.piece_offset;
        const take = @min(bytes_available, self.remaining);
        const start = piece.off + self.piece_offset;
        const slice = src[start .. start + take];
        // advance iterator state
        self.remaining -= take;
        self.piece_offset += take;
        if (self.piece_offset == piece.len()) {
            self.piece_idx += 1;
            self.piece_offset = 0;
        }
        return slice;
    }
};
