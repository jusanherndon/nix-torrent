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
    if (timeout_ms == 0) {
        const stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => return error.ConnectionRefused,
            else => return error.ConnectionFailed,
        };
        return stream;
    }
    return try connectStreamWithTimeout(addr, timeout_ms);
}

fn connectStreamWithTimeout(addr: net.IpAddress, timeout_ms: u64) ConnectError!net.Stream {
    const ip4 = addr.ip4;
    const sock = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (sock == -1) return error.ConnectionFailed;
    errdefer _ = c.close(sock);

    const flags = c.fcntl(sock, c.F.GETFL, @as(c_int, 0));
    if (flags == -1) return error.ConnectionFailed;
    const o_nonblock: c_int = 0x800;
    if (c.fcntl(sock, c.F.SETFL, flags | o_nonblock) == -1) return error.ConnectionFailed;

    var sockaddr: c.sockaddr.in = .{
        .family = c.AF.INET,
        .port = std.mem.nativeToBig(u16, ip4.port),
        .addr = @bitCast(ip4.bytes),
        .zero = .{0} ** 8,
    };

    const rc = c.connect(sock, @ptrCast(&sockaddr), @sizeOf(c.sockaddr.in));
    switch (c.errno(rc)) {
        .SUCCESS => {
            _ = c.fcntl(sock, c.F.SETFL, flags);
            try ensureBlocking(sock);
            setIoTimeouts(sock, timeout_ms);
            return .{ .socket = .{ .handle = sock, .address = addr } };
        },
        .INPROGRESS, .ALREADY => {},
        .CONNREFUSED => return error.ConnectionRefused,
        .TIMEDOUT => return error.Timeout,
        .NETUNREACH, .HOSTUNREACH => return error.ConnectionFailed,
        else => return error.ConnectionFailed,
    }

    var pollfd = c.pollfd{ .fd = sock, .events = c.POLL.OUT, .revents = 0 };
    const poll_ms: c_int = @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(c_int)))));
    const ready = c.poll(@ptrCast(&pollfd), 1, poll_ms);
    if (ready == 0) return error.Timeout;
    if (ready < 0) return error.ConnectionFailed;

    var sock_err: c_int = 0;
    var sock_err_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(sock, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&sock_err), &sock_err_len) == -1) return error.ConnectionFailed;
    if (sock_err != 0) {
        if (sock_err == @intFromEnum(std.posix.E.CONNREFUSED)) return error.ConnectionRefused;
        if (sock_err == @intFromEnum(std.posix.E.TIMEDOUT)) return error.Timeout;
        return error.ConnectionFailed;
    }

    _ = c.fcntl(sock, c.F.SETFL, flags);
    try ensureBlocking(sock);
    setIoTimeouts(sock, timeout_ms);
    return .{ .socket = .{ .handle = sock, .address = addr } };
}

fn ensureBlocking(sock: c.fd_t) ConnectError!void {
    const flags = c.fcntl(sock, c.F.GETFL, @as(c_int, 0));
    if (flags == -1) return error.ConnectionFailed;
    const o_nonblock: c_int = 0x800;
    if (flags & o_nonblock != 0 and c.fcntl(sock, c.F.SETFL, flags & ~o_nonblock) == -1) return error.ConnectionFailed;
}

/// Reads up to `dest.len` bytes, waiting at most `timeout_ms` for data.
pub fn readSome(sock: c.fd_t, dest: []u8, timeout_ms: u64) ReadError!usize {
    try pollReadable(sock, timeout_ms);
    while (true) {
        const n = c.recv(sock, dest.ptr, dest.len, 0);
        if (n != -1) return @intCast(n);
        switch (c.errno(n)) {
            .INTR => continue,
            .AGAIN => return error.Timeout,
            else => return error.ReadFailed,
        }
    }
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
    var chunked = false;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (headerNameEquals(trimmed, "Content-Length")) {
            const val = headerValue(trimmed);
            content_length = std.fmt.parseInt(usize, val, 10) catch return error.InvalidHttpResponse;
        } else if (headerNameEquals(trimmed, "Transfer-Encoding")) {
            const val = headerValue(trimmed);
            if (std.ascii.indexOfIgnoreCase(val, "chunked") != null) chunked = true;
        }
    }
    if (content_length) |len| {
        if (body.len < len) return error.InvalidHttpResponse;
        return try allocator.dupe(u8, body[0..len]);
    }
    if (chunked) return try decodeChunkedBody(allocator, body);
    return try allocator.dupe(u8, body);
}

fn headerNameEquals(line: []const u8, name: []const u8) bool {
    if (line.len < name.len + 1) return false;
    if (!std.ascii.eqlIgnoreCase(line[0..name.len], name)) return false;
    return line[name.len] == ':';
}

fn headerValue(line: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return "";
    return std.mem.trim(u8, line[colon + 1 ..], " \t");
}

fn decodeChunkedBody(allocator: std.mem.Allocator, body: []const u8) ReadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos < body.len) {
        const line_end = std.mem.indexOfPos(u8, body, pos, "\r\n") orelse return error.InvalidHttpResponse;
        const size_line = body[pos..line_end];
        const size_end = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_line[0..size_end], " \t"), 16) catch return error.InvalidHttpResponse;
        pos = line_end + 2;
        if (size == 0) break;
        if (pos + size + 2 > body.len) return error.InvalidHttpResponse;
        try out.appendSlice(allocator, body[pos .. pos + size]);
        pos += size;
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.InvalidHttpResponse;
        pos += 2;
    }
    return out.toOwnedSlice(allocator);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

test "connectStream reaches localhost listener" {
    const io = std.testing.io;
    const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    var server = try addr.listen(io, .{ .mode = .stream, .kernel_backlog = 1 });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    const stream = try connectStream(io, .{ 127, 0, 0, 1 }, port, 2000);
    defer stream.close(io);
    const client = c.accept(server.socket.handle, null, null);
    try std.testing.expect(client >= 0);
    _ = c.close(@intCast(client));
}

test "extracts http body" {
    const raw = "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    const body = try extractHttpBody(std.testing.allocator, raw);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "extracts chunked http body" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    const body = try extractHttpBody(std.testing.allocator, raw);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "extracts chunked tracker-style body" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3e\r\nd8:completei1e10:incompletei1e8:intervali1800e5:peers6:\x7f\x00\x00\x01\x1a\xe1e\r\n0\r\n\r\n";
    const body = try extractHttpBody(std.testing.allocator, raw);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "d8:complete"));
}
