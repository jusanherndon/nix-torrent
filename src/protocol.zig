const std = @import("std");

pub const Command = enum { add, list, show, pause, @"resume", remove };

pub const Request = struct {
    command: Command,
    argument: ?[]const u8 = null,

    pub fn toJson(self: Request, allocator: std.mem.Allocator) ![]u8 {
        const cmd = @tagName(self.command);
        if (self.argument) |arg| return std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\",\"argument\":\"{s}\"}}\n", .{ cmd, arg });
        return std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}\n", .{cmd});
    }
};

pub const Response = struct {
    ok: bool,
    message: []const u8,

    pub fn toJson(self: Response, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{{\"ok\":{},\"message\":\"{s}\"}}\n", .{ self.ok, self.message });
    }
};

pub fn parseRequest(bytes: []const u8) !Request {
    const cmd = try field(bytes, "command");
    const command = parseCommand(cmd) orelse return error.UnknownCommand;
    return .{ .command = command, .argument = field(bytes, "argument") catch null };
}

pub fn parseResponse(bytes: []const u8) !Response {
    const ok = if (std.mem.indexOf(u8, bytes, "\"ok\":true") != null) true else if (std.mem.indexOf(u8, bytes, "\"ok\":false") != null) false else return error.InvalidResponse;
    return .{ .ok = ok, .message = field(bytes, "message") catch "" };
}

fn parseCommand(value: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |f| if (std.mem.eql(u8, value, f.name)) return @enumFromInt(f.value);
    return null;
}

fn field(bytes: []const u8, name: []const u8) ![]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{name});
    const start = std.mem.indexOf(u8, bytes, needle) orelse return error.MissingField;
    const value_start = start + needle.len;
    const rest = bytes[value_start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.InvalidJson;
    return rest[0..end];
}

test "round trips json request" {
    const json = try (Request{ .command = .add, .argument = "file.torrent" }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const req = try parseRequest(json);
    try std.testing.expectEqual(Command.add, req.command);
    try std.testing.expectEqualStrings("file.torrent", req.argument.?);
}

test "round trips json response" {
    const json = try (Response{ .ok = true, .message = "queued" }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const res = try parseResponse(json);
    try std.testing.expect(res.ok);
    try std.testing.expectEqualStrings("queued", res.message);
}
