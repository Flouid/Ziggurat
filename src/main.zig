const std = @import("std");
const utils = @import("utils");
const app = @import("app");


fn printUsage(cmd: [:0]u8) !void {
    try utils.printf("There are two accepted usage cases:\n", .{});
    try utils.printf("\tOpen new empty file:\t{s}\n", .{cmd});
    try utils.printf("\tOpen existing file:\t{s} <path_in>\n", .{cmd});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len > 2) {
        try printUsage(args[0]);
        return;
    }

    if (args.len == 1) {
        try app.run(null);
    } else {
        try app.run(args[1]);
    }
}