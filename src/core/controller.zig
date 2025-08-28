const std = @import("std");
const sapp = @import("sokol").app;
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;

const Y_SCROLL = 2;
const X_SCROLL = 2;
const REVERSE_DIR = true;

pub const Command = union(enum) {
    save,
    exit,
    noop,
    done,
};

pub const Controller = struct {
    doc: *Document,
    vp: *Viewport,

    pub fn onEvent(self: *Controller, ev: [*c]const sapp.Event) !Command {
        // this has a very specific contract which is important to understand. 
        // If the controller determines some action is requested which it cannot handle (save/exit/etc),
        // then it will return that action as a command for the app to deal with.
        // If the event is unsupported, it returns a .noop command, do nothing
        // If the event was supported and handled, it returns .done. 
        var modified = false;
        switch (ev.*.type) {
            .KEY_DOWN => {
                modified = true;
                const key = ev.*.key_code;
                const modifiers = modifiersOf(ev);
                // ctrl-s to save
                if (modifiers.ctrl and key == .S) return .save;
                // ctrl-d to exit
                if (modifiers.ctrl and key == .D) return .exit;

                switch (key) {
                    .RIGHT => try self.doc.moveRight(),
                    .LEFT => try self.doc.moveLeft(),
                    .DOWN => try self.doc.moveDown(),
                    .UP => try self.doc.moveUp(),
                    .HOME => try self.doc.moveHome(),
                    .END => try self.doc.moveEnd(),
                    .BACKSPACE => try self.doc.caretBackspace(1),
                    .ENTER => try self.doc.caretInsert("\n"),
                    else => return .noop,
                }
            },
            .CHAR => {
                modified = true;
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(ev.*.char_code), &buf);
                try self.doc.caretInsert(buf[0..len]);
            },
            .MOUSE_ENTER => sapp.setMouseCursor(.IBEAM),
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
                self.vp.scrollBy(d_lines, d_cols);
            },
            else => return .noop,
        }
        // if the cursor was modified in any way, jump to it
        if (modified) {
            const caret_pos = self.doc.caret.pos;
            self.vp.ensureCaretVisible(caret_pos);
            self.vp.clampVert(self.doc.lineCount());
            const active_line_span = try self.doc.lineSpan(caret_pos.line);
            self.vp.clampHorz(active_line_span.len);
        }
        return .done;
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
