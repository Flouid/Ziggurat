const std = @import("std");
const Document = @import("document").Document;
const Layout = @import("layout").Layout;
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const sdtx = sokol.debugtext;
const sgl = sokol.gl;
const sglue = sokol.glue;

pub const Theme = struct { 
    // colors stored as packed 32-bit integers in RGBA order
    // for example, 0xRRGGBBAA
    background: u32,
    foreground: u32,
    caret: u32,
    pad_px_x: f32,
    pad_px_y: f32,
};

const SdtxWriter = struct {
    pub const Error = error{};
    pub const Writer = std.io.Writer(*SdtxWriter, Error, write);

    pub fn writer(self: *SdtxWriter) Writer {
        return .{ .context = self };
    }

    fn write(_: *SdtxWriter, bytes: []const u8) !usize {
        if (bytes.len != 0) sdtx.putr(bytes.ptr, @intCast(bytes.len));
        return bytes.len;
    }
};

pub const Renderer = struct {
    theme: Theme,

    pub fn init(theme: Theme) Renderer {
        const renderer = .{ .theme = theme };
        sgfx.setup(.{ .environment = sglue.environment()} );
        sdtx.setup(.{ .fonts = .{ sdtx.font_kc853() } });
        sgl.setup(.{});
        return renderer;
    }

    pub fn deinit() void {
        sgl.shutdown();
        sdtx.shutdown();
        sgfx.shutdown();
    }

    pub fn beginFrame(self: *const Renderer) void {
        var pass = sgfx.Pass{
            .action = .{
                .colors = .{ .{ .load_action = .CLEAR, .clear_value = toColor(self.theme.background) } },
            },
            .swapchain = sglue.swapchain(),
        };
        sgfx.beginPass(&pass);
    }

    pub fn endFrame() void {
        sgfx.endPass();
        sgfx.commit();
    }

    pub fn draw(self: *Renderer, doc: *const Document, layout: *const Layout) !void {
        const rows = layout.lines.len;
        const cols = layout.width;
        if (rows == 0 or cols == 0) return;
        // set positions, create canvas, set text color
        sdtx.canvas(@floatFromInt(sapp.width()), @floatFromInt(sapp.height()));
        sdtx.origin(self.theme.pad_px_x, self.theme.pad_px_y);
        sdtx.home();
        sdtx.color1i(rgbaToAbgr(self.theme.foreground)); // nasty RGBA vs ABGR footgun
        // materialize the doc lines directly into sokol's debugtext
        var row: usize = 0;
        var out = SdtxWriter{};
        while (row < layout.lines.len) : (row += 1) {
            const slice = layout.lines[row];
            sdtx.pos(0, @intCast(row));
            if (slice.len != 0) {
                try doc.materializeRange(out.writer(), slice.start, slice.len);
            }
        }
        // draw the caret
        if (layout.caret) |caret| {
            const x = self.theme.pad_px_x + @as(f32, @floatFromInt(caret.col)) * 8;
            const y = self.theme.pad_px_y + @as(f32, @floatFromInt(caret.row)) * 8;
            sgl.beginQuads();
            sgl.c1i(self.theme.caret);
            const h: f32 = 8.0;
            const w: f32 = 2.0;
            sgl.v2f(x,   y);
            sgl.v2f(x+w, y);
            sgl.v2f(x+w, y+h);
            sgl.v2f(x,   y+h);
            sgl.end();
            sgl.draw();
        }
        sdtx.draw();
    }
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

test "compiles?" {
    try std.testing.expect(true);
}