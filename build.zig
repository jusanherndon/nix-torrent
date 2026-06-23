const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const daemon = b.addExecutable(.{
        .name = "torrentd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(daemon);

    const cli = b.addExecutable(.{
        .name = "torrent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);

    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const log_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/log.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const bencode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bencode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const torrent_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/torrent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(log_tests).step);
    test_step.dependOn(&b.addRunArtifact(bencode_tests).step);
    test_step.dependOn(&b.addRunArtifact(torrent_tests).step);
}
