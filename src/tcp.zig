const std = @import("std");

const net = std.Io.net;
const c = std.c;

pub const ConnectError = error{
    Timeout,
    ConnectionRefused,
    ConnectionFailed,
};

/// Opens a TCP stream to an IPv4 endpoint and applies read/write timeouts.
pub fn connectStream(io: std.Io, ip: [4]u8, port: u16, timeout_ms: u64) ConnectError!net.Stream {
    const addr = net.IpAddress{ .ip4 = .{ .bytes = ip, .port = port } };
    const stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.ConnectionFailed;
    if (timeout_ms > 0) setIoTimeouts(stream.socket.handle, timeout_ms);
    return stream;
}

pub fn setIoTimeouts(sock: c.fd_t, timeout_ms: u64) void {
    const tv = c.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    _ = c.setsockopt(sock, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    _ = c.setsockopt(sock, c.SOL.SOCKET, c.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
}

pub const ReadError = error{
    Timeout,
    ReadFailed,
    InvalidHttpResponse,
    OutOfMemory,
};

pub fn readHttpResponse(io: std.Io, sock: c.fd_t, allocator: std.mem.Allocator, timeout_ms: u64) ReadError![]u8 {
    const raw = try readAllWithTimeout(io, sock, allocator, timeout_ms);
    defer allocator.free(raw);
    return extractHttpBody(allocator, raw);
}

fn readAllWithTimeout(io: std.Io, sock: c.fd_t, allocator: std.mem.Allocator, timeout_ms: u64) ReadError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const deadline = nowMs(io) + @as(i64, @intCast(timeout_ms));
    var buf: [4096]u8 = undefined;
    while (true) {
        const now = nowMs(io);
        if (now >= deadline) return error.Timeout;
        const remaining: c_int = @intCast(@max(deadline - now, 0));
        try pollReadable(sock, @intCast(remaining));
        const n = c.recv(sock, &buf, buf.len, 0);
        if (n == -1) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

fn pollReadable(sock: c.fd_t, timeout_ms: u64) ReadError!void {
    var fds = c.pollfd{
        .fd = sock,
        .events = c.POLL.IN,
        .revents = 0,
    };
    const poll_ms: c_int = @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(c_int)))));
    const ready = c.poll(@ptrCast(&fds), 1, poll_ms);
    if (ready == 0) return error.Timeout;
    if (ready < 0) return error.ReadFailed;
}

fn extractHttpBody(allocator: std.mem.Allocator, raw: []const u8) ReadError![]u8 {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidHttpResponse;
    const header_end = if (raw[sep..].len >= 4 and raw[sep] == '\r') sep + 4 else sep + 2;
    const headers = raw[0..sep];
    const body = raw[header_end..];
    var content_length: ?usize = null;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const val = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, val, 10) catch return error.InvalidHttpResponse;
        }
    }
    if (content_length) |len| {
        if (body.len < len) return error.InvalidHttpResponse;
        return try allocator.dupe(u8, body[0..len]);
    }
    return try allocator.dupe(u8, body);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

test "extracts http body" {
    const raw = "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    const body = try extractHttpBody(std.testing.allocator, raw);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}
