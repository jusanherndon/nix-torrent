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
            .link_libc = true,
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

    const address_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/address.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const dns_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dns.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const tcp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tcp.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tracker.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const peer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/peer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const peer_pool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/peer_pool.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const inbound_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inbound.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const port_mapping_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/port_mapping.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const pex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pex.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const lsd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsd.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const tracker_tier_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tracker_tier.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const control_plane_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/control_plane.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const lsd_service_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsd_service.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const piece_scheduler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/piece_scheduler.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
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
            .link_libc = true,
        }),
    });

    const encryption_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/encryption.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const mse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mse.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    const staging_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/staging.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_step.dependOn(&b.addRunArtifact(staging_tests).step);
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(log_tests).step);
    test_step.dependOn(&b.addRunArtifact(bencode_tests).step);
    test_step.dependOn(&b.addRunArtifact(torrent_tests).step);
    test_step.dependOn(&b.addRunArtifact(storage_tests).step);
    test_step.dependOn(&b.addRunArtifact(address_tests).step);
    test_step.dependOn(&b.addRunArtifact(dns_tests).step);
    test_step.dependOn(&b.addRunArtifact(tcp_tests).step);
    test_step.dependOn(&b.addRunArtifact(tracker_tests).step);
    test_step.dependOn(&b.addRunArtifact(peer_tests).step);
    test_step.dependOn(&b.addRunArtifact(peer_pool_tests).step);
    test_step.dependOn(&b.addRunArtifact(engine_tests).step);
    test_step.dependOn(&b.addRunArtifact(inbound_tests).step);
    test_step.dependOn(&b.addRunArtifact(port_mapping_tests).step);
    test_step.dependOn(&b.addRunArtifact(pex_tests).step);
    test_step.dependOn(&b.addRunArtifact(lsd_tests).step);
    test_step.dependOn(&b.addRunArtifact(tracker_tier_tests).step);
    test_step.dependOn(&b.addRunArtifact(control_plane_tests).step);
    test_step.dependOn(&b.addRunArtifact(lsd_service_tests).step);
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
    test_step.dependOn(&b.addRunArtifact(piece_scheduler_tests).step);
    test_step.dependOn(&b.addRunArtifact(handoff_tests).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    test_step.dependOn(&b.addRunArtifact(state_tests).step);
    test_step.dependOn(&b.addRunArtifact(dht_tests).step);
    test_step.dependOn(&b.addRunArtifact(encryption_tests).step);
    test_step.dependOn(&b.addRunArtifact(mse_tests).step);
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
