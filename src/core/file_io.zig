const std = @import("std");

const MAX_FILE_SIZE = 1 << 31;  // 2 GiB

pub fn read(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(alloc, path, MAX_FILE_SIZE);
}

pub fn write(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}