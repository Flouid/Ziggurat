const std = @import("std");

pub fn build(b: *std.Build) void {
    const cli_target = b.standardTargetOptions(.{});
    const cli_optimize = b.standardOptimizeOption(.{});

    const target_win = b.resolveTargetQuery(.{
        .os_tag = .windows,
        .cpu_arch = .x86_64,
        .abi = .gnu,
    });

    addApps(b, cli_target, cli_optimize);
    addApps(b, target_win, cli_optimize);

    const mods = addCoreModules(b, cli_target, cli_optimize);
    const app_tests = b.addTest(.{ .root_module = mods.app });

    const run_app_tests = b.addRunArtifact(app_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_app_tests.step);
}

const CoreModules = struct {
    debug: *std.Build.Module,
    utils: *std.Build.Module,
    ref_buf: *std.Build.Module,
    buffer: *std.Build.Module,
    types: *std.Build.Module,
    document: *std.Build.Module,
    viewport: *std.Build.Module,
    layout: *std.Build.Module,
    renderer: *std.Build.Module,
    file_io: *std.Build.Module,
    geometry: *std.Build.Module,
    controller: *std.Build.Module,
    app: *std.Build.Module,
};

fn addCoreModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) CoreModules {
    const debug_mod = b.addModule("debug", .{
        .root_source_file = b.path("src/utils/debug.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils_mod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/utils.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "debug", .module = debug_mod }},
    });

    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ref_buffer_mod = b.addModule("ref_buffer", .{
        .root_source_file = b.path("src/tools/ref_text_buffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "types", .module = types_mod },
        },
    });

    const buffer_mod = b.addModule("buffer", .{
        .root_source_file = b.path("src/core/text_buffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "types", .module = types_mod },
        },
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
        .imports = &.{.{ .name = "types", .module = types_mod }},
    });

    const geom_mod = b.addModule("geometry", .{
        .root_source_file = b.path("src/core/geometry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "document", .module = doc_mod },
            .{ .name = "viewport", .module = viewport_mod },
            .{ .name = "types", .module = types_mod },
        },
    });

    const layout_mod = b.addModule("layout", .{
        .root_source_file = b.path("src/core/layout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "document", .module = doc_mod },
            .{ .name = "viewport", .module = viewport_mod },
            .{ .name = "types", .module = types_mod },
            .{ .name = "geometry", .module = geom_mod },
        },
    });

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const renderer_mod = b.addModule("renderer", .{
        .root_source_file = b.path("src/core/renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = debug_mod },
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "document", .module = doc_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "geometry", .module = geom_mod },
            .{ .name = "types", .module = types_mod },
        },
    });

    const dep_win32 = b.dependency("win32", .{});

    const file_io_mod = b.addModule("file_io", .{
        .root_source_file = b.path("src/core/file_io.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "win32", .module = dep_win32.module("win32") },
        },
    });

    const controller_mod = b.addModule("controller", .{
        .root_source_file = b.path("src/core/controller.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "document", .module = doc_mod },
            .{ .name = "viewport", .module = viewport_mod },
            .{ .name = "geometry", .module = geom_mod },
        },
    });

    const app_mod = b.addModule("app", .{
        .root_source_file = b.path("src/app/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "document", .module = doc_mod },
            .{ .name = "viewport", .module = viewport_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "file_io", .module = file_io_mod },
            .{ .name = "controller", .module = controller_mod },
            .{ .name = "geometry", .module = geom_mod },
            .{ .name = "types", .module = types_mod },
        },
    });

    return .{
        .debug = debug_mod,
        .utils = utils_mod,
        .ref_buf = ref_buffer_mod,
        .buffer = buffer_mod,
        .types = types_mod,
        .document = doc_mod,
        .viewport = viewport_mod,
        .layout = layout_mod,
        .renderer = renderer_mod,
        .file_io = file_io_mod,
        .geometry = geom_mod,
        .controller = controller_mod,
        .app = app_mod,
    };
}

fn addApps(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const mods = addCoreModules(b, target, optimize);

    const test_engine = b.addExecutable(.{
        .name = "test-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/test_engine.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "debug", .module = mods.debug },
                .{ .name = "utils", .module = mods.utils },
                .{ .name = "ref_buffer", .module = mods.ref_buf },
                .{ .name = "buffer", .module = mods.buffer },
                .{ .name = "types", .module = mods.types },
            },
        }),
    });
    b.installArtifact(test_engine);

    const main = b.addExecutable(.{
        .name = "Ziggurat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app", .module = mods.app },
                .{ .name = "utils", .module = mods.utils },
            },
        }),
    });
    b.installArtifact(main);
}
