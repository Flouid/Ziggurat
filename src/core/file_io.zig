const std = @import("std");
const builtin = @import("builtin");
const win32 = if (builtin.os.tag == .windows) @import("win32") else struct {};

const MAX_FILE_SIZE = @as(usize, 1) << (@bitSizeOf(usize) - 1);
const TEMP_PATH = ".ziggurat_temp";

pub fn read(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return try alloc.dupe(u8, ""),
        else => return e,
    };
    defer file.close();
    return try file.readToEndAlloc(alloc, MAX_FILE_SIZE);
}

pub fn tempPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return try std.fs.path.join(alloc, &.{ dir, TEMP_PATH });
}

pub fn write(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

// -------------------- MEMORY MAPPING --------------------

const Platform = if (builtin.os.tag == .windows) struct {
    mapping: ?win32.foundation.HANDLE,
    view: ?*const anyopaque,
    len: usize,
} else struct {
    raw: []align(std.heap.page_size_min) u8,
};

pub const MappedFile = struct {
    bytes: []const u8,
    platform: Platform,

    pub fn initFromPath(path: ?[]const u8) !MappedFile {
        if (path == null) return MappedFile.empty();
        const p = path.?;
        var file = std.fs.cwd().openFile(p, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => return MappedFile.empty(),
            else => return e,
        };
        defer file.close();
        const size = try file.getEndPos();
        if (size == 0) return MappedFile.empty();
        if (size > MAX_FILE_SIZE) return error.FileTooBig;
        const len: usize = @intCast(size);
        if (builtin.os.tag == .windows) {
            return try mapWindows(file, len);
        } else {
            return try mapPosix(file, len);
        }
    }

    pub fn deinit(self: *MappedFile) void {
        if (builtin.os.tag == .windows) {
            if (self.platform.view) |p| {
                _ = win32.system.memory.UnmapViewOfFile(p);
            }
            if (self.platform.mapping) |h| {
                _ = win32.foundation.CloseHandle(h);
            }
            self.* = MappedFile.empty();
        } else {
            if (self.platform.raw.len != 0) {
                std.posix.munmap(self.platform.raw);
            }
            self.* = MappedFile.empty();
        }
    }

    // private implementation

    fn empty() MappedFile {
        return if (builtin.os.tag == .windows) .{ .bytes = &[_]u8{}, .platform = .{ .mapping = null, .view = null, .len = 0 } } else .{ .bytes = &[_]u8{}, .platform = .{ .raw = &[_]u8{} } };
    }

    fn mapPosix(file: std.fs.File, len: usize) !MappedFile {
        const posix = std.posix;
        const raw = try posix.mmap(
            null,
            len,
            posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        return .{
            .bytes = raw[0..len],
            .platform = .{ .raw = raw },
        };
    }

    fn mapWindows(file: std.fs.File, len: usize) !MappedFile {
        const hFile_w32: win32.foundation.HANDLE = @ptrCast(file.handle);
        const hMap = win32.system.memory.CreateFileMappingW(
            hFile_w32,
            null,
            win32.system.memory.PAGE_READONLY,
            0,
            0,
            null,
        ) orelse return error.Unexpected;
        const addr = win32.system.memory.MapViewOfFile(
            hMap,
            win32.system.memory.FILE_MAP_READ,
            0,
            0,
            0,
        ) orelse {
            _ = win32.foundation.CloseHandle(hMap);
            return error.Unexpected;
        };
        const base_u8: [*]const u8 = @ptrCast(addr);
        return .{
            .bytes = base_u8[0..len],
            .platform = .{ .mapping = hMap, .view = addr, .len = len },
        };
    }
};
