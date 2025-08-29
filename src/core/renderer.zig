const std = @import("std");
const debug = @import("debug");
const Document = @import("document").Document;
const Layout = @import("layout").Layout;
const Geometry = @import("geometry").Geometry;
const PixelPos = @import("types").PixelPos;
const PixelDims = @import("types").PixelDims;
const ClipPos = @import("types").ClipPos;
const ClipRect = @import("types").ClipRect;
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const sdtx = sokol.debugtext;
const sgl = sokol.gl;
const sglue = sokol.glue;

pub const Theme = struct {
    // colors stored as packed 32-bit integers in RGBA order
    // for example, 0xRRGGBBAA
    background: u32 = 0x242936FF,
    foreground: u32 = 0xcccac2FF,
    caret: u32 = 0xffcc66FF,
    highlight: u32 = 0x409fff40,
};

pub const Renderer = struct {
    theme: Theme,
    alloc: std.mem.Allocator,
    line_buffer: []u8 = &[_]u8{},
    geom: Geometry,
    // cache colors in the form they'll be handed to sokol
    background: sgfx.Color,
    foreground: u32,
    caret: u32,
    highlight: u32,

    pub fn init(alloc: std.mem.Allocator, theme: Theme, geometry: Geometry) Renderer {
        const renderer = Renderer{
            .theme = theme,
            .alloc = alloc,
            .geom = geometry,
            .background = toColor(theme.background),
            .foreground = rgbaToAbgr(theme.foreground),
            .caret = rgbaToAbgr(theme.caret),
            .highlight = rgbaToAbgr(theme.highlight),
        };
        sgfx.setup(.{ .environment = sglue.environment() });
        sdtx.setup(.{
            .fonts = .{ sdtx.fontKc853(), .{}, .{}, .{}, .{}, .{}, .{}, .{} },
            .context = .{ .char_buf_size = 1 << 16 },
        });
        sdtx.font(0);
        sgl.setup(.{});
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.line_buffer.len > 0) self.alloc.free(self.line_buffer);
        sgl.shutdown();
        sdtx.shutdown();
        sgfx.shutdown();
    }

    pub fn beginFrame(self: *const Renderer) void {
        const pass = sgfx.Pass{
            .action = .{
                .colors = .{ .{ .load_action = .CLEAR, .clear_value = self.background }, .{}, .{}, .{} },
            },
            .swapchain = sglue.swapchain(),
        };
        sgfx.beginPass(pass);
    }

    pub fn endFrame(_: *const Renderer) void {
        sgfx.endPass();
        sgfx.commit();
    }

    pub fn draw(self: *Renderer, doc: *Document, layout: *const Layout, draw_caret: bool) !void {
        const rows = layout.lines.len;
        const cols = layout.width;
        if (rows == 0 or cols == 0) return;
        // set positions, create canvas, set text color
        const dims: PixelDims = .{ .w = @floatFromInt(sapp.width()), .h = @floatFromInt(sapp.height()) };
        sdtx.canvas(dims.w, dims.h);
        sdtx.origin(self.geom.pad_x_cells, self.geom.pad_y_cells);
        sdtx.home();
        sdtx.color1i(self.foreground);
        // allocate a per-frame line buffer, allows sentintel terminated strings
        try self.ensureLineBuffer(cols + 1);
        // materialize the doc lines directly into sokol's debugtext
        var row: usize = 0;
        var writer = SdtxWriter{ .buffer = self.line_buffer };
        // const rows_per_flush = @max(1, GLYPH_BUDGET / cols);
        while (row < layout.lines.len) : (row += 1) {
            sdtx.pos(0, @floatFromInt(row));
            const line = layout.lines[row];
            try doc.materializeRange(&writer, line.start, line.len);
            writer.flush();
        }
        sdtx.draw();
        // draw the caret
        if (!draw_caret) return;
        // sgl operates in clip space, so translate from the pixels we used in sdtx
        if (layout.caret) |caret| {
            const pos = self.geom.screenPosToPixelPos(caret);
            const off: PixelPos = .{ .x = self.geom.cell_w_px / 4, .y = self.geom.cell_h_px };
            const rect = Geometry.pixelPosToClipRect(pos, off, dims);
            drawQuad(self.caret, rect);
            sgl.draw();
        }
    }

    fn ensureLineBuffer(self: *Renderer, want: usize) !void {
        if (self.line_buffer.len >= want) return;
        if (self.line_buffer.len == 0) {
            self.line_buffer = try self.alloc.alloc(u8, want);
        } else {
            self.line_buffer = try self.alloc.realloc(self.line_buffer, want);
        }
    }
};

const SdtxWriter = struct {
    // this will be passed as the writer into the document and text buffer.
    // Loosely mirrors the Io.Writer interface, but I'm too smooth brained to figure that out
    buffer: []u8,
    end: usize = 0,

    pub fn writeAll(self: *SdtxWriter, bytes: []const u8) !void {
        // write into a private buffer, accumulate any number of writes as long as they fit in one line
        if (bytes.len == 0) return;
        debug.dassert(self.end + bytes.len < self.buffer.len, "attempt to write past the end of line buffer");
        @memcpy(self.buffer[self.end .. self.end + bytes.len], bytes);
        self.end += bytes.len;
    }

    fn flush(self: *SdtxWriter) void {
        // null terminate the string and write it using sokol's standard debug
        if (self.buffer.len != 0) self.buffer[self.end] = 0;
        const s: [:0]const u8 = self.buffer[0..self.end :0];
        sdtx.putr(s, @as(i32, @intCast(self.end)));
        self.end = 0;
    }
};

fn rgbaToAbgr(rgba: u32) u32 {
    // for some absurd reason, some sokol functions take RGBA and others take ABGR...
    const r: u32 = (rgba >> 24) & 0xFF;
    const g: u32 = (rgba >> 16) & 0xFF;
    const b: u32 = (rgba >> 8) & 0xFF;
    const a: u32 = rgba & 0xFF;
    return (a << 24) | (b << 16) | (g << 8) | r;
}

fn toColor(rgba: u32) sgfx.Color {
    // other functions still take a {r, g, b, a} struct...
    const a = @as(f32, @floatFromInt(rgba & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt((rgba >> 8) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((rgba >> 16) & 0xFF)) / 255.0;
    const r = @as(f32, @floatFromInt((rgba >> 24) & 0xFF)) / 255.0;
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn drawQuad(color: u32, rect: ClipRect) void {
    sgl.c1i(color);
    sgl.beginQuads();
    sgl.v2f(rect.x, rect.y);
    sgl.v2f(rect.x + rect.w, rect.y);
    sgl.v2f(rect.x + rect.w, rect.y + rect.h);
    sgl.v2f(rect.x, rect.y + rect.h);
    sgl.end();
}
