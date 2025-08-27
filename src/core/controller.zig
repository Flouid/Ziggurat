const std = @import("std");
const sapp = @import("sokol").app;
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;

pub const Command = union(enum) { 
    save,
    exit,
};

pub const Controller = struct {
    doc: *Document,
    vp: *Viewport,

    pub fn onEvent(self: *Controller, ev: [*c]const sapp.Event) !?Command {
        switch (ev.*.type) {
            .KEY_DOWN => {
                const key = ev.*.key_code;
                const modifiers = modifiersOf(ev);
                // ctrl-s to save
                if (modifiers.ctrl and key == .S) return .save;
                // ctrl-d to exit
                if (modifiers.ctrl and key == . D) return .exit;

                switch (key) {
                    .RIGHT => try self.doc.moveRight(),
                    .LEFT => try self.doc.moveLeft(),
                    .DOWN => try self.doc.moveDown(),
                    .UP => try self.doc.moveUp(),
                    .HOME => try self.doc.moveHome(),
                    .END => try self.doc.moveEnd(),
                    .BACKSPACE => try self.doc.caretBackspace(1),
                    .ENTER => try self.doc.caretInsert("\n"),
                    else => {},
                }
            },
            .CHAR => {
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(@intCast(ev.*.char_code), &buf);
                try self.doc.caretInsert(buf[0..len]);
            },
            else => {},
        }

        return null;
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
