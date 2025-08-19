const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const debug_mod = b.addModule("debug", .{
        .root_source_file = b.path("src/utils/debug.zig"),
        .target = target,
        .optimize = optimize,
    });
    const utils_mod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/utils.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
        },
    });

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

    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const doc_mod = b.addModule("document", .{
        .root_source_file = b.path("src/core/document.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "types", .module = types_mod },
        },
    });

    const viewport_mod = b.addModule("viewport", .{
        .root_source_file = b.path("src/core/viewport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
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
    const doc_tests = b.addTest(.{
        .root_module = doc_mod,
    });
    const viewport_tests = b.addTest(.{
        .root_module = viewport_mod,
    });

    const run_buffer_tests = b.addRunArtifact(buffer_tests);
    const run_doc_tests = b.addRunArtifact(doc_tests);
    const run_viewport_tests = b.addRunArtifact(viewport_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_buffer_tests.step);
    test_step.dependOn(&run_doc_tests.step);
    test_step.dependOn(&run_viewport_tests.step);
}
