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

    const storage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tracker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const peer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/peer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const handoff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/handoff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/state.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const dht_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dht.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const encryption_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/encryption.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(log_tests).step);
    test_step.dependOn(&b.addRunArtifact(bencode_tests).step);
    test_step.dependOn(&b.addRunArtifact(torrent_tests).step);
    test_step.dependOn(&b.addRunArtifact(storage_tests).step);
    test_step.dependOn(&b.addRunArtifact(tracker_tests).step);
    test_step.dependOn(&b.addRunArtifact(peer_tests).step);
    test_step.dependOn(&b.addRunArtifact(engine_tests).step);
    test_step.dependOn(&b.addRunArtifact(handoff_tests).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    test_step.dependOn(&b.addRunArtifact(state_tests).step);
    test_step.dependOn(&b.addRunArtifact(dht_tests).step);
    test_step.dependOn(&b.addRunArtifact(encryption_tests).step);
    const magnet_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/magnet.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_step.dependOn(&b.addRunArtifact(magnet_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}
