const std = @import("std");

const MAX_FILE_SIZE = @as(usize, 1) << (@bitSizeOf(usize) - 1);

pub fn read(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |e| switch(e) {
        error.FileNotFound => return try alloc.dupe(u8, ""),
        else => return e,
    };
    defer file.close();
    return try file.readToEndAlloc(alloc, MAX_FILE_SIZE);
}

pub fn write(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}