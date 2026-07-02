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

pub const default_level: []const u8 = "debug";

pub fn parseLevel(name: []const u8) ?Level {
    if (std.mem.eql(u8, name, "debug")) return .debug;
    if (std.mem.eql(u8, name, "info")) return .info;
    if (std.mem.eql(u8, name, "warn")) return .warn;
    if (std.mem.eql(u8, name, "error")) return .err;
    return null;
}

pub const Logger = struct {
    writer: *std.Io.Writer,
    min_level: Level,

    pub fn init(writer: *std.Io.Writer, level_name: []const u8) Logger {
        return .{
            .writer = writer,
            .min_level = parseLevel(level_name) orelse .info,
        };
    }

    pub fn enabled(self: Logger, level: Level) bool {
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    pub fn log(self: Logger, level: Level, component: []const u8, message: []const u8) void {
        if (!self.enabled(level)) return;
        event(self.writer, level, component, message) catch {};
    }

    pub fn logFmt(self: Logger, level: Level, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled(level)) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log message truncated";
        event(self.writer, level, component, msg) catch {};
    }
};

var active: ?Logger = null;

pub fn set(writer: *std.Io.Writer, level_name: []const u8) void {
    active = Logger.init(writer, level_name);
}

pub fn clear() void {
    active = null;
}

fn current() ?Logger {
    return active;
}

pub fn debug(comptime component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (current()) |logger| logger.logFmt(.debug, component, fmt, args);
}

pub fn info(comptime component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (current()) |logger| logger.logFmt(.info, component, fmt, args);
}

pub fn warn(comptime component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (current()) |logger| logger.logFmt(.warn, component, fmt, args);
}

pub fn err(comptime component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (current()) |logger| logger.logFmt(.err, component, fmt, args);
}

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
            0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test "writes json log event" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try event(&buffer.writer, .info, "test", "hello");
    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"component\":\"test\",\"message\":\"hello\"}\n",
        buffer.writer.buffered(),
    );
}

test "escapes json strings" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try event(&buffer.writer, .warn, "quote", "a \"thing\"");
    try std.testing.expectEqualStrings(
        "{\"level\":\"warn\",\"component\":\"quote\",\"message\":\"a \\\"thing\\\"\"}\n",
        buffer.writer.buffered(),
    );
}

test "filters by configured level" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    const logger = Logger.init(&buffer.writer, "info");
    try std.testing.expect(logger.enabled(.info));
    try std.testing.expect(logger.enabled(.warn));
    try std.testing.expect(!logger.enabled(.debug));

    logger.log(.debug, "test", "hidden");
    logger.log(.info, "test", "visible");
    try std.testing.expectEqualStrings(
        "{\"level\":\"info\",\"component\":\"test\",\"message\":\"visible\"}\n",
        buffer.writer.buffered(),
    );
}

test "parses log levels" {
    try std.testing.expectEqual(@as(?Level, .debug), parseLevel("debug"));
    try std.testing.expectEqual(@as(?Level, .info), parseLevel("info"));
    try std.testing.expectEqual(@as(?Level, .warn), parseLevel("warn"));
    try std.testing.expectEqual(@as(?Level, .err), parseLevel("error"));
    try std.testing.expect(parseLevel("verbose") == null);
}
