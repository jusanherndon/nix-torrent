const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

pub fn event(writer: anytype, level: Level, component: []const u8, message: []const u8) !void {
    try writer.writeAll("{\"level\":");
    try jsonString(writer, level.label());
    try writer.writeAll(",\"component\":");
    try jsonString(writer, component);
    try writer.writeAll(",\"message\":");
    try jsonString(writer, message);
    try writer.writeAll("}\n");
}

pub fn configEvent(writer: anytype, component: []const u8, staging_area: []const u8, final_destination: []const u8, socket_path: []const u8) !void {
    try writer.writeAll("{\"level\":\"info\",\"component\":");
    try jsonString(writer, component);
    try writer.writeAll(",\"message\":\"configuration loaded\",\"staging_area\":");
    try jsonString(writer, staging_area);
    try writer.writeAll(",\"final_destination\":");
    try jsonString(writer, final_destination);
    try writer.writeAll(",\"socket_path\":");
    try jsonString(writer, socket_path);
    try writer.writeAll("}\n");
}

fn jsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test "writes json log event" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try event(buffer.writer(), .info, "test", "hello");
    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"component\":\"test\",\"message\":\"hello\"}\n",
        buffer.items,
    );
}

test "escapes json strings" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try event(buffer.writer(), .warn, "quote", "a \"thing\"");
    try std.testing.expectEqualStrings(
        "{\"level\":\"warn\",\"component\":\"quote\",\"message\":\"a \\\"thing\\\"\"}\n",
        buffer.items,
    );
}
