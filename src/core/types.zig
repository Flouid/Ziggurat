

pub const TextPos = struct {
    // a logical position in the document
    line: usize,
    col: usize,
};

pub const Span = struct {
    // a generic [start, start + len) open range for indexing a line or subset of a line
    start: usize,
    len: usize,
};