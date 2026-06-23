const std = @import("std");

const config = @import("config.zig");
const log = @import("log.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const cfg = config.load(allocator, init.minimal.args, init.environ_map) catch |err| switch (err) {
        error.UnknownFlag, error.MissingFlagValue => {
            try config.usage("torrentd", stderr);
            try stderr.flush();
            return err;
        },
        else => return err,
    };
    defer cfg.deinit(allocator);

    try ensureDirectory(init.io, cfg.staging_area);
    try ensureDirectory(init.io, cfg.final_destination);

    try log.configEvent(stderr, "daemon", cfg.staging_area, cfg.final_destination, cfg.socket_path);
    try log.event(stderr, .info, "daemon", "skeleton daemon initialized; torrent engine not implemented yet");
    try stderr.flush();

    // Milestone 1 only proves the long-running process can load configuration and
    // prepare its owned directories. The Unix domain socket and torrent lifecycle
    // state arrive in later milestones.
}

fn ensureDirectory(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}
