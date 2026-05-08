const std = @import("std");

/// Build zgz against zlib-ng's zlib-compatible static artifact.
///
/// The referenced `zig-zlib-ng` package exposes an artifact named `zng`; this
/// build links that artifact into the library tests and the benchmark binary.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlib_ng = b.dependency("zlib_ng", .{
        .target = target,
        .optimize = optimize,
    });
    const zng = zlib_ng.artifact("zng");

    const zgz_mod = b.addModule("zgz", .{
        .root_source_file = b.path("src/zgz.zig"),
        .target = target,
        .optimize = optimize,
    });
    zgz_mod.linkLibrary(zng);

    const lib = b.addLibrary(.{
        .name = "zgz",
        .linkage = .static,
        .root_module = zgz_mod,
    });
    lib.root_module.linkLibrary(zng);
    b.installArtifact(lib);

    const bench_exe = b.addExecutable(.{
        .name = "zgz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/zgzcat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zgz", .module = zgz_mod }},
        }),
    });
    bench_exe.root_module.linkLibrary(zng);
    b.installArtifact(bench_exe);

    const igz_cli = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "zgz-cat", .path = "src/cli/zgz-cat.zig" },
        .{ .name = "zgz-repack", .path = "src/cli/zgz-repack.zig" },
        .{ .name = "zgz-inspect", .path = "src/cli/zgz-inspect.zig" },
    };

    for (igz_cli) |cli| {
        const exe = b.addExecutable(.{
            .name = cli.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(cli.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zgz", .module = zgz_mod }},
            }),
        });
        exe.root_module.linkLibrary(zng);
        b.installArtifact(exe);
    }

    const zgzfill_exe = b.addExecutable(.{
        .name = "zgzfill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/zgzfill.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "zgz",
                    .module = zgz_mod,
                },
            },
        }),
    });

    zgzfill_exe.root_module.linkLibrary(zng);
    b.installArtifact(zgzfill_exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zgz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkLibrary(zng);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zgz unit tests");
    test_step.dependOn(&run_tests.step);

    const run_cmd = b.addRunArtifact(bench_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zgz; pass args after --");
    run_step.dependOn(&run_cmd.step);
}
