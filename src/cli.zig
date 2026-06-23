const std = @import("std");

const config = @import("config.zig");
const log = @import("log.zig");
const protocol = @import("protocol.zig");

const Command = enum { add, list, show, pause, @"resume", remove, help };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        try usage(stdout);
        try stdout.flush();
        return;
    }

    const command = parseCommand(args[1]) orelse {
        try usage(stderr);
        return error.UnknownCommand;
    };

    const cfg = config.loadFromArgsWithEnv(allocator, &.{}, init.environ_map) catch |err| switch (err) {
        error.UnknownFlag, error.MissingFlagValue => {
            try config.usage("torrent", stderr);
            try stderr.flush();
            return err;
        },
        else => return err,
    };
    defer cfg.deinit(allocator);

    try log.configEvent(stderr, "cli", cfg.staging_area, cfg.final_destination, cfg.socket_path);

    switch (command) {
        .add => try requireArity(stderr, args, 3, "add <torrent-file>"),
        .show, .pause, .@"resume", .remove => try requireArity(stderr, args, 3, "<command> <info-hash>"),
        .list => try requireArity(stderr, args, 2, "list"),
        .help => unreachable,
    }

    const request = protocol.Request{ .command = switch (command) {
        .add => .add,
        .list => .list,
        .show => .show,
        .pause => .pause,
        .@"resume" => .@"resume",
        .remove => .remove,
        .help => unreachable,
    }, .argument = if (args.len == 3) args[2] else null };
    const json = try request.toJson(allocator);
    defer allocator.free(json);
    try stdout.print("would send to daemon socket {s}: {s}", .{ cfg.socket_path, json });
    try stdout.flush();
    try stderr.flush();
}

fn parseCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "add")) return .add;
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "show")) return .show;
    if (std.mem.eql(u8, value, "pause")) return .pause;
    if (std.mem.eql(u8, value, "resume")) return .@"resume";
    if (std.mem.eql(u8, value, "remove")) return .remove;
    if (std.mem.eql(u8, value, "help")) return .help;
    return null;
}

fn requireArity(stderr: anytype, args: []const []const u8, expected: usize, shape: []const u8) !void {
    if (args.len == expected) return;
    try stderr.print("expected: torrent {s}\n", .{shape});
    try stderr.flush();
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
