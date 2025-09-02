pub const TextPos = struct {
    // a logical position in the document in characters
    row: usize,
    col: usize,
};

pub const ScreenPos = struct {
    // a logical position on the screen in cells
    row: usize,
    col: usize,
};

pub const ScreenDims = struct {
    // the dimensions of a screen in cells
    w: usize,
    h: usize,
};

pub const Span = struct {
    // a generic [start, start + len) open range for indexing a sequence of bytes in the document
    start: usize,
    len: usize,

    pub fn end(self: Span) usize {
        return self.start + self.len;
    }
};

pub const PixelPos = struct {
    // a position on the screen in pixels
    x: f32,
    y: f32,

    pub const origin: PixelPos = .{ .x = 0, .y = 0 };
};

pub const PixelDims = struct {
    // the dimensions of a screen in pixels
    w: f32,
    h: f32,
};

pub const ClipPos = struct {
    // a position on the screen in clip space
    x: f32,
    y: f32,
};

pub const ClipRect = struct {
    // a rectangle in clip space
    x: f32,
    y: f32,
    h: f32,
    w: f32,
};