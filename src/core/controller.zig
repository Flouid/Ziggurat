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
                    .RIGHT => try self.doc.moveRight(),
                    .LEFT  => try self.doc.moveLeft(),
                    .DOWN  => try self.doc.moveDown(),
                    .UP    => try self.doc.moveUp(),
                    .HOME  => try self.doc.moveHome(),
                    .END   => try self.doc.moveEnd(),
                    else => {},
                }
            },
            else => {},
        }
    }
};