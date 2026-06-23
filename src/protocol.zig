const std = @import("std");

pub const CONTROL_PROTOCOL_VERSION: u32 = 1;

pub const Command = enum { add, list, show, pause, @"resume", remove, status };

pub const ErrorCode = enum {
    invalid_request,
    unknown_command,
    invalid_arguments,
    torrent_parse_error,
    unsupported_tracker_scheme,
    unsupported_tracker_metadata,
    duplicate_torrent,
    already_completed,
    not_found,
    config_error,
    storage_error,
    tracker_error,
    peer_error,
    handoff_failed,
    internal_error,
};

pub const Request = struct {
    command: Command,
    argument: ?[]const u8 = null,

    pub fn toJson(self: Request, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(self, .{ .emit_null_optional_fields = false }, &out.writer);
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }
};

pub const ProtocolError = struct {
    code: ErrorCode,
    message: []const u8,
};

pub const Response = union(enum) {
    success: std.json.Value,
    failure: ProtocolError,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => |value| deinitValue(value, allocator),
            .failure => {},
        }
    }

    pub fn toJson(self: Response, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try jw.beginObject();
        try jw.objectField("ok");
        switch (self) {
            .success => |result| {
                try jw.write(true);
                try jw.objectField("result");
                try jw.write(result);
            },
            .failure => |err| {
                try jw.write(false);
                try jw.objectField("error");
                try jw.write(err);
            },
        }
        try jw.endObject();
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }
};

fn deinitValue(value: std.json.Value, allocator: std.mem.Allocator) void {
    switch (value) {
        .array => |array| {
            for (array.items) |item| deinitValue(item, allocator);
            var a = array;
            a.deinit();
        },
        .object => |object| {
            var o = object;
            var it = o.iterator();
            while (it.next()) |entry| deinitValue(entry.value_ptr.*, allocator);
            o.deinit(allocator);
        },
        else => {},
    }
}

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !Request {
    const Wire = struct { command: []const u8, argument: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Wire, allocator, std.mem.trim(u8, bytes, "\r\n"), .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const command = parseCommand(parsed.value.command) orelse return error.UnknownCommand;
    return .{
        .command = command,
        .argument = if (parsed.value.argument) |arg| try allocator.dupe(u8, arg) else null,
    };
}

pub fn deinitRequest(req: Request, allocator: std.mem.Allocator) void {
    if (req.argument) |arg| allocator.free(arg);
}

pub fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, bytes, "\r\n"), .{});
}

fn parseCommand(value: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |f| if (std.mem.eql(u8, value, f.name)) return @enumFromInt(f.value);
    return null;
}

test "round trips json request with escaping" {
    const json = try (Request{ .command = .add, .argument = "fi\\le\".torrent" }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const req = try parseRequest(std.testing.allocator, json);
    defer deinitRequest(req, std.testing.allocator);
    try std.testing.expectEqual(Command.add, req.command);
    try std.testing.expectEqualStrings("fi\\le\".torrent", req.argument.?);
}

test "writes structured success response" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, "torrents", .{ .array = .init(std.testing.allocator) });
    defer map.getPtr("torrents").?.array.deinit();
    const json = try (Response{ .success = .{ .object = map } }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const res = try parseResponse(std.testing.allocator, json);
    defer res.deinit();
    try std.testing.expectEqual(true, res.value.object.get("ok").?.bool);
}
