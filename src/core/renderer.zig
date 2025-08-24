const std = @import("std");
const debug = @import("debug");
const Document = @import("document").Document;
const Layout = @import("layout").Layout;
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const sdtx = sokol.debugtext;
const sgl = sokol.gl;
const sglue = sokol.glue;


pub const Renderer = struct {
    theme: Theme,

    pub fn init(theme: Theme) Renderer {
        const renderer = Renderer{ .theme = theme };
        sgfx.setup(.{ .environment = sglue.environment() });
        sdtx.setup(.{ .fonts = .{ sdtx.fontKc853(), .{}, .{}, .{}, .{}, .{}, .{}, .{} } });
        sdtx.font(0);
        sgl.setup(.{});
        return renderer;
    }

    pub fn deinit(_: *Renderer) void {
        sgl.shutdown();
        sdtx.shutdown();
        sgfx.shutdown();
    }

    pub fn beginFrame(self: *const Renderer) void {
        const pass = sgfx.Pass{
            .action = .{
                .colors = .{ .{ .load_action = .CLEAR, .clear_value = toColor(self.theme.background) }, .{}, .{}, .{} },
            },
            .swapchain = sglue.swapchain(),
        };
        sgfx.beginPass(pass);
    }

    pub fn endFrame(_: *const Renderer) void {
        sgfx.endPass();
        sgfx.commit();
    }

    pub fn draw(self: *Renderer, doc: *Document, layout: *const Layout) !void {
        const rows = layout.lines.len;
        const cols = layout.width;
        if (rows == 0 or cols == 0) return;
        // set positions, create canvas, set text color
        const appDims = Dimensions{ .x = @floatFromInt(sapp.width()), .y = @floatFromInt(sapp.height()) };
        sdtx.canvas(appDims.x, appDims.y);
        sdtx.origin(self.theme.pad_x, self.theme.pad_y);
        sdtx.home();
        sdtx.color1i(rgbaToAbgr(self.theme.foreground)); // nasty RGBA vs ABGR footgun
        // allocate a per-frame line buffer, allows sentintel terminated strings
        var a = std.heap.page_allocator;
        const line_buffer = try a.alloc(u8, cols + 1);
        defer a.free(line_buffer);
        // materialize the doc lines directly into sokol's debugtext
        var row: usize = 0;
        var writer = SdtxWriter{ .buffer = line_buffer };
        while (row < layout.lines.len) : (row += 1) {
            sdtx.pos(0, @floatFromInt(row));
            const line = layout.lines[row];
            try doc.materializeRange(&writer, line.start, line.len);
            writer.flush();
        }
        sdtx.draw();
        // draw the caret
        // sgl operates in clip space, so translate from the pixels we used in sdtx
        if (layout.caret) |caret| {
            const cell_size: f32 = 8.0;
            const x = (self.theme.pad_x + @as(f32, @floatFromInt(caret.col))) * cell_size;
            const y = (self.theme.pad_y + @as(f32, @floatFromInt(caret.row))) * cell_size;
            const h = cell_size;
            const w = cell_size / 4;
            // calculate vertices in clip space
            const p0 = px_to_ndc(x,   y,   appDims);
            const p1 = px_to_ndc(x+w, y,   appDims);
            const p2 = px_to_ndc(x+w, y+h, appDims);
            const p3 = px_to_ndc(x,   y+h, appDims);
            // draw filled rectangle for the caret
            sgl.c1i(self.theme.caret);
            sgl.beginQuads();
            sgl.v2f(p0.x, p0.y);
            sgl.v2f(p1.x, p1.y);
            sgl.v2f(p2.x, p2.y);
            sgl.v2f(p3.x, p3.y);
            sgl.end();
            sgl.draw();
        }
    }
};

pub const Theme = struct { 
    // colors stored as packed 32-bit integers in RGBA order
    // for example, 0xRRGGBBAA
    background: u32,
    foreground: u32,
    caret: u32,
    // number of TEXT CELLS to pad x and y around the borders
    pad_x: f32,
    pad_y: f32,
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
        @memcpy(self.buffer[self.end..self.end + bytes.len], bytes);
        self.end += bytes.len;
    }

    pub fn flush(self: *SdtxWriter) void {
        // null terminate the string and write it using sokol's standard debug
        if (self.buffer.len != 0) self.buffer[self.end] = 0;
        const s: [:0]const u8 = self.buffer[0..self.end :0];
        sdtx.putr(s, @as(i32, @intCast(self.end)));
        self.end = 0;
    }
};

const Dimensions = struct {
    x: f32,
    y: f32,
};

fn rgbaToAbgr(rgba: u32) u32 {
    // for some absurd reason, some sokol functions take RGBA and others take ABGR...
    const r: u32 = (rgba >> 24) & 0xFF;
    const g: u32 = (rgba >> 16) & 0xFF;
    const b: u32 = (rgba >> 8)  & 0xFF;
    const a: u32 =  rgba        & 0xFF;
    return (a << 24) | (b << 16) | (g << 8) | r;
}

fn toColor(rgba: u32) sgfx.Color {
    // other functions still take a {r, g, b, a} struct...
    const a = @as(f32, @floatFromInt( rgba        & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt((rgba >> 8)  & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((rgba >> 16) & 0xFF)) / 255.0;
    const r = @as(f32, @floatFromInt((rgba >> 24) & 0xFF)) / 255.0;
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn px_to_ndc(x_px: f32, y_px: f32, appDims: Dimensions) Dimensions {
    // translate pixel space to clip space
    return .{
        .x = (x_px / appDims.x) * 2.0 - 1.0,
        .y = 1.0 - (y_px / appDims.y) * 2.0,
    };
}

