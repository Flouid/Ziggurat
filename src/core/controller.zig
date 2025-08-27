const std      = @import("std");
const sapp     = @import("sokol").app;
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;


pub const Controller = struct {
    doc: *Document,
    vp:  *Viewport,

    pub fn onEvent(self: *Controller, ev: [*c]const sapp.Event) !void {
        switch (ev.*.type) {
            .KEY_DOWN => {
                const key = ev.*.key_code;
                switch (key) {
                    .RIGHT     => try self.doc.moveRight(),
                    .LEFT      => try self.doc.moveLeft(),
                    .DOWN      => try self.doc.moveDown(),
                    .UP        => try self.doc.moveUp(),
                    .HOME      => try self.doc.moveHome(),
                    .END       => try self.doc.moveEnd(),
                    .BACKSPACE => try self.doc.caretBackspace(1),
                    .ENTER     => try self.doc.caretInsert("\n"),
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
    }
};