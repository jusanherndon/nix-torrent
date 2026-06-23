const std = @import("std");

const config = @import("config.zig");
const log = @import("log.zig");

const Command = enum { add, list, show, pause, resume, remove, help };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        try usage(stdout);
        return;
    }

    const command = parseCommand(args[1]) orelse {
        try usage(stderr);
        return error.UnknownCommand;
    };

    const cfg = config.loadFromArgs(allocator, &.{}) catch |err| switch (err) {
        error.UnknownFlag, error.MissingFlagValue => {
            try config.usage("torrent", stderr);
            return err;
        },
        else => return err,
    };
    defer cfg.deinit(allocator);

    try log.configEvent(stderr, "cli", cfg.staging_area, cfg.final_destination, cfg.socket_path);

    switch (command) {
        .add => try requireArity(args, 3, "add <torrent-file>"),
        .show, .pause, .resume, .remove => try requireArity(args, 3, "<command> <info-hash>"),
        .list => try requireArity(args, 2, "list"),
        .help => unreachable,
    }

    try stdout.print(
        "torrent CLI skeleton: would send '{s}' to daemon socket {s}\n",
        .{ args[1], cfg.socket_path },
    );
}

fn parseCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "add")) return .add;
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "show")) return .show;
    if (std.mem.eql(u8, value, "pause")) return .pause;
    if (std.mem.eql(u8, value, "resume")) return .resume;
    if (std.mem.eql(u8, value, "remove")) return .remove;
    if (std.mem.eql(u8, value, "help")) return .help;
    return null;
}

fn requireArity(args: []const []const u8, expected: usize, shape: []const u8) !void {
    if (args.len == expected) return;
    const stderr = std.io.getStdErr().writer();
    try stderr.print("expected: torrent {s}\n", .{shape});
    return error.InvalidArguments;
}

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: torrent <command>
        \\
        \\Commands:
        \\  add <torrent-file>
        \\  list
        \\  show <info-hash>
        \\  pause <info-hash>
        \\  resume <info-hash>
        \\  remove <info-hash>
        \\
        \\The CLI is a control surface. It never mutates torrent state directly.
        \\
    );
}
