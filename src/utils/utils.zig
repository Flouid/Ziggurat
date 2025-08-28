const std = @import("std");
const debug = @import("debug");

// A semirandom collection of functions which really should be in the standard library but for some reason aren't
// the majority of this IS in the 0.14 STL, but is now missing for one reason or another.

// Also contains some utility helpers which could have use in multiple modules

// -------------------- ARRAY LISTS --------------------

pub fn orderedRemoveRange(comptime T: type, list: *std.ArrayList(T), start: usize, count: usize) void {
    // for some strange reason the arraylist stl does not have this function.
    // Repeatedly calling .removedOrdered would be slow, this does the same more performantly.
    debug.dassert(start <= list.items.len, "start is out of bounds");
    debug.dassert(start + count <= list.items.len, "range is out of bounds");
    debug.dassert(count > 0, "cannot remove 0 items");

    const tail_start = start + count;
    std.mem.copyForwards(T, list.items[start .. list.items.len - count], list.items[tail_start..]);
    list.shrinkRetainingCapacity(list.items.len - count);
}

// -------------------- RUNTIME HEX CONVERSION --------------------

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => error.BadHexDigit,
    };
}

pub fn hexToBytesAlloc(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.BadHexLength;
    const n = hex.len / 2;
    var out = try alloc.alloc(u8, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hi = try hexNibble(hex[2 * i]);
        const lo = try hexNibble(hex[2 * i + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

pub fn bytesToHexAlloc(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // for some reason zig 0.15 doesn't expose a method like this but earlier versions did...
    // Converts strings known only at runtime to hex using an allocator.
    var out = try alloc.alloc(u8, bytes.len * 2);
    const tbl = "0123456789ABCDEF";

    var i: usize = 0;
    for (bytes) |b| {
        out[i] = tbl[(b >> 4) & 0x0F];
        out[i + 1] = tbl[b & 0x0F];
        i += 2;
    }
    return out;
}

// -------------------- RANDOM NUMBER IN RANGE --------------------

pub const RNG = struct {
    // wrapper for a specific pseudo-random number generator that provides results in a range.
    // Also generic for any unsigned integer type (as long as it's not bigger than u64).
    rng: std.Random.SplitMix64,

    pub fn init(seed: u64) RNG {
        return RNG{ .rng = std.Random.SplitMix64.init(seed) };
    }

    pub fn randInt(self: *RNG, comptime T: type, min: T, max_exclusive: T) T {
        // uniform in [min, max_exclusive)
        debug.dassert(max_exclusive >= min, "min cannot be larger than max_exlusive");
        const span: u64 = @intCast(max_exclusive - min);
        const r: u64 = self.rng.next() % span;
        return min + @as(T, @intCast(r));
    }
};

// -------------------- A SANE PRINT FUNCTION --------------------

pub fn printf(comptime fmt: []const u8, args: anytype) !void {
    // don't forget to flush
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

// -------------------- GENERIC HELPERS --------------------

pub fn countNewlinesInSlice(slice: []const u8) usize {
    var count: usize = 0;
    for (slice) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub fn indexOfKthNewlineInRange(slice: []const u8, start: usize, end: usize, k: usize) usize {
    // count up to k newlines between a start and end index in a given slice
    // NOTE: assumes you can guarantee that there ARE k newlines in the range!!!
    var seen: usize = 0;
    var i: usize = start;
    while (i < end) : (i += 1) {
        if (slice[i] == '\n') {
            seen += 1;
            if (seen == k) return i;
        }
    }
    @panic("invariant violated: not enough newlines in range");
}
