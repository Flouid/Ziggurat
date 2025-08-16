const std = @import("std");
const debug = @import("debug");
const utils = @import("utils");

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

const MAX_BRANCH = 128;
const MIN_BRANCH = 8;
const MAX_PIECES = 128;
const MIN_PIECES = 8;
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
    },
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
        .leaf     => |*pieces| { pieces.deinit(); },
        .internal => |*children| { 
            for (children.items) |child| freeTree(alloc, child);
            children.deinit();
        }
    }
    alloc.destroy(node);
}

fn freeNode(alloc: std.mem.Allocator, node: *Node) void {
    // non-recursive function to free any single node
    debug.dassert(nodeCount(node) == 0, "cannot non-recursively free node with children");
    switch (node.children) {
        .leaf     => |*pieces| pieces.deinit(),
        .internal => |*chilren| chilren.deinit(),
    }
    alloc.destroy(node);
}

// inline helper methods, good for debugging and provide readable aliases

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

inline fn isLeaf(node: *const Node) bool {
    return std.meta.activeTag(node.children) == .leaf;
}

inline fn nodeCount(node: *const Node) usize {
    return switch (node.children) {
        .leaf     => |*pieces| pieces.items.len,
        .internal => |*children| children.items.len
    };
}

inline fn nodeMin(node: *const Node) usize {
    return if (isLeaf(node)) MIN_PIECES else MIN_BRANCH;
}

inline fn nodeMax(node: *const Node) usize {
    return if (isLeaf(node)) MAX_PIECES else MAX_BRANCH;
}

inline fn spareNodes(node: *Node) usize {
    const count = nodeCount(node);
    const min = nodeMin(node);
    return if (count > min) count - min else 0;
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
                debug.dassert(children.items.len > 0, "internal node must have at least one child");
                var i: usize = 0;
                // cumulatively subtract node weights from the index, we want an OFFSET
                while (i < children.items.len and idx >= children.items[i].weight_bytes) : (i += 1) {
                    idx -= children.items[i].weight_bytes;
                }
                // if the node walked to the very end, a small manual adjustment is needed for consistency
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
    // return a sentinel to the end of the pieces array
    return .{ .piece_idx = pieces.items.len, .offset = 0 };
}

// navigation within the tree structure

const Siblings = struct { l: ?*Node, r: ?*Node };

fn indexOfChild(parent: *const Node, child: *const Node) usize {
    const children = childListConst(parent);
    var idx: usize = 0;
    while (idx < children.items.len and children.items[idx] != child) : (idx += 1) {}
    debug.dassert(idx < children.items.len, "child not found under parent");
    return idx;
}

fn getSiblings(child: *const Node) Siblings {
    if (child.parent) |parent| {
        const siblings = childListConst(parent);
        const idx = indexOfChild(parent, child);
        return .{
            .l = if (idx > 0) siblings.items[idx-1] else null,
            .r = if (idx + 1 < siblings.items.len) siblings.items[idx+1] else null
        };
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
        const idx = indexOfChild(parent, cur);
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
    // generic path, build 1-3 replacement pieces and insert them into the piece table.
    // The return is the index of the newly inserted piece
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
    var pieces = leafPieces(leaf);
    var removed: usize = 0;
    var piece_idx = start.piece_idx;
    const prefix_len = start.offset;
    if (piece_idx >= pieces.items.len) return 0;

    // handle the current (first) piece
    var piece = &pieces.items[piece_idx];
    var take = @min(max_remove, piece.len - prefix_len);
    // we can't just delete the entire thing
    if (prefix_len > 0 or take < piece.len) {
        const suffix_len = piece.len - prefix_len - take;
        // delete the middle of the piece
        if (prefix_len > 0 and suffix_len > 0) {
            piece.len = prefix_len;
            var suffix = piece.*;
            suffix.off += prefix_len + take;
            suffix.len = suffix_len;
            try pieces.insert(piece_idx + 1, suffix);
            piece_idx += 1;
        // there is no suffix, trim the front
        } else if (prefix_len > 0) { piece.len = prefix_len; piece_idx += 1; }
        // there is no prefix, trim the tail
        else { piece.off += take; piece.len = suffix_len; }
        removed += take;
    }

    // if applicable, remove entire middle pieces, coalesce into one big delete at the end
    var end_range = piece_idx;
    while (end_range < pieces.items.len and removed < max_remove) : (end_range += 1) {
        piece = &pieces.items[end_range];
        if (piece.len <= (max_remove - removed)) removed += piece.len else break;
    }
    if (end_range > piece_idx) utils.orderedRemoveRange(Piece, pieces, piece_idx, end_range - piece_idx);

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

fn bubbleDelta(node: *Node, delta: usize, is_neg: bool) void {
    // propagate a change in weight up the tree
    var cur: ?*Node = node;
    while (cur) |n| {
        if (is_neg) {
            debug.dassert(n.weight_bytes >= delta, "cannot give a node a negative weight");
            n.weight_bytes -= delta;
        } else {
            n.weight_bytes += delta;
        }
        cur = n.parent;
    }
}

fn transferRangeBetweenSiblings(src: *Node, dst: *Node, start: usize, count: usize, side: enum{Front, Back}) error{OutOfMemory}!void {
    debug.dassert(count > 0, "cannot transfer 0 nodes between siblings");
    debug.dassert(std.meta.activeTag(src.children) == std.meta.activeTag(dst.children), "source and destination must be the same type of node");
    debug.dassert(start == 0 or start + count == nodeCount(src), "insertions must be contiguous with start or end of source");
    switch (src.children) {
        .leaf => {
            const src_pieces = leafPieces(src);
            const dst_pieces = leafPieces(dst);
            debug.dassert(src_pieces.items.len >= count, "source must contain enough items to transfer");
            debug.dassert(dst_pieces.items.len > 0, "destination must not start empty");
            
            // calculate exactly how many bytes are moving
            const to_move = src_pieces.items[start..start + count];
            var moved_bytes: usize = 0;
            for (to_move) |*piece| { moved_bytes += piece.len; }

            switch (side) {
                .Front => try dst_pieces.insertSlice(0, to_move),
                .Back  => try dst_pieces.appendSlice(to_move),
            }
            _ = utils.orderedRemoveRange(Piece, src_pieces, start, count);
            // check for new merge opportunities
            const center: usize = switch (side) {
                .Front => count,
                .Back  => dst_pieces.items.len - count
            };
            mergeAround(dst, center);

            bubbleDelta(src, moved_bytes, true);
            bubbleDelta(dst, moved_bytes, false);
        },
        .internal => {
            const src_children = childList(src);
            const dst_children = childList(dst);
            debug.dassert(src_children.items.len >= count, "source must contain enough items to transfer");
            debug.dassert(dst_children.items.len > 0, "destination must not start empty");
            
            // calculate exactly how many bytes are moving
            const to_move = src_children.items[start..start + count];
            var moved_bytes: usize = 0;
            for (to_move) |node| { moved_bytes += node.weight_bytes; }

            switch (side) {
                .Front => try dst_children.insertSlice(0, to_move),
                .Back  => try dst_children.appendSlice(to_move),
            }
            _ = utils.orderedRemoveRange(*Node, src_children, start, count);
            // fix parent pointers for moved children
            const adopted = switch (side) {
                .Front => dst_children.items[0..count],
                .Back  => dst_children.items[dst_children.items.len - count..]
            };
            for (adopted) |child| child.parent = dst;

            bubbleDelta(src, moved_bytes, true);
            bubbleDelta(dst, moved_bytes, false);
        }
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
    const take_right = @min(total_want, right_spare);
    total_want -= take_right;
    const take_left = @min(total_want, left_spare);
    return .{ .take_left = take_left, .take_right = take_right };
}

fn tryBorrow(node: *Node, siblings: Siblings) error{OutOfMemory}!usize {
    // uses a borrow plan to take exactly as many nodes from neighbors as can be spared
    const plan = planBorrow(node, siblings);
    if (siblings.l) |left| {
        if (plan.take_left > 0) { 
            try transferRangeBetweenSiblings(left, node, nodeCount(left) - plan.take_left, plan.take_left, .Front);
        }
    }
    if (siblings.r) |right| {
        if (plan.take_right > 0) {
            try transferRangeBetweenSiblings(right, node, 0, plan.take_right, .Back);
        }
    }
    return plan.take_left + plan.take_right;
}

// -------------------- PIECE TABLE IMPLEMENTATION --------------------

pub const TextEngine = struct {
    // piece table collection object.
    // holds a pointer to the original document as well as a working append-only buffer.
    // holds a collection of ordered "pieces" which describe how to build a final document using the two buffers.
    original: []const u8,
    add: std.ArrayList(u8),
    root: *Node,
    doc_len: usize,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, original: []const u8) error{OutOfMemory}!TextEngine {
        // initialize the root of the tree
        const leaf = try initLeaf(alloc);
        if (original.len != 0) {
            try leafPieces(leaf).append(.{ .buf = .Original, .off = 0, .len = original.len });
            leaf.weight_bytes = original.len;
        }
        return TextEngine{
            .original = original,
            .add = std.ArrayList(u8).init(alloc),
            .root = leaf,
            .doc_len = original.len,
            .alloc = alloc,
        };
    }
    
    pub fn deinit(self: *TextEngine) void {
        self.add.deinit();
        freeTree(self.alloc, self.root);
    }

    pub fn insert(self: *TextEngine, at: usize, text: []const u8) error{OutOfMemory}!void {
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
            bubbleDelta(leaf, text.len, false);
            self.doc_len += text.len;
            return;
        }

        const loc = locateInLeaf(leaf, found.offset);
        const idx = try spliceIntoLeaf(pieces, loc, add_offset, text.len);
        mergeAround(leaf, idx);
        bubbleDelta(leaf, text.len, false);
        try self.bubbleOverflowUp(leaf);
        self.doc_len += text.len;
    }

    pub fn delete(self: *TextEngine, at: usize, len: usize) error{OutOfMemory}!void {
        debug.dassert(at + len <= self.doc_len, "cannot delete outside of document");
        debug.dassert(len > 0, "cannot delete empty span");

        var remaining = len;
        const found = findAt(self.root, at);
        var leaf = found.leaf;
        var offset = found.offset;

        const left: *Node = leaf;
        var right: *Node = leaf;

        while (remaining > 0) {
            const in_leaf = locateInLeaf(leaf, offset);
            const removed = try deleteFromLeaf(leaf, in_leaf, remaining);
            bubbleDelta(leaf, removed, true);
            right = leaf;
            remaining -= removed;

            offset = 0;
            const next_leaf = nextLeaf(leaf);
            if (remaining > 0) {
                debug.dassert(next_leaf != null, "reached rightmost leaf with non-empty deletion queue");
                leaf = next_leaf.?;
            }
            
        }
        try self.repairAfterDelete(left, right);
        self.doc_len -= len;
    }

    pub fn materialize(self: *TextEngine, w: anytype) @TypeOf(w).Error!void {
        try self.writeSubtree(w, self.root);
    }

    // -------------------- WRITE HELPERS --------------------

    fn writeSubtree(self: *TextEngine, w: anytype, node: *const Node) @TypeOf(w).Error!void {
        switch (node.children) {
            .leaf => try self.writeLeaf(w, node),
            .internal => |*children| try self.writeChildren(w, children.items, 0)
        }
    }

    fn writeLeaf(self: *TextEngine, w: anytype, leaf: *const Node) @TypeOf(w).Error!void {
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

    fn writeChildren(self: *TextEngine, w: anytype, children: []const *Node, idx: usize) @TypeOf(w).Error!void {
        if (idx >= children.len) return;
        // traverse deeper on leftmost node
        try self.writeSubtree(w, children[idx]);
        // traverse left to right inside this branch
        return self.writeChildren(w, children, idx + 1);
    }

    // -------------------- INSERT HELPERS --------------------

    fn bubbleOverflowUp(self: *TextEngine, start: *Node) error{OutOfMemory}!void {
        // It's possible that a node split overflows it's parent, which splits and overflows IT'S parent...
        // Thus the logic needs to "bubble up" from the bottom of the tree until splits stop happening
        var cur: ?*Node = start;
        while (cur) |n| {
            const parent = try self.splitNodeIfOverflow(n);
            if (parent == null) return;
            cur = parent;
        }
    }

    fn splitNodeIfOverflow(self: *TextEngine, node: *Node) error{OutOfMemory}!?*Node {
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
                // calculate exactly how many bytes are moving
                const to_move = pieces.items[mid..];
                var moved_bytes: usize = 0;
                for (to_move) |*piece| { moved_bytes += piece.len; }
                // move them
                try leafPieces(right).appendSlice(to_move);
                pieces.shrinkRetainingCapacity(mid);
                // manually adjust node weights, faster than a full recompute
                debug.dassert(node.weight_bytes >= moved_bytes, "leaf split size underflow");
                node.weight_bytes -= moved_bytes;
                right.weight_bytes = moved_bytes;
                // add the newly split node into the tree
                return self.spliceNodeInTree(node, right);
            },
            .internal => |*children| {
                // same as leaf case above, but just different enough to not be one function call
                if (children.items.len <= MAX_BRANCH) return null;
                const mid = children.items.len / 2;
                const right = try initInternal(self.alloc);
                const to_move = children.items[mid..];
                var moved_bytes: usize = 0;
                for (to_move) |n| { moved_bytes += n.weight_bytes; }
                try childList(right).appendSlice(to_move);
                children.shrinkRetainingCapacity(mid);
                // fix parent pointers
                for (childList(right).items) |child| child.parent = right;
                debug.dassert(node.weight_bytes >= moved_bytes, "leaf split size underflow");
                node.weight_bytes -= moved_bytes;
                right.weight_bytes = moved_bytes;
                return self.spliceNodeInTree(node, right);
            }
        }
    }

    fn spliceNodeInTree(self: *TextEngine, old: *Node, new: *Node) error{OutOfMemory}!?*Node {
        // general case, add the new node one to the right of the old
        if (old.parent) |parent| {
            const siblings = childList(parent);
            const idx = indexOfChild(parent, old);
            try siblings.insert(idx + 1, new);
            new.parent = parent;
            return parent;
        // edge case, old node was the root, create a new root and create both as siblings
        } else {
            const root = try initInternal(self.alloc);
            try childList(root).append(old);
            try childList(root).append(new);
            old.parent = root;
            new.parent = root;
            root.weight_bytes = old.weight_bytes + new.weight_bytes;
            self.root = root;
            return null;
        }
    }

    // -------------------- DELETE HELPERS --------------------

    fn repairAfterDelete(self: *TextEngine, left: *Node, right: *Node) error{OutOfMemory}!void {
        try self.repairUpward(left);
        if (left != right) try self.repairUpward(right);
        try self.tryCollapseRoot();
    }

    fn repairUpward(self: *TextEngine, start: *Node) error{OutOfMemory}!void {
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
                    if (try self.mergeWithSibling(node, left)) |parent| { cur = parent; continue; }
                }
                if (siblings.r) |right| {
                    if (try self.mergeWithSibling(right, node)) |parent| { cur = parent; continue; }
                }
                // failing that, try and borrow children
                const borrowed = try tryBorrow(node, siblings);
                if (borrowed >= demand) { cur = node.parent; continue; }
            }
            cur = node.parent;
        }
    }

    fn tryCollapseRoot(self: *TextEngine) error{OutOfMemory}!void {
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
            }
        }
    }

    fn infanticide(self: *TextEngine, parent: *Node, child: *Node) void {
        // metal
        const siblings = childList(parent);
        const idx = indexOfChild(parent, child);
        _ = siblings.orderedRemove(idx);
        freeTree(self.alloc, child);
    }

    fn mergeWithSibling(self: *TextEngine, src: *Node, dst: *Node) error{OutOfMemory}!?*Node {
        if (nodeCount(src) + nodeCount(dst) > nodeMax(dst)) return null;
        try transferRangeBetweenSiblings(src, dst, 0, nodeCount(src), .Back);
        const parent = src.parent.?;
        self.infanticide(parent, src);
        return parent;
    }
};
