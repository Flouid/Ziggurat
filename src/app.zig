const std = @import("std");
const sapp = @import("sokol").app;
const Document  = @import("document").Document;
const Viewport  = @import("viewport").Viewport;
const LayoutMod = @import("layout");
const Renderer  = @import("renderer").Renderer;
const Theme     = @import("renderer").Theme;

const CELL_PX: f32 = 8.0;

const HARD_CODED_PATH = "../../fixtures/example.txt";

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    arena: std.heap.ArenaAllocator = undefined,
    doc: Document = undefined,
    vp: Viewport = undefined,
    renderer: Renderer = undefined,

    fn init(self: *App) !void {
        const gpa = self.gpa.allocator();
        // initialize document
        const bytes = try std.fs.cwd().readFileAlloc(gpa, HARD_CODED_PATH, std.math.maxInt(usize));
        self.doc = try Document.init(gpa, bytes);
        // initialize viewport
        const padding = .{ .x = 4.0, .y = 4.0 };
        const dims = windowCells(padding.x, padding.y);
        self.vp = .{
            .top_line = 0,
            .left_col = 0,
            .height = dims.h,
            .width  = dims.h,
        };
        // initialize renderer
        self.renderer = Renderer.init(.{
            .background = 0x000000FF,
            .foreground = 0xFFFFFFFF,
            .caret      = 0xFFFFFFFF,
            .pad_px_x   = padding.x,
            .pad_px_y   = padding.y,
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
        const dims = windowCells(self.renderer.theme.pad_px_x, self.renderer.theme.pad_px_y);
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

fn windowCells(pad_px_x: f32, pad_px_y: f32) struct { w: usize, h: usize} {
    const w_px = @as(f32, @floatFromInt(sapp.width()));
    const h_px = @as(f32, @floatFromInt(sapp.height()));
    const avail_w = w_px - 2.0 * pad_px_x;
    const avail_h = h_px - 2.0 * pad_px_y;

    const cols: usize = if (avail_w <= 0) 0 else @intFromFloat(@floor(avail_w / CELL_PX));
    const rows: usize = if (avail_h <= 0) 0 else @intFromFloat(@floor(avail_h / CELL_PX));
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
    G.frame() catch unreachable;
}

fn cleanup_cb() callconv(.c) void {
    G.deinit();
}

fn event_cb(ev: [*c]const sapp.Event) callconv(.c) void {
    // v0 has no interaction :(
    _ = ev;
}

pub fn main() !void {
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