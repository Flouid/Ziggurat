const std        = @import("std");
const sapp       = @import("sokol").app;
const file_io    = @import("file_io");
const Document   = @import("document").Document;
const Viewport   = @import("viewport").Viewport;
const LayoutMod  = @import("layout");
const Renderer   = @import("renderer").Renderer;
const Theme      = @import("renderer").Theme;
const Controller = @import("controller").Controller;


const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator = undefined,
    doc: Document = undefined,
    vp: Viewport = undefined,
    controller: Controller = undefined,
    renderer: Renderer = undefined,
    path_in: ?[]const u8 = null,

    fn init(self: *App) !void {
        const gpa = self.gpa.allocator();
        // initialize document
        if (self.path_in) |p| {
            const bytes = try file_io.read(gpa, p);
            self.doc = try Document.init(gpa, bytes);
        } else {
            self.doc = try Document.init(gpa, "");
        }
        // initialize viewport
        const pad = .{ .x = 0.5, .y = 0.5 };
        const dims = windowCells(pad.x, pad.y);
        self.vp = .{
            .top_line = 0,
            .left_col = 0,
            .height = dims.h,
            .width  = dims.h,
        };
        // initialize controller
        self.controller = .{ .doc = &self.doc, .vp = &self.vp };
        // initialize renderer
        self.renderer = Renderer.init(.{
            .background = 0x000000FF,
            .foreground = 0xFFFFFFFF,
            .caret      = 0xFFFFFFFF,
            .pad_x      = pad.x,
            .pad_y      = pad.y,
        });
        // initialize arena for rendering each frame
        self.arena = std.heap.ArenaAllocator.init(gpa);
    }

    fn deinit(self: *App) void {
        self.renderer.deinit();
        self.doc.deinit();
        self.arena.deinit();
        _ = self.gpa.deinit();
    }

    fn frame(self: *App) !void {
        // calculating dimensions per frame natively supports resizing
        const dims = windowCells(self.renderer.theme.pad_x, self.renderer.theme.pad_y);
        self.vp.height = dims.h;
        self.vp.width  = dims.w;
        // keep caret visible and clamped within the frame
        const caret_pos = self.doc.caret.pos;
        self.vp.ensureCaretVisible(caret_pos);
        self.vp.clampVert(self.doc.lineCount());
        const active_line_span = try self.doc.lineSpan(caret_pos.line);
        self.vp.clampHorz(active_line_span.len);
        // build layout
        _ = self.arena.reset(.retain_capacity);
        const layout = try LayoutMod.build(self.arena.allocator(), &self.doc, &self.vp);
        // render frame
        self.renderer.beginFrame();
        try self.renderer.draw(&self.doc, &layout);
        self.renderer.endFrame();
    }
};

fn windowCells(pad_x: f32, pad_y: f32) struct { w: usize, h: usize} {
    const w_px = @as(f32, @floatFromInt(sapp.width()));
    const h_px = @as(f32, @floatFromInt(sapp.height()));
    const cell_px: f32 = 8.0;
    const avail_w = w_px - 2.0 * pad_x;
    const avail_h = h_px - 2.0 * pad_y;
    const cols: usize = if (avail_w <= 0) 0 else @intFromFloat(@floor(avail_w / cell_px));
    const rows: usize = if (avail_h <= 0) 0 else @intFromFloat(@floor(avail_h / cell_px));
    return .{ .w = cols, .h = rows };
}

// GLOBAL app instance, sokol wants this
var G: App = .{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };

// sokol callbacks

fn init_cb() callconv(.c) void {
    G.init() catch |e| {
        std.log.err("init failed: {s}\n", .{ @errorName(e) });
        sapp.requestQuit();
    };
}

fn frame_cb() callconv(.c) void {
    G.frame() catch |e| {
        std.log.err("failure when rendering frame: {s}\n", .{ @errorName(e) });
        sapp.requestQuit();
    };
}

fn cleanup_cb() callconv(.c) void {
    G.deinit();
}

fn event_cb(ev: [*c]const sapp.Event) callconv(.c) void {
    G.controller.onEvent(ev) catch |e| {
        std.log.err("failure processing input: {s}\n", .{ @errorName(e) });
        sapp.requestQuit();
    };
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