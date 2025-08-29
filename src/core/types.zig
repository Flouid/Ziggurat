pub const TextPos = struct {
    // a logical position in the document
    row: usize,
    col: usize,
};

pub const ScreenPos = struct {
    // a logical position ON THE SCREEN
    row: usize,
    col: usize,
};

pub const Span = struct {
    // a generic [start, start + len) open range for indexing a sequence of bytes in the document
    start: usize,
    len: usize,
};

pub const PixelPos = struct {
    // a position on the screen in pixels
    x: f32,
    y: f32,
};

pub const ClipPos = struct {
    // a position on the screen in clip space
    x: f32,
    y: f32,
};
