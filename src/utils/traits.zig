const std = @import("std");

/// Recursively peel off pointer/optional wrappers to the underlying type.
pub inline fn baseType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer  => |p| baseType(p.child),
        .optional => |o| baseType(o.child),
        else => T,
    };
}

/// Does the (unwrapped) type declare a method/field named `name`?
pub inline fn hasMethod(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(baseType(T), name);
}

/// Ensure any arbitrary value has a method signature matching a given name 
pub inline fn ensureHasMethod(value: anytype, comptime name: []const u8) void {
    comptime {
        if (!hasMethod(@TypeOf(value), name)) {
            @compileError("value does not provide method: " ++ name);
        }
    }
}
