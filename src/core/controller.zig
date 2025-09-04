const std = @import("std");
const sapp = @import("sokol").app;
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const Geometry = @import("geometry").Geometry;
const PixelPos = @import("types").PixelPos;
const TextPos = @import("types").TextPos;

const Y_SCROLL = 2;
const X_SCROLL = 2;
const REVERSE_DIR = true;

pub const Command = union(enum) {
    save,
    exit,
    edit,
    resize,
    noop,
};

pub const Controller = struct {
    doc: *Document,
    vp: *Viewport,
    geom: *Geometry,
    // mouse click tracking
    mouse_held: bool = false,
    click_count: u8 = 0,
    last_click_ms: u64 = 0,
    last_click_pixel_pos: PixelPos = .origin,
    last_click_text_pos: TextPos = .origin,
    last_button: sapp.Mousebutton = .LEFT,
    mouse_pos: PixelPos = .origin,

    const double_click_ms: u64 = 400;
    const click_slop_sq: f32 = 36;

    pub fn onEvent(self: *Controller, ev: [*c]const sapp.Event) !Command {
        // this has a very specific contract which is important to understand.
        // If the controller determines some action is requested which it cannot handle (save/exit/etc),
        // then it will return that action as a command for the app to deal with.
        // If the event is unsupported or doesn't require re-render, it returns a .noop command
        // If the event was supported and handled, it returns .edit (trigger re-render).
        switch (ev.*.type) {
            .KEY_DOWN => {
                const key = ev.*.key_code;
                const modifiers = modifiersOf(ev);
                // ctrl-s to save
                if (modifiers.ctrl and key == .S) return .save;
                // ctrl-d to exit
                if (modifiers.ctrl and key == .D) return .exit;

                switch (key) {
                    .RIGHT => {
                        if (modifiers.ctrl) {
                            try moveWithModifiers(self.doc, modifiers, Document.moveWordRight);
                        } else try moveWithModifiers(self.doc, modifiers, Document.moveRight);
                    },
                    .LEFT => {
                        if (modifiers.ctrl) {
                            try moveWithModifiers(self.doc, modifiers, Document.moveWordLeft);
                        } else try moveWithModifiers(self.doc, modifiers, Document.moveLeft);
                    },
                    .DOWN => try moveWithModifiers(self.doc, modifiers, Document.moveDown),
                    .UP => try moveWithModifiers(self.doc, modifiers, Document.moveUp),
                    // TODO: fix home and end, on my machine the events are KP_1 and KP_7 with or without numlock
                    .HOME => try moveWithModifiers(self.doc, modifiers, Document.moveHome),
                    .END => try moveWithModifiers(self.doc, modifiers, Document.moveEnd),
                    .BACKSPACE => {
                        if (modifiers.ctrl) {
                            try self.doc.deleteWordLeft();
                        } else try self.doc.caretBackspace();
                    },
                    .DELETE => {
                        if (modifiers.ctrl) {
                            try self.doc.deleteWordRight();
                        } else try self.doc.deleteForward();
                    },
                    .ENTER => try self.doc.caretInsert("\n"),
                    .ESCAPE => {
                        if (self.doc.hasSelection()) {
                            self.doc.resetSelection();
                            return .edit;
                        } else return .noop;
                    },
                    else => return .noop,
                }
            },
            .CHAR => {
                const modifiers = modifiersOf(ev);
                if (modifiers.ctrl or modifiers.alt or modifiers.super) return .noop;
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(ev.*.char_code), &buf);
                try self.doc.caretInsert(buf[0..len]);
            },
            .MOUSE_DOWN => {
                self.mouse_held = true;
                const x = ev.*.mouse_x;
                const y = ev.*.mouse_y;
                const btn = ev.*.mouse_button;
                const now: u64 = @intCast(std.time.milliTimestamp());
                // determine if this is part of a sequence of clicks
                const button_match = btn == self.last_button;
                const fast_enough = now - self.last_click_ms <= double_click_ms;
                const close_enough = Geometry.distanceSquared(self.last_click_pixel_pos.x, self.last_click_pixel_pos.y, x, y) <= click_slop_sq;
                const click_seq = button_match and fast_enough and close_enough;
                // track internal state accordingly
                if (click_seq) {
                    if (self.click_count < std.math.maxInt(u8)) self.click_count += 1;
                } else {
                    self.click_count = 1;
                    self.last_button = btn;
                }
                self.last_click_ms = now;
                self.last_click_pixel_pos = .{ .x = x, .y = y };
                const pos = try self.geom.mouseToTextPos(self.doc, self.vp, x, y) orelse return .noop;
                self.last_click_text_pos = pos;
                // handle each case
                switch (self.click_count) {
                    1 => {
                        try self.doc.moveTo(pos);
                        self.doc.resetSelection();
                    },
                    2 => try self.doc.selectWord(),
                    3 => try self.doc.selectLine(),
                    4 => try self.doc.selectDocument(),
                    else => {},
                }
                return .edit;
            },
            .MOUSE_MOVE => {
                self.mouse_pos = .{ .x = ev.*.mouse_x, .y = ev.*.mouse_y };
                if (!self.mouse_held) return .noop;
                const pos = try self.geom.mouseToTextPos(self.doc, self.vp, ev.*.mouse_x, ev.*.mouse_y) orelse return .noop;
                const not_last_click_pos = pos.row != self.last_click_text_pos.row or pos.col != self.last_click_text_pos.col;
                if (!self.doc.hasSelection() and not_last_click_pos) self.doc.startSelection();
                try self.doc.moveTo(pos);
            },
            .MOUSE_UP => {
                self.mouse_held = false;
                return .noop;
            },
            .MOUSE_ENTER => {
                sapp.setMouseCursor(.IBEAM);
                return .noop;
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
                if (!self.vp.scrollBy(d_lines, d_cols, n_lines, n_cols)) return .noop;
                return .edit;
            },
            .RESIZED => return .resize,
            else => return .noop,
        }
        // unless skipped via early return, ensure the caret is visible
        const caret_pos = self.doc.caret.pos;
        const n_lines = self.doc.lineCount();
        const n_cols = self.doc.lineLength();
        self.vp.ensureCaretVisible(caret_pos, n_lines, n_cols);
        return .edit;
    }

    pub fn autoScroll(self: *const Controller) !bool {
        if (!self.doc.hasSelection() or !self.mouse_held) return false;
        const mouse_pos = try self.geom.mouseToTextPos(self.doc, self.vp, self.mouse_pos.x, self.mouse_pos.y) orelse return false;
        if (!self.vp.posNearEdge(mouse_pos, self.doc.lineCount(), self.doc.lineLength())) return false;
        const caret_pos = self.doc.caret.pos;
        if (mouse_pos.row == caret_pos.row and mouse_pos.col == caret_pos.col) return false;
        try self.doc.moveTo(mouse_pos);
        return true;
    }
};

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

fn moveWithModifiers(doc: *Document, modifiers: Modifiers, comptime move: fn (*Document, bool) error{OutOfMemory}!void) !void {
    if (modifiers.shift and !doc.hasSelection()) doc.startSelection();
    const cancel_selection = doc.hasSelection() and !modifiers.shift;
    try move(doc, cancel_selection);
}
