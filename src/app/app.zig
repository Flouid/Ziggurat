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
    // for rebuilding frames only after changes
    dirty: bool = false,
    cached_layout: Layout = undefined,
    // for blinking caret
    blink_accum_ns: u64 = 0,
    blink_period_ns: u64 = std.time.ns_per_s,
    last_tick_ns: u64 = 0,
    // use a platform-agnostic memory map for O(1) file loading
    path_in: ?[]const u8 = null,
    mmap: file_io.MappedFile = undefined,
    // have a headless mode for testing
    headless: bool = true,

    const preinit: App = .{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };

    fn initCore(self: *App) !void {
        const gpa = self.gpa.allocator();
        self.geom = .{ .cell_h_px = 8.0, .cell_w_px = 8.0, .pad_x_cells = 0.5, .pad_y_cells = 0.5 };
        self.mmap = try file_io.MappedFile.initFromPath(self.path_in);
        self.doc = try Document.init(gpa, self.mmap.bytes);
        self.vp = .{ .top_line = 0, .left_col = 0, .dims = self.getScreenDims() };
        self.controller = .{ .doc = &self.doc, .vp = &self.vp, .geom = &self.geom };
        self.arena = std.heap.ArenaAllocator.init(gpa);
        try self.refreshLayout();
        self.last_tick_ns = @intCast(std.time.nanoTimestamp());
    }

    fn initGraphics(self: *App) void {
        self.headless = false;
        self.renderer = Renderer.init(self.gpa.allocator(), .{}, self.geom);
    }

    fn init(self: *App) !void {
        try self.initCore();
        self.initGraphics();
    }

    fn deinit(self: *App) void {
        if (!self.headless) self.renderer.deinit();
        self.doc.deinit();
        self.arena.deinit();
        _ = self.gpa.deinit();
        self.mmap.deinit();
    }

    fn frame(self: *App) !void {
        // manage caret blinking and autoscroll
        const now: u64 = @intCast(std.time.nanoTimestamp());
        const dt = now - self.last_tick_ns;
        self.last_tick_ns = now;
        self.blink_accum_ns = (self.blink_accum_ns + dt) % self.blink_period_ns;
        const draw_caret = self.blink_accum_ns < self.blink_period_ns / 2;
        try self.handleAutoScroll();
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
            const cwd = std.fs.cwd();
            const a = self.gpa.allocator();
            // write the current document to a temp file
            const temp_path = try file_io.tempPath(a, p);
            defer a.free(temp_path);
            var f = try cwd.createFile(temp_path, .{ .truncate = true });
            defer f.close();
            var buf: [64 * 1024]u8 = undefined;
            var fw = f.writer(buf[0..]);
            const w = &fw.interface;
            try self.doc.materialize(w);
            try w.flush();
            try f.sync();
            // build a logical document index for the current file
            const logical_idx = try self.doc.buffer.buildLogicalIndex();
            // unmap and delete the old source file, rename temp to it, and build new mmap
            self.mmap.deinit();
            try cwd.rename(temp_path, p);
            self.mmap = try file_io.MappedFile.initFromPath(p);
            // reinitialize the document's text buffer using the logical index created from the old one
            self.doc.buffer = try self.doc.buffer.reinit(self.mmap.bytes, logical_idx);
        } else std.log.err("cannot save unnamed document\n", .{});
    }

    fn handleAutoScroll(self: *App) !void {
        const moved = try self.controller.autoScroll();
        if (!moved) return;
        self.dirty = true;
        const caret_pos = self.doc.caret.pos;
        const n_lines = self.doc.lineCount();
        const n_cols = self.doc.lineLength();
        self.vp.ensureCaretVisible(caret_pos, n_lines, n_cols);
    }

    fn refreshLayout(self: *App) !void {
        _ = self.arena.reset(.retain_capacity);
        self.cached_layout = try Layout.init(self.arena.allocator(), &self.doc, &self.vp);
    }

    fn getScreenDims(self: *const App) ScreenDims {
        if (sapp.isvalid()) {
            return self.geom.pixelDimsToScreenDims(.{ .w = @floatFromInt(sapp.width()), .h = @floatFromInt(sapp.height()) });
        } else return self.geom.pixelDimsToScreenDims(.{ .w = 1024.0, .h = 768.0 });
    }
};

// GLOBAL app instance, sokol wants this
var G: App = .preinit;

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

// -------------------- TESTING --------------------

const small_file = "fixtures/example.txt";
const huge_file = "fixtures/huge_random_ut8.txt";

fn openWith(path: ?[]const u8, app: *App) !void {
    if (path) |p| app.path_in = p;
    try app.initCore();
}

test "opens huge file quickly" {
    var timer = try std.time.Timer.start();
    var app: App = .preinit;
    try openWith(huge_file, &app);
    defer app.deinit();
    const init_ns = timer.read();
    try std.testing.expect(init_ns < std.time.ns_per_s / 10);
}

test "deletes huge file without hiccup" {
    var app: App = .preinit;
    try openWith(huge_file, &app);
    defer app.deinit();
    var timer = try std.time.Timer.start();
    try app.doc.selectDocument();
    try app.doc.caretBackspace();
    const del_ns = timer.read();
    try std.testing.expect(del_ns < std.time.ns_per_s / 10);
    try std.testing.expect(app.doc.size() == 0);
}

test "replaces huge file without hiccup" {
    var app: App = .preinit;
    try openWith(huge_file, &app);
    defer app.deinit();
    var timer = try std.time.Timer.start();
    try app.doc.selectDocument();
    try app.doc.caretInsert("hello world!");
    const del_ns = timer.read();
    try std.testing.expect(del_ns < std.time.ns_per_s / 10);
    try std.testing.expect(app.doc.size() == 12);
}

test "selecting empty line selects document" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 4, .col = 0 });
    try app.doc.selectLine();
    const selection = app.doc.selectionSpan();
    try std.testing.expect(selection != null);
    try std.testing.expect(selection.?.start == 0);
    try std.testing.expect(selection.?.len == app.doc.size());
}

test "deleting empty line decrements line count and size" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    const old_size = app.doc.size();
    const old_lines = app.doc.lineCount();
    try app.doc.moveTo(.{ .row = 4, .col = 0 });
    try app.doc.caretBackspace();
    try std.testing.expect(app.doc.size() == old_size - 1);
    try std.testing.expect(app.doc.lineCount() == old_lines - 1);
}

test "adding empty line increments line count and size" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    const old_size = app.doc.size();
    const old_lines = app.doc.lineCount();
    try app.doc.moveTo(.{ .row = 4, .col = 0 });
    try app.doc.caretInsert("\n");
    try std.testing.expect(app.doc.size() == old_size + 1);
    try std.testing.expect(app.doc.lineCount() == old_lines + 1);
}

test "prefix appends work normally" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    const old_size = app.doc.size();
    try app.doc.caretInsert("hello world!");
    try std.testing.expect(app.doc.size() == old_size + 12);
}

test "suffix appends work normally" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    const old_size = app.doc.size();
    try app.doc.selectDocument();
    try app.doc.moveRight(true);
    try app.doc.caretInsert("hello world!");
    try std.testing.expect(app.doc.size() == old_size + 12);
}

test "word selection and deletion works as expected" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 0, .col = 6 });
    try app.doc.selectWord();
    const selection = app.doc.selectionSpan();
    try std.testing.expect(selection != null);
    try std.testing.expect(selection.?.start == 4);
    try std.testing.expect(selection.?.len == 5);
    const old_size = app.doc.size();
    try app.doc.caretBackspace();
    try std.testing.expect(app.doc.size() == old_size - selection.?.len);
}

test "line selection and deletion works as expected" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 0, .col = 6 });
    try app.doc.selectLine();
    const selection = app.doc.selectionSpan();
    try std.testing.expect(selection != null);
    try std.testing.expect(selection.?.start == 0);
    try std.testing.expect(selection.?.len == 43);
    const old_size = app.doc.size();
    try app.doc.caretBackspace();
    try std.testing.expect(app.doc.size() == old_size - selection.?.len);
}

test "move up from selection works as expected" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 16, .col = 3 });
    try app.doc.selectWord();
    try app.doc.moveUp(true);
    try std.testing.expect(app.doc.caret.pos.row == 15);
    try std.testing.expect(app.doc.caret.pos.col == 0);
}

test "move down from selection works as expected" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 16, .col = 3 });
    try app.doc.selectWord();
    try app.doc.moveDown(true);
    try std.testing.expect(app.doc.caret.pos.row == 17);
    try std.testing.expect(app.doc.caret.pos.col == 7);
}

test "move left from selection works as expected" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 16, .col = 3 });
    try app.doc.selectWord();
    try app.doc.moveLeft(true);
    try std.testing.expect(app.doc.caret.pos.row == 16);
    try std.testing.expect(app.doc.caret.pos.col == 0);
}

test "move right from selection works as expected" {
    var app: App = .preinit;
    try openWith(small_file, &app);
    defer app.deinit();
    try app.doc.moveTo(.{ .row = 16, .col = 3 });
    try app.doc.selectWord();
    try app.doc.moveRight(true);
    try std.testing.expect(app.doc.caret.pos.row == 16);
    try std.testing.expect(app.doc.caret.pos.col == 7);
}