const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const debug_mod = b.addModule("debug", .{
        .root_source_file = b.path("src/utils/debug.zig"),
        .target = target
    });
    const utils_mod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/utils.zig"),
        .target = target
    });
    utils_mod.addImport("debug", debug_mod);

    const ref_buffer_mod = b.addModule("ref_buffer", .{
        .root_source_file = b.path("src/tools/ref_text_buffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
            .{ .name = "utils", .module = utils_mod },
        },
    });

    const buffer_mod = b.addModule("buffer", .{
        .root_source_file = b.path("src/core/text_buffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
            .{ .name = "utils", .module = utils_mod },
        },
    });

    const fixture_gen = b.addExecutable(.{
        .name = "test-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/test_engine.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "debug", .module = debug_mod },
                .{ .name = "utils", .module = utils_mod },
                .{ .name = "ref_buffer", .module = ref_buffer_mod },
                .{ .name = "buffer", .module = buffer_mod },
            },
        }),
    });
    b.installArtifact(fixture_gen);

    const buffer_tests = b.addTest(.{
        .root_module = buffer_mod,
    });

    const run_buffer_tests = b.addRunArtifact(buffer_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_buffer_tests.step);
}
