const std = @import("std");
const debug = @import("debug");
const traits = @import("traits");

// The piece-table implementation for storing edits to a document efficiently in memory.
// There are two distinct but highly coupled data structures implemented here.
// Top-level is a piece table, but storing pieces in an array is SLOW! O(P)
// Pieces are stored in a rope implemented as a b-tree. 
// With P = # pieces:
//   Locate index -> leaf:  O(log_{MIN_BRANCH} P)
//   Point edit (insert/delete at one index):
//     - Leaf mutation:     O(MAX_PIECES)
//     - Rebalance path:    O(log_{MIN_BRANCH} P * MAX_BRANCH)
//     => Overall:          O(log_{MIN_BRANCH} P) with small constants
//   Range edit spanning t pieces: O(log_{MIN_BRANCH} P + t)

const Piece = struct {
    // one entry in the piece table.
    // pieces are a 3-tuple with
    //  1. buffer identifier
    //  2. starting index in source buffer
    //  3. sequence length
    // the working document can be assembled by walking through the piece table
    // and concatenating the "pieces" from each buffer.
    buf: enum { Original, Add },
    off: usize,
    len: usize,
};

// -------------------- ROPE IMPLEMENTATION --------------------

const MAX_BRANCH = 64;
const MIN_BRANCH = MAX_BRANCH / 2;
const MAX_PIECES = 64;
const MIN_PIECES = MAX_PIECES / 2;
const MAX_ITER = 1_000;

const Node = struct {
    // The "table" in piece table is actually a rope implemented as a b-tree.
    // This allows for O(log n) searching, insertion, and deletion anywhere
    parent: ?*Node,
    weight_bytes: usize,
    // tagged union makes mutual exclusivity between node types explicit.
    // also keeps node size as small as possible by not storing two headers
    children: union(enum) {
        internal: std.ArrayList(*Node),
        leaf:     std.ArrayList(Piece)
    }
};

const Found = struct {
    // for global navigation of the document.
    // when looking for the in-memory object representing a specific index into the document,
    // this is what is returned: A leaf node and the offset into its memory.
    leaf: *Node,
    offset: usize,
};

const InLeaf = struct {
    // for local navigation inside of a leaf.
    // when looking for the specific piece that contains an index, this is what's returned:
    // An index into that leaf node's pieces array, and the offset within that piece.
    piece_idx: usize,
    offset: usize,
};

// memory management: allocation and deallocation

fn initLeaf(alloc: std.mem.Allocator) error{OutOfMemory}!*Node {
    const node = try alloc.create(Node);
    node.* = .{
        .parent = null,
        .weight_bytes = 0,
        .children = .{ 
            .leaf = std.ArrayList(Piece).init(alloc)
        },
    };
    return node;
}

fn initInternal(alloc: std.mem.Allocator) error{OutOfMemory}!*Node {
    const node = try alloc.create(Node);
    node.* = .{
        .parent = null,
        .weight_bytes = 0,
        .children = .{
            .internal = std.ArrayList(*Node).init(alloc)
        },
    };
    return node;
}

fn freeTree(alloc: std.mem.Allocator, node: *Node) void {
    // recursive function to free all children of a given node
    switch (node.children) {
        .leaf => |*pieces| { pieces.deinit(); },
        .internal => |*children| { 
            for (children.items) |child| freeTree(alloc, child);
            children.deinit();
        }
    }
    alloc.destroy(node);
}

// safe helper methods, good for debugging and provide readable aliases

inline fn leafPieces(leaf: *Node) *std.ArrayList(Piece) {
    debug.dassert(std.meta.activeTag(leaf.children) == .leaf, "expected leaf node");
    return &leaf.children.leaf;
}

inline fn leafPiecesConst(leaf: *const Node) *const std.ArrayList(Piece) {
    debug.dassert(std.meta.activeTag(leaf.children) == .leaf, "expected leaf node");
    return &leaf.children.leaf;
}

inline fn childList(internal: *Node) *std.ArrayList(*Node) {
    debug.dassert(std.meta.activeTag(internal.children) == .internal, "expected internal node");
    return &internal.children.internal;
}

inline fn childListConst(internal: *const Node) *const std.ArrayList(*Node) {
    debug.dassert(std.meta.activeTag(internal.children) == .internal, "expected internal node");
    return &internal.children.internal;
}

// navigation within a document and within a leaf

fn findAt(root: *Node, at: usize) Found {
    var node = root;
    var idx = at;
    var iter: usize = 0;
    while (iter < MAX_ITER) : (iter += 1) {
        switch (node.children) {
            // if we've settled on a leaf, that's the one containing our index
            .leaf => return .{ .leaf = node, .offset = idx},
            // otherwise, iterate through children
            .internal => |*children| {
                var i: usize = 0;
                // cumulatively subtract node weights from the index, we want an OFFSET
                while (i < children.items.len and idx >= children.items[i].weight_bytes) : (i += 1) {
                    idx -= children.items[i].weight_bytes;
                }
                // if the node walked to the very end, a small manual adjustment is needed
                if (i == children.items.len) { i -= 1; idx = children.items[i].weight_bytes; }
                // children.items[i].weight_bytes <= idx < children.items[i+1].weight_bytes
                node = children.items[i];
            }
        }
    }
    unreachable;
}

fn locateInLeaf(leaf: *const Node, offset: usize) InLeaf {
    const pieces = leafPiecesConst(leaf);
    var acc: usize = 0;
    var idx: usize = 0;
    while (idx < pieces.items.len) : (idx += 1) {
        const piece = &pieces.items[idx];
        if (offset < acc + piece.len) return .{ .piece_idx = idx, .offset = offset - acc };
        acc += piece.len;
    }
    return .{ .piece_idx = pieces.items.len, .offset = 0 };
}

// merging

fn canMerge(leaf: *const Node, a: usize, b: usize) bool {
    // given an index to a "left" and "right" piece, see if they are contiguous and from the same buffer
    const pieces = leafPiecesConst(leaf);
    debug.dassert(a < pieces.items.len, "left merge must be inside leaf");
    debug.dassert(b < pieces.items.len, "right merge must be inside leaf");
    const piece_a = pieces.items[a];
    const piece_b = pieces.items[b];
    return piece_a.buf == piece_b.buf and piece_a.off + piece_a.len == piece_b.off;
}

fn merge(leaf: *Node, a: usize, b: usize) void {
    // merge two pieces by summing their lengths into the left one and deleting the right
    const pieces = leafPieces(leaf);
    pieces.items[a].len += pieces.items[b].len;
    _ = pieces.orderedRemove(b);
}

fn mergeAround(leaf: *Node, idx: usize) void {
    // given a "center" index, attempt to merge its left and right neighbors
    const pieces = leafPieces(leaf);
    debug.dassert(idx < pieces.items.len, "merge index must be inside piece table");
    var i = idx;
    if (i > 0 and canMerge(leaf, i-1, i)) { merge(leaf, i-1, i); i -= 1; }
    if (i + 1 < pieces.items.len and canMerge(leaf, i, i+1)) merge(leaf, i, i+1);
}

// helpers for editing nodes

fn fastAppendIfPossible(leaf: *Node, add_off: usize, add_len: usize, at: usize, doc_len: usize) bool {
    // happy path, appending to the end of the add buffer
    if (at != doc_len) return false;
    const pieces = leafPieces(leaf);
    if (pieces.items.len == 0) return false;
    const last = &pieces.items[pieces.items.len - 1];
    // only valid if the last piece is from the add buffer and contiguous with new entry
    if (last.buf == .Add and last.off + last.len == add_off) {
        last.len += add_len;
        return true;
    }
    return false;
}

fn spliceIntoLeaf(pieces: *std.ArrayList(Piece), loc: InLeaf, add_off: usize, add_len: usize) error{OutOfMemory}!usize {
    // generic path, build 1-3 replacement pieces and insert them into the piece table
    const new_piece = Piece{ .buf = .Add, .off = add_off, .len = add_len };
    if (loc.piece_idx < pieces.items.len) {
        const old = pieces.items[loc.piece_idx];
        const len_suffix = old.len - loc.offset;

        var buf: [3]Piece = undefined;
        var n: usize = 0;
        if (loc.offset != 0) { buf[n] = old; buf[n].len = loc.offset; n += 1; }
        buf[n] = new_piece; n += 1;
        if (len_suffix != 0) { buf[n] = old; buf[n].off += loc.offset; buf[n].len = len_suffix; n += 1; }

        pieces.items[loc.piece_idx] = buf[0];
        if (n >= 2) try pieces.insertSlice(loc.piece_idx + 1, buf[1..n]);
        return loc.piece_idx + @intFromBool(loc.offset != 0);
    } else {
        try pieces.append(new_piece);
        return pieces.items.len - 1;
    }
}

fn deleteFromLeaf(leaf: *Node, start: InLeaf, max_remove: usize) error{OutOfMemory}!usize {
    // attempt to delete at most max_remove bytes from the current leaf.
    // return the total number that could be deleted, deletion may go into another node.
    const pieces = leafPieces(leaf);
    var removed: usize = 0;
    var piece_idx = start.piece_idx;
    const prefix_len = start.offset;
    if (piece_idx >= pieces.items.len) return 0;

    // handle the current (first) piece
    var piece = &pieces.items[piece_idx];
    var take = @min(max_remove, piece.len - prefix_len);
    // lucky case: delete the whole piece
    if (prefix_len == 0 and take == piece.len) { _ = pieces.orderedRemove(piece_idx); }
    // general case, we may need to create a new suffix piece
    else {
        const suffix_len = piece.len - prefix_len - take;
        // delete the middle of the piece
        if (prefix_len > 0 and suffix_len > 0) {
            piece.len = prefix_len;
            var suffix = piece.*;
            suffix.off += prefix_len + take;
            suffix.len = suffix_len;
            try pieces.insert(piece_idx + 1, suffix);
            piece_idx += 1;
        // there is no suffix, just trim the current piece
        } else if (prefix_len > 0) { piece.len = prefix_len; piece_idx += 1; }
        // there is no prefix, but the entire piece wasn't removed
        else { piece.off += take; piece.len = suffix_len; }
    }
    removed += take;

    // if applicable, remove entire middle pieces
    while (piece_idx < pieces.items.len and removed < max_remove) {
        piece = &pieces.items[piece_idx];
        if (piece.len <= (max_remove - removed)) {
            removed += piece.len;
            _ = pieces.orderedRemove(piece_idx);
        } else break;
    }

    // we may still need to remove the front of one final piece
    if (piece_idx < pieces.items.len and removed < max_remove) {
        piece = &pieces.items[piece_idx];
        take = max_remove - removed;
        piece.off += take;
        piece.len -= take;
        removed += take;
    }

    // if there are still pieces left, perform a local coalesce before returning
    if (pieces.items.len == 0) return removed;
    if (piece_idx == pieces.items.len) piece_idx -= 1;
    mergeAround(leaf, piece_idx);
    return removed;
}

fn recomputeWeight(node: *Node) void {
    // recompute the sum for any node, then propagate the difference up it's parents
    var sum: usize = 0;
    switch (node.children) {
        .leaf => |*pieces| { for (pieces.items) |piece| sum += piece.len; },
        .internal => |*children| { for (children.items) |child| sum += child.weight_bytes; },
    }
    // no propagation needed if sum is unchanged
    if (sum == node.weight_bytes) return;

    var cur = node.parent;
    if (sum > node.weight_bytes) {
        const inc = sum - node.weight_bytes;
        while (cur) |n| {
            n.weight_bytes += inc;
            cur = n.parent;
        }
    } else {
        const dec = node.weight_bytes - sum;
        while (cur) |n| {
            debug.dassert(n.weight_bytes >= dec, "cannot give a node a negative weight");
            n.weight_bytes -= dec;
            cur = n.parent;
        }
    }
    node.weight_bytes = sum;
}

// -------------------- PIECE TABLE IMPLEMENTATION --------------------

const PieceTable = struct {
    // piece table collection object.
    // holds a pointer to the original document as well as a working append-only buffer.
    // holds a collection of ordered "pieces" which describe how to build a final document using the two buffers.
    original: []const u8,
    add: std.ArrayList(u8),
    root: *Node,
    doc_len: usize,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{OutOfMemory}!PieceTable {
        // initialize the root of the tree
        const leaf = try initLeaf(alloc);
        if (original.len != 0) {
            try leafPieces(leaf).append(.{ .buf = .Original, .off = 0, .len = original.len });
            leaf.weight_bytes = original.len;
        }
        return PieceTable{
            .original = original,
            .add = std.ArrayList(u8).init(alloc),
            .root = leaf,
            .doc_len = original.len,
            .alloc = alloc,
        };
    }
    
    pub fn deinit(self: *PieceTable) void {
        self.add.deinit();
        freeTree(self.alloc, self.root);
    }

    pub fn insert(self: *PieceTable, at: usize, text: []const u8) error{OutOfMemory}!void {
        debug.dassert(at <= self.doc_len, "cannot insert outside of the document.");
        debug.dassert(text.len > 0, "cannot insert empty text");

        const add_offset = self.add.items.len;
        try self.add.appendSlice(text);

        // find the leaf node that corresponds to the insertion index
        const found = findAt(self.root, at);
        const leaf = found.leaf;
        const pieces = leafPieces(leaf);

        // under the ideal case, new edits are appended to the end and extend an existing piece
        if (fastAppendIfPossible(leaf, add_offset, text.len, at, self.doc_len)) {
            recomputeWeight(leaf);
            self.doc_len += text.len;
            return;
        }

        const loc = locateInLeaf(leaf, found.offset);
        const idx = try spliceIntoLeaf(pieces, loc, add_offset, text.len);
        mergeAround(leaf, idx);
        recomputeWeight(leaf);
        try self.bubbleOverflowUp(leaf);
        self.doc_len += text.len;
    }

    pub fn delete(self: *PieceTable, at: usize, len: usize) error{OutOfMemory}!void {
        debug.dassert(at + len <= self.doc_len, "cannot delete outside of document");
        debug.dassert(len > 0, "cannot delete empty span");

        var remaining = len;
        while (remaining > 0) {
            const found = findAt(self.root, at);
            const leaf = found.leaf;
            const in_leaf = locateInLeaf(leaf, found.offset);

            // try to remove as much as possible within this leaf
            const removed = try deleteFromLeaf(leaf, in_leaf, remaining);
            recomputeWeight(leaf);
            // TODO: repair tree
            remaining -= removed;
        }
        self.doc_len -= len;
    }

    pub fn writeWith(self: *PieceTable, w: anytype) @TypeOf(w).Error!void {
        traits.ensureHasMethod(w, "writeAll");
        try self.writeSubtree(w, self.root);
    }

    // -------------------- WRITE HELPERS --------------------

    fn writeSubtree(self: *PieceTable, w: anytype, node: *const Node) @TypeOf(w).Error!void {
        switch (node.children) {
            .leaf => try self.writeLeaf(w, node),
            .internal => |*children| try self.writeChildren(w, children.items, 0)
        }
    }

    fn writeLeaf(self: *PieceTable, w: anytype, leaf: *const Node) @TypeOf(w).Error!void {
        // helper method to write all of the pieces from a given leaf
        const pieces = leafPiecesConst(leaf);
        for (pieces.items) |piece| {
            const src = switch(piece.buf) {
                .Original => self.original,
                .Add      => self.add.items,
            };
            debug.dassert(piece.off <= src.len, "piece offset must be inside it's source buffer");
            debug.dassert(piece.len <= src.len - piece.off, "full piece slice must be inside source buffer");
            try w.writeAll(src[piece.off..piece.off + piece.len]);
        }
    }

    fn writeChildren(self: *PieceTable, w: anytype, children: []const *Node, idx: usize) @TypeOf(w).Error!void {
        if (idx >= children.len) return;
        // traverse deeper on leftmost node
        try self.writeSubtree(w, children[idx]);
        // traverse left to right inside this branch
        return self.writeChildren(w, children, idx + 1);
    }

    // -------------------- INSERT HELPERS --------------------

    fn bubbleOverflowUp(self: *PieceTable, start: *Node) error{OutOfMemory}!void {
        // It's possible that a node split overflows it's parent, which splits and overflows IT'S parent...
        // Thus the logic needs to "bubble up" from the bottom of the tree until splits stop happening
        var cur: ?*Node = start;
        while (cur) |n| {
            const parent = try self.splitNodeIfOverflow(n);
            if (parent == null) return;
            cur = parent;
        }
    }

    fn splitNodeIfOverflow(self: *PieceTable, node: *Node) error{OutOfMemory}!?*Node {
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
                try leafPieces(right).appendSlice(pieces.items[mid..]);
                pieces.shrinkRetainingCapacity(mid);
                return self.spliceNodeInTree(node, right);
            },
            .internal => |*children| {
                if (children.items.len <= MAX_BRANCH) return null;
                const mid = children.items.len / 2;
                const right = try initInternal(self.alloc);
                try childList(right).appendSlice(children.items[mid..]);
                children.shrinkRetainingCapacity(mid);
                // fix parent pointer for moved children
                for (childList(right).items) |child| child.parent = right;
                return self.spliceNodeInTree(node, right);
            }
        }
    }

    fn spliceNodeInTree(self: *PieceTable, old: *Node, new: *Node) error{OutOfMemory}!?*Node {
        // Wraps all of the logic add adding a new node into the tree.
        // This is for the specific case of splitting an existing node in half.
        // NOTE: Unfortunately this must be a piece table method since it modifies the root.
        // Likewise, it's two calling parents need to be as well. Maybe fix this sometime?
        recomputeWeight(old);
        // general case, add the new node one to the right of the old
        if (old.parent) |parent| {
            const siblings = childList(parent);
            var idx: usize = 0;
            while (siblings.items[idx] != old) : (idx += 1) {}
            debug.dassert(idx < siblings.items.len, "left child not found under parent");
            try siblings.insert(idx + 1, new);
            new.parent = parent;
            recomputeWeight(new);
            return parent;
        // edge case, old node was the root, create a new root and create both as siblings
        } else {
            const root = try initInternal(self.alloc);
            try childList(root).append(old);
            try childList(root).append(new);
            old.parent = root;
            new.parent = root;
            recomputeWeight(new);
            recomputeWeight(root);
            self.root = root;
            return null;
        }
    }

    // -------------------- DELETE HELPERS --------------------


};

// -------------------- TESTING --------------------

test "compiles?" {
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "hello world");
    defer pt.deinit();
}

test "insert: empty, start, middle, end, fast path" {
    const alloc = std.testing.allocator;

    // empty
    var pt = try PieceTable.init(alloc, "");
    defer pt.deinit();
    try pt.insert(0, "hello");

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();
    try pt.writeWith(out.writer());
    try std.testing.expect(std.mem.eql(u8, "hello", out.items));

    // end (original + add)
    var pt2 = try PieceTable.init(alloc, "abc");
    defer pt2.deinit();
    try pt2.insert(3, "def");
    out.clearRetainingCapacity();
    try pt2.writeWith(out.writer());
    try std.testing.expect(std.mem.eql(u8, "abcdef", out.items));

    // fast path extend
    try pt2.insert(6, "X");
    try pt2.insert(7, "Y");
    out.clearRetainingCapacity();
    try pt2.writeWith(out.writer());
    try std.testing.expect(std.mem.eql(u8, "abcdefXY", out.items));

    // start + middle
    var pt3 = try PieceTable.init(alloc, "hello world");
    defer pt3.deinit();
    try pt3.insert(0, ">>> ");
    try pt3.insert(9, ",");
    out.clearRetainingCapacity();
    try pt3.writeWith(out.writer());
    try std.testing.expect(std.mem.eql(u8, ">>> hello, world", out.items));
}

test "delete: single-piece middle" {
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "hello world");
    defer pt.deinit();

    try pt.delete(3, 4); // remove "lo w"
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();
    try pt.writeWith(out.writer());
    try std.testing.expect(std.mem.eql(u8, "helorld", out.items));
}

test "delete: spans pieces and merges" {
    const alloc = std.testing.allocator;
    var pt = try PieceTable.init(alloc, "abcXYZ");
    defer pt.deinit();
    try pt.insert(3, "123"); // abc123XYZ  (pieces: Original[a..c], Add[123], Original[XYZ])
    try pt.delete(2, 4);     // delete "c123" -> "abXYZ"
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();
    try pt.writeWith(out.writer());
    try std.testing.expect(std.mem.eql(u8, "abXYZ", out.items));
}
