const std = @import("std");
const sapp = @import("sokol").app;
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const Geometry = @import("geometry").Geometry;

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

    pub fn onEvent(self: *Controller, ev: [*c]const sapp.Event) !Command {
        // this has a very specific contract which is important to understand.
        // If the controller determines some action is requested which it cannot handle (save/exit/etc),
        // then it will return that action as a command for the app to deal with.
        // If the event is unsupported, it returns a .noop command, do nothing
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
                    .RIGHT => try traverseWithModifiers(self.doc, modifiers, Document.moveRight),
                    .LEFT => try traverseWithModifiers(self.doc, modifiers, Document.moveLeft),
                    .DOWN => try traverseWithModifiers(self.doc, modifiers, Document.moveDown),
                    .UP => try traverseWithModifiers(self.doc, modifiers, Document.moveUp),
                    // TODO: fix home and end, on my machine the events are KP_1 and KP_7 with or without numlock
                    .HOME => try traverseWithModifiers(self.doc, modifiers, Document.moveHome),
                    .END => try traverseWithModifiers(self.doc, modifiers, Document.moveEnd),
                    .BACKSPACE => try self.doc.caretBackspace(),
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
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(ev.*.char_code), &buf);
                try self.doc.caretInsert(buf[0..len]);
            },
            .MOUSE_DOWN => {
                const pos = try self.geom.mouseToTextPos(self.doc, self.vp, ev.*.mouse_x, ev.*.mouse_y);
                if (pos) |p| try self.doc.moveTo(p);
                return .edit;
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

fn traverseWithModifiers(doc: *Document, modifiers: Modifiers, comptime traverse: fn (*Document) error{OutOfMemory}!void) !void {
    if (modifiers.shift and !doc.hasSelection()) doc.startSelection();
    if (!modifiers.shift) doc.resetSelection();
    try traverse(doc);
}
