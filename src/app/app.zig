const std = @import("std");
const sapp = @import("sokol").app;
const file_io = @import("file_io");
const Document = @import("document").Document;
const Viewport = @import("viewport").Viewport;
const Layout = @import("layout").Layout;
const Renderer = @import("renderer").Renderer;
const Theme = @import("renderer").Theme;
const Geometry = @import("geometry").Geometry;
const Controller = @import("controller").Controller;
const ScreenDims = @import("types").ScreenDims;

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator = undefined,
    geom: Geometry = undefined,
    doc: Document = undefined,
    vp: Viewport = undefined,
    controller: Controller = undefined,
    renderer: Renderer = undefined,
    path_in: ?[]const u8 = null,
    // for rebuilding frames only after changes
    dirty: bool = false,
    cached_layout: Layout = undefined,
    // for blinking caret
    blink_accum_ns: u64 = 0,
    blink_period_ns: u64 = std.time.ns_per_s,
    last_tick_ns: u64 = 0,

    fn init(self: *App) !void {
        const gpa = self.gpa.allocator();
        // initialize geometry
        self.geom = .{ .cell_h_px = 8.0, .cell_w_px = 8.0, .pad_x_cells = 0.5, .pad_y_cells = 0.5 };
        // initialize document
        if (self.path_in) |p| {
            const bytes = try file_io.read(gpa, p);
            self.doc = try Document.init(gpa, bytes);
        } else {
            self.doc = try Document.init(gpa, "");
        }
        // initialize viewport
        self.vp = .{ .top_line = 0, .left_col = 0, .dims = self.getScreenDims() };
        // initialize controller
        self.controller = .{ .doc = &self.doc, .vp = &self.vp, .geom = &self.geom };
        // initialize renderer
        self.renderer = Renderer.init(gpa, .{}, self.geom);
        // initialize arena for rendering each frame
        self.arena = std.heap.ArenaAllocator.init(gpa);
        // cache initial layout on open
        try self.refreshLayout();
        // initialize caret blink timer
        self.last_tick_ns = @intCast(std.time.nanoTimestamp());
    }

    fn deinit(self: *App) void {
        self.renderer.deinit();
        self.doc.deinit();
        self.arena.deinit();
        _ = self.gpa.deinit();
    }

    fn frame(self: *App) !void {
        // manage caret blinking
        const now: u64 = @intCast(std.time.nanoTimestamp());
        const dt = now - self.last_tick_ns;
        self.last_tick_ns = now;
        self.blink_accum_ns = (self.blink_accum_ns + dt) % self.blink_period_ns;
        const draw_caret = self.blink_accum_ns < self.blink_period_ns / 2;
        // rebuild the layout if an edit occured since last frame
        if (self.dirty) {
            self.dirty = false;
            try self.refreshLayout();
        }
        // render frame
        self.renderer.beginFrame();
        try self.renderer.draw(&self.doc, &self.cached_layout, draw_caret);
        self.renderer.endFrame();
    }

    fn save(self: *App) !void {
        if (self.path_in) |p| {
            const a = self.gpa.allocator();
            const buf = try a.alloc(u8, self.doc.size());
            defer a.free(buf);
            var w: std.Io.Writer = .fixed(buf);
            try self.doc.materialize(&w);
            try file_io.write(p, buf);
        } else std.log.err("cannot save unnamed document\n", .{});
    }

    fn refreshLayout(self: *App) !void {
        _ = self.arena.reset(.retain_capacity);
        self.cached_layout = try Layout.init(self.arena.allocator(), &self.doc, &self.vp);
    }

    fn getScreenDims(self: *const App) ScreenDims {
        return self.geom.pixelDimsToScreenDims(.{ .w = @floatFromInt(sapp.width()), .h = @floatFromInt(sapp.height()) });
    }
};

// GLOBAL app instance, sokol wants this
var G: App = .{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };

// sokol callbacks

fn init_cb() callconv(.c) void {
    G.init() catch |e| {
        std.log.err("init failed: {t}\n", .{e});
        sapp.requestQuit();
    };
}

fn frame_cb() callconv(.c) void {
    G.frame() catch |e| {
        std.log.err("failure when rendering frame: {t}\n", .{e});
        sapp.requestQuit();
    };
}

fn cleanup_cb() callconv(.c) void {
    G.deinit();
}

fn event_cb(ev: [*c]const sapp.Event) callconv(.c) void {
    const command = G.controller.onEvent(ev) catch |e| blk: {
        std.log.err("error handling event: {t}\n", .{e});
        break :blk .exit;
    };
    switch (command) {
        .save => G.save() catch |e| {
            std.log.err("failed to save document: {t}\n", .{e});
        },
        .exit => sapp.requestQuit(),
        .resize => G.vp.resize(G.getScreenDims()),
        .noop => return,
        else => {},
    }
    // if here, the command was NOT a noop, refresh the cached layout on next frame
    G.dirty = true;
    G.blink_accum_ns = 0;
}

pub fn run(path: ?[]const u8) !void {
    if (path) |p| G.path_in = p;
    sapp.run(.{
        .width = 1024,
        .height = 764,
        .window_title = "Ziggurat v0",
        .icon = .{ .sokol_default = true },
        .high_dpi = true,
        .init_cb = init_cb,
        .frame_cb = frame_cb,
        .cleanup_cb = cleanup_cb,
        .event_cb = event_cb,
        .logger = .{ .func = @import("sokol").log.func },
    });
}
