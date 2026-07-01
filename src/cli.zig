const std = @import("std");

const config = @import("config.zig");
const log = @import("log.zig");
const protocol = @import("protocol.zig");

const Command = enum { add, list, show, pause, @"resume", remove, status, help };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    if (args.len < 2 or hasHelp(args)) {
        try usage(stdout);
        try stdout.flush();
        return;
    }

    const split = findCommand(args) orelse {
        try usage(stderr);
        try stderr.flush();
        return error.UnknownCommand;
    };
    const config_args = args[1..split];
    const command_args = args[split..];

    const command = parseCommand(command_args[0]) orelse {
        try usage(stderr);
        try stderr.flush();
        return error.UnknownCommand;
    };

    const cfg = config.loadFromArgsWithEnvAndIo(allocator, init.io, config_args, init.environ_map) catch |err| switch (err) {
        error.UnknownFlag, error.MissingFlagValue => {
            try config.usage("torrent", stderr);
            try stderr.flush();
            return err;
        },
        error.MissingExplicitConfig => {
            try stderr.writeAll("configuration error: explicit --config file is missing or unreadable\n");
            try stderr.flush();
            return err;
        },
        error.InvalidConfig => {
            try stderr.writeAll("configuration error: invalid configuration values\n");
            try stderr.flush();
            return err;
        },
        else => return err,
    };
    defer cfg.deinit(allocator);

    try log.configEvent(stderr, "cli", cfg.staging_area, cfg.final_destination, cfg.socket_path);

    switch (command) {
        .add => try requireArity(stderr, command_args, 2, "add <torrent-file>"),
        .show, .pause, .@"resume", .remove => try requireArity(stderr, command_args, 2, "<command> <info-hash>"),
        .list, .status => try requireArity(stderr, command_args, 1, @tagName(command)),
        .help => unreachable,
    }

    const request = protocol.Request{ .command = switch (command) {
        .add => .add,
        .list => .list,
        .show => .show,
        .pause => .pause,
        .@"resume" => .@"resume",
        .remove => .remove,
        .status => .status,
        .help => unreachable,
    }, .argument = if (command_args.len == 2) command_args[1] else null };

    try verifyDaemonProtocol(init.io, allocator, cfg.socket_path);

    const response = try sendRequest(init.io, allocator, cfg.socket_path, request);
    defer allocator.free(response);

    try stdout.writeAll(response);
    if (response.len == 0 or response[response.len - 1] != '\n') try stdout.writeByte('\n');
    try stdout.flush();
    try stderr.flush();
}

fn verifyDaemonProtocol(io: std.Io, allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const response = try sendRequest(io, allocator, socket_path, .{ .command = .status });
    defer allocator.free(response);
    try verifyControlProtocol(allocator, response);
}

fn verifyControlProtocol(allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = try protocol.parseResponse(allocator, response);
    defer parsed.deinit();
    if (!parsed.value.object.get("ok").?.bool) return error.ControlProtocolMismatch;
    const result = parsed.value.object.get("result") orelse return error.ControlProtocolMismatch;
    const version = result.object.get("control_protocol_version") orelse return error.ControlProtocolMismatch;
    if (version.integer != protocol.CONTROL_PROTOCOL_VERSION) return error.ControlProtocolMismatch;
}

fn sendRequest(io: std.Io, allocator: std.mem.Allocator, socket_path: []const u8, request: protocol.Request) ![]u8 {
    const ua = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try ua.connect(io);
    defer stream.close(io);

    const request_json = try request.toJson(allocator);
    defer allocator.free(request_json);

    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request_json);
    try writer.interface.flush();

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    return allocator.dupe(u8, line);
}

fn hasHelp(args: []const []const u8) bool {
    return std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help");
}

fn findCommand(args: []const []const u8) ?usize {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (parseCommand(args[i]) != null) return i;
        if (std.mem.eql(u8, args[i], "--config") or std.mem.eql(u8, args[i], "--staging-area") or std.mem.eql(u8, args[i], "--final-destination") or std.mem.eql(u8, args[i], "--socket-path")) i += 1;
    }
    return null;
}

fn parseCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "add")) return .add;
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "show")) return .show;
    if (std.mem.eql(u8, value, "pause")) return .pause;
    if (std.mem.eql(u8, value, "resume")) return .@"resume";
    if (std.mem.eql(u8, value, "remove")) return .remove;
    if (std.mem.eql(u8, value, "status")) return .status;
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
        \\Usage: torrent [options] <command>
        \\
        \\Options:
        \\  --config PATH
        \\
        \\Commands:
        \\  add <torrent-file>
        \\  list
        \\  show <info-hash>
        \\  pause <info-hash>
        \\  resume <info-hash>
        \\  remove <info-hash>
        \\  status
        \\
        \\The CLI is a control surface. It never mutates torrent state directly.
        \\
    );
}
