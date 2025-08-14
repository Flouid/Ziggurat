const std = @import("std");
const debug = @import("debug");

pub inline fn orderedRemoveRange(comptime T: type, list: *std.ArrayList(T), start: usize, count: usize) void {
    // for some strange reason the arraylist stl does not have this function
    // repeatedly calling .removedOrdered would be slow, this does the same performantly
    debug.dassert(start <= list.items.len, "start is out of bounds");
    debug.dassert(start + count <= list.items.len, "range is out of bounds");
    debug.dassert(count > 0, "cannot remove 0 items");

    const tail_start = start + count;
    std.mem.copyForwards(T, list.items[start..list.items.len - count], list.items[tail_start..]);
    list.shrinkRetainingCapacity(list.items.len - count);
}