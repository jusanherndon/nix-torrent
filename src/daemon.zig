const std = @import("std");

const config = @import("config.zig");
const log = @import("log.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();

    const cfg = config.load(allocator) catch |err| switch (err) {
        error.UnknownFlag, error.MissingFlagValue => {
            try config.usage("torrentd", stderr);
            return err;
        },
        else => return err,
    };
    defer cfg.deinit(allocator);

    try ensureDirectory(cfg.staging_area);
    try ensureDirectory(cfg.final_destination);

    try log.configEvent(stderr, "daemon", cfg.staging_area, cfg.final_destination, cfg.socket_path);
    try log.event(stderr, .info, "daemon", "skeleton daemon initialized; torrent engine not implemented yet");

    // Milestone 1 only proves the long-running process can load configuration and
    // prepare its owned directories. The Unix domain socket and torrent lifecycle
    // state arrive in later milestones.
}

fn ensureDirectory(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}
