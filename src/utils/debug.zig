const std = @import("std");
const builtin = @import("builtin");

// assertions in safe modes only, "fail fast" without a runtime performance penalty
// also, send a (hopefully) helpful error message
pub inline fn dassert(cond: bool, msg: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (!cond) @panic(msg);
    }
}
