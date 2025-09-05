const std = @import("std");
const sapp = @import("sokol").app;
const clipboard = @import("clipboard");
const Document = @import("document").Document;
const Caret = @import("document").Caret;
const Selection = @import("document").Selection;
const Viewport = @import("viewport").Viewport;
const Geometry = @import("geometry").Geometry;
const PixelPos = @import("types").PixelPos;
const TextPos = @import("types").TextPos;
const Span = @import("types").Span;

// scrolling policy
const Y_SCROLL = 2;
const X_SCROLL = 2;
const REVERSE_DIR = true;
// double click policy
const DOUBLE_CLICK_MS: u64 = 400;
const CLICK_SLOP_SQ: f32 = 36;
// edit coalescing policy
const COALESCE_WINDOW_MS: u64 = std.time.ms_per_s;
const BREAK_ON_NEWLINE: bool = true;

fn now() u64 {
    // one source of truth for the current timestamp.
    // This WILL crash if the system's time is set before 1970...
    return @intCast(std.time.milliTimestamp());
}

pub const Command = union(enum) {
    save,
    exit,
    refresh,
    resize,
    handled,
};

pub const Controller = struct {
    doc: *Document,
    vp: *Viewport,
    geom: *Geometry,
    history: History = .empty,
    alloc: std.mem.Allocator,
    // mouse click tracking
    mouse_held: bool = false,
    click_count: u8 = 0,
    last_click_ms: u64 = 0,
    last_click_pixel_pos: PixelPos = .origin,
    last_click_text_pos: TextPos = .origin,
    last_button: sapp.Mousebutton = .LEFT,
    mouse_pos: PixelPos = .origin,

    pub fn deinit(self: *Controller) void {
        self.history.deinit(self.alloc);
    }

    pub fn onEvent(self: *Controller, ev: [*c]const sapp.Event) !Command {
        // this has a very specific contract which is important to understand.
        // If the controller determines some action is requested which it cannot handle (save/exit/etc),
        // then it will return that action as a command for the app to deal with.
        // If the event can be handled and does not change the visible state, return .handled.
        // If the event was handled but mutated visible state, trigger a refresh with .refresh.
        switch (ev.*.type) {
            .KEY_DOWN => {
                const key = ev.*.key_code;
                const modifiers = modifiersOf(ev);
                // handle ctrl+key shortcuts
                if (modifiers.ctrl) {
                    switch (key) {
                        .S => return .save,
                        .D => return .exit,
                        .X => {
                            try self.copySelectionToClipboard();
                            try self.handleBackspace(modifiers);
                            return .refresh;
                        },
                        .C => {
                            try self.copySelectionToClipboard();
                            return .handled;
                        },
                        .V => {
                            const buf = try clipboard.read();
                            try self.handleTyping(buf, true);
                            return .refresh;
                        },
                        .A => {
                            try self.doc.selectDocument();
                            return .refresh;
                        },
                        else => {},
                    }
                }
                // handle generic key presses
                switch (key) {
                    .RIGHT => {
                        if (modifiers.ctrl) {
                            try self.moveWithModifiers(modifiers, Document.moveWordRight);
                        } else try self.moveWithModifiers(modifiers, Document.moveRight);
                    },
                    .LEFT => {
                        if (modifiers.ctrl) {
                            try self.moveWithModifiers(modifiers, Document.moveWordLeft);
                        } else try self.moveWithModifiers(modifiers, Document.moveLeft);
                    },
                    .DOWN => try self.moveWithModifiers(modifiers, Document.moveDown),
                    .UP => try self.moveWithModifiers(modifiers, Document.moveUp),
                    // TODO: fix home and end, on my machine the events are KP_1 and KP_7 with or without numlock
                    .HOME => try self.moveWithModifiers(modifiers, Document.moveHome),
                    .END => try self.moveWithModifiers(modifiers, Document.moveEnd),
                    .BACKSPACE => try self.handleBackspace(modifiers),
                    .DELETE => try self.handleDelete(modifiers),
                    .ENTER => try self.handleTyping("\n", false),
                    .ESCAPE => {
                        if (self.doc.sel.active()) {
                            self.doc.sel.resetAnchor();
                            return .refresh;
                        } else return .handled;
                    },
                    else => return .handled,
                }
            },
            .CHAR => {
                const modifiers = modifiersOf(ev);
                if (modifiers.ctrl or modifiers.alt or modifiers.super) return .handled;
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(ev.*.char_code), &buf);
                try self.handleTyping(buf[0..len], false);
            },
            .MOUSE_DOWN => {
                // clicks end the current transaction
                self.history.commit();
                self.mouse_held = true;
                const x = ev.*.mouse_x;
                const y = ev.*.mouse_y;
                const btn = ev.*.mouse_button;
                // determine if this is part of a sequence of clicks
                const button_match = btn == self.last_button;
                const now_ms = now();
                const fast_enough = now_ms - self.last_click_ms <= DOUBLE_CLICK_MS;
                const close_enough = Geometry.distanceSquared(self.last_click_pixel_pos.x, self.last_click_pixel_pos.y, x, y) <= CLICK_SLOP_SQ;
                const click_seq = button_match and fast_enough and close_enough;
                // track internal state accordingly
                if (click_seq) {
                    if (self.click_count < std.math.maxInt(u8)) self.click_count += 1;
                } else {
                    self.click_count = 1;
                    self.last_button = btn;
                }
                self.last_click_ms = now_ms;
                self.last_click_pixel_pos = .{ .x = x, .y = y };
                const pos = try self.geom.mouseToTextPos(self.doc, self.vp, x, y) orelse return .handled;
                self.last_click_text_pos = pos;
                // handle each case
                switch (self.click_count) {
                    1 => {
                        try self.doc.moveTo(pos);
                        self.doc.sel.resetAnchor();
                    },
                    2 => try self.doc.selectWord(),
                    3 => try self.doc.selectLine(),
                    4 => try self.doc.selectDocument(),
                    else => {},
                }
                return .refresh;
            },
            .MOUSE_MOVE => {
                self.mouse_pos = .{ .x = ev.*.mouse_x, .y = ev.*.mouse_y };
                if (!self.mouse_held) return .handled;
                const pos = try self.geom.mouseToTextPos(self.doc, self.vp, ev.*.mouse_x, ev.*.mouse_y) orelse return .handled;
                const not_last_click_pos = pos.row != self.last_click_text_pos.row or pos.col != self.last_click_text_pos.col;
                if (!self.doc.sel.active() and not_last_click_pos) self.doc.sel.dropAnchor();
                try self.doc.moveTo(pos);
            },
            .MOUSE_UP => {
                self.mouse_held = false;
                return .handled;
            },
            .MOUSE_ENTER => {
                sapp.setMouseCursor(.IBEAM);
                return .handled;
            },
            .MOUSE_SCROLL => {
                const modifiers = modifiersOf(ev);
                var dx = ev.*.scroll_x / 4;
                var dy = ev.*.scroll_y / 4;
                // support shift + scroll -> horizontal scroll
                if (dx == 0 and dy != 0 and modifiers.shift) {
                    dx = dy;
                    dy = 0;
                }
                // support reversing scroll direction
                if (REVERSE_DIR) {
                    dx = -dx;
                    dy = -dy;
                }
                const d_lines: isize = @intFromFloat(dy * Y_SCROLL);
                const d_cols: isize = @intFromFloat(dx * X_SCROLL);
                const n_lines = self.doc.lineCount();
                const n_cols = self.doc.lineLength();
                if (!self.vp.scrollBy(d_lines, d_cols, n_lines, n_cols)) return .handled;
                return .refresh;
            },
            .RESIZED => return .resize,
            else => return .handled,
        }
        // unless skipped via early return, ensure the caret is visible
        const caret_pos = self.doc.sel.caret.pos;
        const n_lines = self.doc.lineCount();
        const n_cols = self.doc.lineLength();
        self.vp.ensureCaretVisible(caret_pos, n_lines, n_cols);
        return .refresh;
    }

    pub fn autoScroll(self: *const Controller) !bool {
        if (!self.doc.sel.active() or !self.mouse_held) return false;
        const mouse_pos = try self.geom.mouseToTextPos(self.doc, self.vp, self.mouse_pos.x, self.mouse_pos.y) orelse return false;
        if (!self.vp.posNearEdge(mouse_pos, self.doc.lineCount(), self.doc.lineLength())) return false;
        const caret_pos = self.doc.sel.caret.pos;
        if (mouse_pos.row == caret_pos.row and mouse_pos.col == caret_pos.col) return false;
        try self.doc.moveTo(mouse_pos);
        return true;
    }

    fn buildSlice(self: *const Controller, span: Span) ![]const u8 {
        const slice = try self.alloc.alloc(u8, span.len);
        var w: std.Io.Writer = .fixed(slice);
        try self.doc.materializeRange(&w, span);
        try w.flush();
        return slice;
    }

    fn copySelectionToClipboard(self: *const Controller) !void {
        const span = self.doc.sel.span() orelse return;
        const slice = try self.buildSlice(span);
        defer self.alloc.free(slice);
        try clipboard.write(slice);
    }

    fn moveWithModifiers(self: *Controller, modifiers: Modifiers, comptime move: fn (*Document, bool) error{OutOfMemory}!void) !void {
        if (modifiers.shift and !self.doc.sel.active()) self.doc.sel.dropAnchor();
        const cancel_selection = self.doc.sel.active() and !modifiers.shift;
        try move(self.doc, cancel_selection);
        // end any open transactions in the history when navigating
        self.history.commit();
    }

    fn handleTyping(self: *Controller, bytes: []const u8, is_paste: bool) !void {
        // end the current transaction on exit if it contains a newline and that policy is enabled
        defer if (BREAK_ON_NEWLINE and std.mem.indexOfScalar(u8, bytes, '\n') != null) self.history.commit();
        const origin: Origin = if (is_paste) .paste else .typing;
        try self.history.ensureTransaction(self.alloc, self.doc, origin);
        // handle replace behavior, create a delete operation as part of the current transaction
        if (self.doc.sel.active()) {
            const span = self.doc.sel.span().?;
            const old = try self.buildSlice(span);
            defer self.alloc.free(old);
            // document can handle this implicitly, but doing it here updates the selection for snapshots
            try self.doc.caretBackspace();
            // the delete portion of the replace must be reversible, so it is logged as a seperate edit
            try self.history.appendDelete(self.alloc, self.doc, span.start, old);
        }
        const at = self.doc.sel.caret.byte;
        try self.doc.caretInsert(bytes);
        try self.history.appendInsert(self.alloc, self.doc, at, bytes);
    }

    fn deleteSelection(self: *Controller) !void {
        // helper for deleting the current selection from the document and adding it to the current transaction
        const span = self.doc.sel.span() orelse return;
        const old = try self.buildSlice(span);
        defer self.alloc.free(old);
        try self.doc.caretBackspace();
        try self.history.appendDelete(self.alloc, self.doc, span.start, old);
    }

    fn handleBackspace(self: *Controller, modifiers: Modifiers) !void {
        try self.history.ensureTransaction(self.alloc, self.doc, .backspace);
        // on exit, delete whatever is selected and store it in the current transaction
        // that means the only responsibility of the rest of this function is building a correct selection
        defer self.deleteSelection() catch @panic("deletion failed inside handleBackspace!");
        // handle deleting a selection
        if (self.doc.sel.active()) return;
        // handle word-granular deletion when there is no selection
        if (modifiers.ctrl) {
            self.doc.sel.dropAnchor();
            try self.doc.moveWordLeft(false);
            return;
        }
        // default case for unmodified single backspace, start a selection and move one left
        self.doc.sel.dropAnchor();
        try self.doc.moveLeft(false);
    }

    fn handleDelete(self: *Controller, modifiers: Modifiers) !void {
        // this function is almost identical to backspace, read that for comments
        try self.history.ensureTransaction(self.alloc, self.doc, .delete);
        defer self.deleteSelection() catch @panic("deletion failed inside handleDelete!");
        if (self.doc.sel.active()) return;
        if (modifiers.ctrl) {
            self.doc.sel.dropAnchor();
            try self.doc.moveWordRight(false);
            return;
        }
        self.doc.sel.dropAnchor();
        try self.doc.moveRight(false);
    }
};

// -------------------- MODIFIERS --------------------

const Modifiers = packed struct {
    shift: bool,
    ctrl: bool,
    alt: bool,
    super: bool,
};

fn modifiersOf(ev: [*c]const sapp.Event) Modifiers {
    const m = ev.*.modifiers;
    return .{
        .shift = (m & sapp.modifier_shift) != 0,
        .ctrl = (m & sapp.modifier_ctrl) != 0,
        .alt = (m & sapp.modifier_alt) != 0,
        .super = (m & sapp.modifier_super) != 0,
    };
}

// -------------------- HISTORY --------------------

const Edit = union(enum) {
    insert: struct { at: usize, text: std.ArrayList(u8) },
    delete: struct { at: usize, text: std.ArrayList(u8) },

    fn deinit(self: *Edit, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .insert => |*i| i.text.deinit(alloc),
            .delete => |*d| d.text.deinit(alloc),
        }
    }
};

const Origin = enum { typing, backspace, delete, paste };

const HistoryEntry = struct {
    edits: std.ArrayList(Edit) = .empty,
    ante: Selection,
    post: Selection,
    origin: Origin,
    t_ms: u64,

    fn deinit(self: *HistoryEntry, alloc: std.mem.Allocator) void {
        for (self.edits.items) |*edit| edit.deinit(alloc);
        self.edits.deinit(alloc);
    }

    fn lastEdit(self: *HistoryEntry) ?*Edit {
        return if (self.edits.items.len == 0) null else &self.edits.items[self.edits.items.len - 1];
    }
};

const History = struct {
    entries: std.ArrayList(HistoryEntry) = .empty,
    index: usize = 0,
    tx_open: bool = false,

    const empty: History = .{};

    fn deinit(self: *History, alloc: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
    }

    fn hasTail(self: *const History) bool {
        return self.entries.items.len > 0;
    }

    fn tail(self: *History) *HistoryEntry {
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn commit(self: *History) void {
        self.tx_open = false;
    }

    fn shouldCoalesce(self: *History, origin: Origin) bool {
        if (!self.tx_open or !self.hasTail()) return false;
        const last = self.tail();
        if (last.origin != origin) return false;
        if (last.origin == .paste) return false;
        if (now() - last.t_ms > COALESCE_WINDOW_MS) return false;
        return true;
    }

    fn ensureTransaction(self: *History, alloc: std.mem.Allocator, doc: *Document, origin: Origin) error{OutOfMemory}!void {
        // ensures there is is an open transaction at the tail to edit
        if (self.shouldCoalesce(origin)) return;
        while (self.entries.items.len > self.index) {
            self.tail().deinit(alloc);
            _ = self.entries.pop();
        }
        try self.entries.append(alloc, .{
            .ante = doc.sel,
            .post = doc.sel,
            .origin = origin,
            .t_ms = now(),
        });
        self.index = self.entries.items.len;
        self.tx_open = true;
    }

    fn appendInsert(self: *History, alloc: std.mem.Allocator, doc: *Document, at: usize, bytes: []const u8) error{OutOfMemory}!void {
        const entry = self.tail();
        defer {
            entry.post = doc.sel;
            entry.t_ms = now();
        }
        // if the previous entry was also an insert, append onto it
        if (entry.lastEdit()) |edit| switch (edit.*) {
            .insert => |*i| {
                if (i.at + i.text.items.len == at and entry.origin == .typing) {
                    try i.text.appendSlice(alloc, bytes);
                } else @panic("noncontiguous insert within the same transaction");
                return;
            },
            else => {},
        };
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(alloc, bytes);
        try entry.edits.append(alloc, .{ .insert = .{ .at = at, .text = buf } });
    }

    fn appendDelete(self: *History, alloc: std.mem.Allocator, doc: *Document, at: usize, bytes: []const u8) error{OutOfMemory}!void {
        const entry = self.tail();
        defer {
            entry.post = doc.sel;
            entry.t_ms = now();
        }
        // if the previous edit was also a delete, append onto it
        if (entry.lastEdit()) |edit| switch (edit.*) {
            .delete => |*d| {
                if (at + bytes.len == d.at and entry.origin == .backspace) {
                    // contiguity check for backspace, can append onto the previous edit
                    try d.text.appendSlice(alloc, bytes);
                    d.at = at;
                } else if (d.at == at and entry.origin == .delete) {
                    // contiguity check for delete, can also append onto the previous edit
                    try d.text.appendSlice(alloc, bytes);
                } else @panic("noncontiguous delete within the same transaction");
                return;
            },
            else => {},
        };
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(alloc, bytes);
        try entry.edits.append(alloc, .{ .delete = .{ .at = at, .text = buf } });
    }
};
