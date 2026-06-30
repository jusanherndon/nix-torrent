const std = @import("std");

const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const log = @import("log.zig");
const protocol = @import("protocol.zig");
const state = @import("state.zig");
const torrent = @import("torrent.zig");
const storage = @import("storage.zig");

const net = std.Io.net;

const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    registry: state.Registry,
    engine: engine_mod.Engine,
    peer_id: [20]u8,
    started_ms: i64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !Daemon {
        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .registry = state.Registry.init(allocator, @intCast(cfg.limits.max_active_torrents), @intCast(cfg.limits.max_peers_per_torrent)),
            .engine = engine_mod.Engine.init(allocator),
            .peer_id = try loadOrCreatePeerId(io, allocator, cfg.staging_area),
        };
    }

    fn deinit(self: *Daemon) void {
        self.engine.deinit(self.io);
        self.registry.deinit();
    }
};

var shutting_down: bool = false;
var listen_handle: ?net.Socket.Handle = null;
var signal_socket_path_buf: [net.UnixAddress.max_len]u8 = undefined;
var signal_socket_path_len: usize = 0;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const validate_config = hasArg(raw_args[1..], "--validate-config");
    const cfg_args = try daemonConfigArgs(init.arena.allocator(), raw_args[1..]);

    const cfg = config.loadFromArgsWithEnvAndIo(allocator, init.io, cfg_args, init.environ_map) catch |err| switch (err) {
        error.UnknownFlag, error.MissingFlagValue => {
            try config.usage("torrentd", stderr);
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

    if (validate_config) {
        try stderr.writeAll("configuration OK\n");
        try stderr.flush();
        return;
    }

    try ensureDirectory(init.io, cfg.staging_area);
    try ensureDirectory(init.io, cfg.final_destination);
    try ensureParentDirectory(init.io, cfg.socket_path);

    var lock_file = try acquireDaemonLock(init.io, allocator, cfg.staging_area);
    defer lock_file.close(init.io);

    var daemon = try Daemon.init(allocator, init.io, cfg);
    defer daemon.deinit();
    try loadPersistedSessions(&daemon);
    try daemon.engine.loadFromRegistry(daemon.io, daemon.cfg, &daemon.registry);

    try prepareSocketPath(init.io, cfg.socket_path);

    const ua = try net.UnixAddress.init(cfg.socket_path);
    @memcpy(signal_socket_path_buf[0..cfg.socket_path.len], cfg.socket_path);
    signal_socket_path_len = cfg.socket_path.len;
    var server = try ua.listen(init.io, .{ .kernel_backlog = 16 });
    const owned_socket_inode = (try std.Io.Dir.cwd().statFile(init.io, cfg.socket_path, .{ .follow_symlinks = false })).inode;
    listen_handle = server.socket.handle;
    defer {
        listen_handle = null;
        server.deinit(init.io);
        deleteOwnedSocket(init.io, cfg.socket_path, owned_socket_inode) catch {};
    }

    installSignalHandlers();

    try log.configEvent(stderr, "daemon", cfg.staging_area, cfg.final_destination, cfg.socket_path);
    try log.event(stderr, .info, "daemon", "control socket listening");
    try stderr.flush();

    daemon.started_ms = nowMs(init.io);

    while (!shutting_down) {
        const now_ms = nowMs(init.io);
        daemon.engine.tick(daemon.io, daemon.cfg, &daemon.registry, daemon.peer_id, now_ms) catch |err| {
            try stderr.print("{{\"level\":\"error\",\"component\":\"engine\",\"message\":\"tick failed: {s}\"}}\n", .{@errorName(err)});
            try stderr.flush();
        };

        if (try acceptWithTimeout(&server, init.io, 100)) |stream| {
            handleConnection(&daemon, stream, daemon.started_ms) catch |err| {
                try stderr.print("{{\"level\":\"error\",\"component\":\"daemon\",\"message\":\"connection failed: {s}\"}}\n", .{@errorName(err)});
                try stderr.flush();
            };
        }
    }

    try log.event(stderr, .info, "daemon", "controlled shutdown complete");
    try stderr.flush();
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

fn daemonConfigArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--validate-config")) continue;
        try out.append(allocator, arg);
        _ = i;
    }
    return out.toOwnedSlice(allocator);
}

fn handleConnection(daemon: *Daemon, stream: net.Stream, started: i64) !void {
    const io = daemon.io;
    const allocator = daemon.allocator;
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };

    const response = response: {
        const req = protocol.parseRequest(allocator, line) catch |err| switch (err) {
            error.UnknownCommand => break :response protocol.Response{ .failure = .{ .code = .unknown_command, .message = "unknown command" } },
            else => break :response protocol.Response{ .failure = .{ .code = .invalid_request, .message = "invalid JSON-line request" } },
        };
        defer protocol.deinitRequest(req, allocator);
        break :response try handleRequest(daemon, req, started);
    };

    const bytes = try response.toJson(allocator);
    defer allocator.free(bytes);
    defer response.deinit(allocator);
    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn handleRequest(daemon: *Daemon, req: protocol.Request, started: i64) !protocol.Response {
    const allocator = daemon.allocator;
    switch (req.command) {
        .status => {
            var root: std.json.ObjectMap = .empty;
            errdefer root.deinit(allocator);
            try root.put(allocator, "daemon_version", .{ .string = "0.2.0" });
            try root.put(allocator, "control_protocol_version", .{ .integer = protocol.CONTROL_PROTOCOL_VERSION });
            const uptime = @max(@as(i64, 0), @divFloor(nowMs(daemon.io) - started, 1000));
            try root.put(allocator, "uptime_seconds", .{ .integer = uptime });
            try root.put(allocator, "active_torrent_count", .{ .integer = @intCast(daemon.registry.records.items.len) });
            var limits: std.json.ObjectMap = .empty;
            errdefer limits.deinit(allocator);
            try limits.put(allocator, "max_active_torrents", .{ .integer = @intCast(daemon.cfg.limits.max_active_torrents) });
            try limits.put(allocator, "max_peers_per_torrent", .{ .integer = @intCast(daemon.cfg.limits.max_peers_per_torrent) });
            try limits.put(allocator, "max_torrent_file_bytes", .{ .integer = @intCast(daemon.cfg.limits.max_torrent_file_bytes) });
            try root.put(allocator, "limits", .{ .object = limits });
            return .{ .success = .{ .object = root } };
        },
        .list => return listResponse(daemon),
        .show => {
            const info_hash = req.argument orelse return .{ .failure = .{ .code = .invalid_arguments, .message = "info hash argument is required" } };
            if (daemon.registry.find(info_hash)) |rec| return showResponse(daemon, rec.*);
            if (daemon.registry.findCompletion(info_hash)) |rec| return showCompletionResponse(daemon, rec.*);
            return .{ .failure = .{ .code = .not_found, .message = "torrent is not known to this daemon" } };
        },
        .pause => {
            const info_hash = req.argument orelse return .{ .failure = .{ .code = .invalid_arguments, .message = "info hash argument is required" } };
            const rec = daemon.registry.find(info_hash) orelse {
                if (daemon.registry.findCompletion(info_hash) != null) return .{ .failure = .{ .code = .already_completed, .message = "completed torrents cannot be paused, resumed, or removed in v2" } };
                return .{ .failure = .{ .code = .not_found, .message = "torrent is not known to this daemon" } };
            };
            rec.status = .paused;
            try state.writeTorrentState(daemon.io, allocator, daemon.cfg.staging_area, rec.*);
            daemon.engine.removeSession(daemon.io, info_hash);
            return showResponse(daemon, rec.*);
        },
        .@"resume" => {
            const info_hash = req.argument orelse return .{ .failure = .{ .code = .invalid_arguments, .message = "info hash argument is required" } };
            const rec = daemon.registry.find(info_hash) orelse {
                if (daemon.registry.findCompletion(info_hash) != null) return .{ .failure = .{ .code = .already_completed, .message = "completed torrents cannot be paused, resumed, or removed in v2" } };
                return .{ .failure = .{ .code = .not_found, .message = "torrent is not known to this daemon" } };
            };
            rec.status = .active;
            if (rec.tracker_error) |old| {
                daemon.allocator.free(old);
                rec.tracker_error = null;
            }
            try state.writeTorrentState(daemon.io, allocator, daemon.cfg.staging_area, rec.*);
            try daemon.engine.addSession(daemon.io, daemon.cfg, &daemon.registry, rec);
            return showResponse(daemon, rec.*);
        },
        .remove => {
            const info_hash = req.argument orelse return .{ .failure = .{ .code = .invalid_arguments, .message = "info hash argument is required" } };
            if (!daemon.registry.remove(info_hash)) {
                if (daemon.registry.findCompletion(info_hash) != null) return .{ .failure = .{ .code = .already_completed, .message = "completed torrents cannot be paused, resumed, or removed in v2" } };
                return .{ .failure = .{ .code = .not_found, .message = "torrent is not known to this daemon" } };
            }
            daemon.engine.removeSession(daemon.io, info_hash);
            deleteTorrentStateFile(daemon, info_hash) catch {};
            var root: std.json.ObjectMap = .empty;
            errdefer root.deinit(allocator);
            try root.put(allocator, "removed", .{ .bool = true });
            return .{ .success = .{ .object = root } };
        },
        .add => return addTorrent(daemon, req.argument orelse return .{ .failure = .{ .code = .invalid_arguments, .message = "torrent file argument is required" } }),
    }
}

fn addTorrent(daemon: *Daemon, path: []const u8) !protocol.Response {
    const allocator = daemon.allocator;
    const meta = torrent.Metadata.parseFile(allocator, daemon.io, path) catch return .{ .failure = .{ .code = .torrent_parse_error, .message = "failed to parse torrent file" } };
    defer meta.deinit();

    torrent.validateLimits(meta, daemon.cfg.limits, meta.bytes.len) catch return .{ .failure = .{ .code = .config_error, .message = "torrent exceeds configured safety limits" } };

    storage.validatePaths(allocator, meta) catch return .{ .failure = .{ .code = .storage_error, .message = "torrent contains unsafe or unsupported file paths" } };

    const announce = validateTracker(meta) catch |err| switch (err) {
        error.UnsupportedTrackerScheme => return .{ .failure = .{ .code = .unsupported_tracker_scheme, .message = "only plain http:// trackers are supported in v2" } },
        else => return .{ .failure = .{ .code = .unsupported_tracker_metadata, .message = "torrent requires a usable top-level announce tracker" } },
    };
    const hex_buf = state.infoHashHex(meta.info_hash);
    const hex = &hex_buf;
    if (daemon.registry.findCompletion(hex) != null) return .{ .failure = .{ .code = .already_completed, .message = "torrent already completed and cannot be re-added in v2" } };
    if (daemon.registry.find(hex) != null) return .{ .failure = .{ .code = .duplicate_torrent, .message = "torrent is already active" } };

    const dir = try std.fs.path.join(allocator, &.{ daemon.cfg.staging_area, hex });
    defer allocator.free(dir);
    const state_path = try std.fs.path.join(allocator, &.{ dir, "state.json" });
    defer allocator.free(state_path);
    const adopting = stagingDirExistsWithoutState(daemon.io, dir, state_path) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };

    try std.Io.Dir.cwd().createDirPath(daemon.io, dir);
    const metadata_path = try std.fs.path.join(allocator, &.{ dir, "metadata.torrent" });
    defer allocator.free(metadata_path);
    if (adopting) {
        if (std.Io.Dir.cwd().readFileAlloc(daemon.io, metadata_path, allocator, .limited(16 * 1024 * 1024))) |existing_bytes| {
            defer allocator.free(existing_bytes);
            const existing = torrent.Metadata.parseBytes(allocator, existing_bytes) catch return .{ .failure = .{ .code = .storage_error, .message = "existing staged metadata is corrupt" } };
            defer existing.deinit();
            const existing_hex = state.infoHashHex(existing.info_hash);
            if (!std.mem.eql(u8, &existing_hex, hex)) return .{ .failure = .{ .code = .storage_error, .message = "staged metadata info hash does not match staging directory" } };
        } else |_| {}
    }
    try std.Io.Dir.cwd().writeFile(daemon.io, .{ .sub_path = metadata_path, .data = meta.bytes, .flags = .{ .truncate = true } });
    const content_dir = try std.fs.path.join(allocator, &.{ dir, "content" });
    defer allocator.free(content_dir);
    try std.Io.Dir.cwd().createDirPath(daemon.io, content_dir);
    if (!adopting) {
        storage.createStagedFiles(daemon.io, allocator, content_dir, meta) catch return .{ .failure = .{ .code = .storage_error, .message = "failed to create staged content files" } };
    }

    var rec = state.TorrentRecord{
        .info_hash_hex = hex,
        .name = meta.name,
        .status = .active,
        .tracker_url = announce,
        .total_bytes = state.totalBytes(meta),
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
    };
    recheckSession(daemon, hex, &rec) catch |err| switch (err) {
        error.StateCorruption => return .{ .failure = .{ .code = .storage_error, .message = "staged metadata info hash does not match staging directory" } },
        else => return .{ .failure = .{ .code = .storage_error, .message = "failed to recheck staged content" } },
    };

    try daemon.registry.add(rec);
    const stored = daemon.registry.find(hex).?;
    try state.writeTorrentState(daemon.io, allocator, daemon.cfg.staging_area, stored.*);
    try daemon.engine.addSession(daemon.io, daemon.cfg, &daemon.registry, stored);
    return showResponse(daemon, stored.*);
}

fn validateTracker(meta: torrent.Metadata) ![]const u8 {
    const announce = meta.announce orelse return error.UnsupportedTrackerMetadata;
    if (!std.mem.startsWith(u8, announce, "http://")) return error.UnsupportedTrackerScheme;
    return announce;
}

fn listResponse(daemon: *Daemon) !protocol.Response {
    const allocator = daemon.allocator;
    var torrents = std.json.Array.init(allocator);
    errdefer torrents.deinit();
    for (daemon.registry.records.items) |rec| try torrents.append(try summaryValue(daemon, allocator, rec));
    for (daemon.registry.history.items) |rec| try torrents.append(try completionSummaryValue(allocator, rec));
    var root: std.json.ObjectMap = .empty;
    errdefer root.deinit(allocator);
    try root.put(allocator, "torrents", .{ .array = torrents });
    return .{ .success = .{ .object = root } };
}

fn showResponse(daemon: *Daemon, rec: state.TorrentRecord) !protocol.Response {
    const allocator = daemon.allocator;
    var root = try summaryObject(daemon, allocator, rec);
    errdefer root.deinit(allocator);
    try root.put(allocator, "piece_count", .{ .integer = @intCast(rec.piece_count) });
    try root.put(allocator, "verified_piece_count", .{ .integer = @intCast(rec.verified_piece_count) });
    try root.put(allocator, "derived_activity", .{ .string = derivedActivity(daemon, rec) });
    try root.put(allocator, "connected_peer_count", .{ .integer = connectedPeerCount(daemon, rec.info_hash_hex) });
    if (rec.tracker_url) |url| try root.put(allocator, "tracker_announce_url", .{ .string = url });
    try root.put(allocator, "tracker_status", .{ .string = rec.tracker_error orelse "not_announced" });
    return .{ .success = .{ .object = root } };
}

fn summaryValue(daemon: *Daemon, allocator: std.mem.Allocator, rec: state.TorrentRecord) !std.json.Value {
    return .{ .object = try summaryObject(daemon, allocator, rec) };
}

fn showCompletionResponse(daemon: *Daemon, rec: state.CompletionRecord) !protocol.Response {
    var root = try completionSummaryObject(daemon.allocator, rec);
    errdefer root.deinit(daemon.allocator);
    try root.put(daemon.allocator, "completed_at", .{ .string = rec.completed_at });
    return .{ .success = .{ .object = root } };
}

fn completionSummaryValue(allocator: std.mem.Allocator, rec: state.CompletionRecord) !std.json.Value {
    return .{ .object = try completionSummaryObject(allocator, rec) };
}

fn completionSummaryObject(allocator: std.mem.Allocator, rec: state.CompletionRecord) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "info_hash", .{ .string = rec.info_hash_hex });
    try obj.put(allocator, "name", .{ .string = rec.name });
    try obj.put(allocator, "lifecycle_status", .{ .string = "complete" });
    try obj.put(allocator, "verified_bytes", .{ .integer = @intCast(rec.total_bytes) });
    try obj.put(allocator, "total_bytes", .{ .integer = @intCast(rec.total_bytes) });
    try obj.put(allocator, "connected_peer_count", .{ .integer = 0 });
    try obj.put(allocator, "final_path", .{ .string = rec.final_path });
    return obj;
}

fn summaryObject(daemon: *Daemon, allocator: std.mem.Allocator, rec: state.TorrentRecord) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "info_hash", .{ .string = rec.info_hash_hex });
    try obj.put(allocator, "name", .{ .string = rec.name });
    try obj.put(allocator, "lifecycle_status", .{ .string = @tagName(rec.status) });
    try obj.put(allocator, "verified_bytes", .{ .integer = @intCast(verifiedBytes(rec)) });
    try obj.put(allocator, "total_bytes", .{ .integer = @intCast(rec.total_bytes) });
    try obj.put(allocator, "connected_peer_count", .{ .integer = connectedPeerCount(daemon, rec.info_hash_hex) });
    return obj;
}

fn connectedPeerCount(daemon: *Daemon, info_hash_hex: []const u8) i64 {
    if (daemon.engine.findSession(info_hash_hex)) |session| return @intCast(session.peers.items.len);
    return 0;
}

fn derivedActivity(daemon: *Daemon, rec: state.TorrentRecord) []const u8 {
    if (rec.status != .active) return @tagName(rec.status);
    if (daemon.engine.findSession(rec.info_hash_hex)) |session| {
        if (session.active_piece != null) return "downloading";
        if (session.peers.items.len > 0) return "connecting";
        if (session.tracker_state.last_error != null) return "announcing";
    }
    return "waiting_for_peers";
}

fn acceptWithTimeout(server: *net.Server, io: std.Io, timeout_ms: i32) !?net.Stream {
    var fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = try std.posix.poll(&fds, timeout_ms);
    if (n == 0) return null;
    return server.accept(io) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => |e| return e,
    };
}

fn verifiedBytes(rec: state.TorrentRecord) u64 {
    if (rec.verified_piece_count == 0 or rec.piece_length == 0) return 0;
    const full = @as(u64, @intCast(rec.verified_piece_count)) * rec.piece_length;
    return @min(full, rec.total_bytes);
}

fn stagingDirExistsWithoutState(io: std.Io, dir: []const u8, state_path: []const u8) !bool {
    _ = try std.Io.Dir.cwd().statFile(io, dir, .{ .follow_symlinks = false });
    const state_stat = std.Io.Dir.cwd().statFile(io, state_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    _ = state_stat;
    return false;
}

fn recheckSession(daemon: *Daemon, info_hash_hex: []const u8, rec: *state.TorrentRecord) !void {
    const metadata_path = try std.fs.path.join(daemon.allocator, &.{ daemon.cfg.staging_area, info_hash_hex, "metadata.torrent" });
    defer daemon.allocator.free(metadata_path);
    const meta = try torrent.Metadata.parseFile(daemon.allocator, daemon.io, metadata_path);
    defer meta.deinit();
    const parsed_hex = state.infoHashHex(meta.info_hash);
    if (!std.mem.eql(u8, &parsed_hex, info_hash_hex)) return error.StateCorruption;
    var layout = try storage.Layout.init(daemon.allocator, meta);
    defer layout.deinit();
    const content_dir = try std.fs.path.join(daemon.allocator, &.{ daemon.cfg.staging_area, info_hash_hex, "content" });
    defer daemon.allocator.free(content_dir);
    try storage.recheck(daemon.io, daemon.allocator, content_dir, meta, &layout);
    rec.verified_piece_count = 0;
    for (layout.piece_states) |piece_state| {
        if (piece_state == .verified) rec.verified_piece_count += 1;
    }
    rec.piece_length = meta.piece_length;
    rec.piece_count = meta.pieces.len / 20;
    rec.total_bytes = state.totalBytes(meta);
}

fn validatePersistedSession(daemon: *Daemon, info_hash_hex: []const u8, rec: *state.TorrentRecord) !void {
    const metadata_path = try std.fs.path.join(daemon.allocator, &.{ daemon.cfg.staging_area, info_hash_hex, "metadata.torrent" });
    defer daemon.allocator.free(metadata_path);
    const meta = try torrent.Metadata.parseFile(daemon.allocator, daemon.io, metadata_path);
    defer meta.deinit();
    const parsed_hex = state.infoHashHex(meta.info_hash);
    if (!std.mem.eql(u8, &parsed_hex, info_hash_hex)) return error.StateCorruption;
    torrent.validateLimits(meta, daemon.cfg.limits, meta.bytes.len) catch {
        rec.status = .failed;
        if (rec.tracker_error) |old| daemon.allocator.free(old);
        rec.tracker_error = try daemon.allocator.dupe(u8, "torrent metadata exceeds configured safety limits");
        return;
    };
    try recheckSession(daemon, info_hash_hex, rec);
}

fn loadPersistedSessions(daemon: *Daemon) !void {
    const history = state.readHistory(daemon.io, daemon.allocator, daemon.cfg.staging_area) catch |err| switch (err) {
        error.DuplicateCompletion => return error.StateCorruption,
        else => return err,
    };
    defer state.freeHistory(daemon.allocator, history);
    for (history) |record| try daemon.registry.addCompletion(record);

    var dir = std.Io.Dir.cwd().openDir(daemon.io, daemon.cfg.staging_area, .{ .iterate = true }) catch return;
    defer dir.close(daemon.io);
    var it = dir.iterate();
    while (try it.next(daemon.io)) |entry| {
        if (entry.kind != .directory or entry.name.len != 40) continue;
        const state_path = try std.fs.path.join(daemon.allocator, &.{ daemon.cfg.staging_area, entry.name, "state.json" });
        defer daemon.allocator.free(state_path);
        var rec = state.readTorrentState(daemon.io, daemon.allocator, state_path) catch continue;
        defer state.deinitRecord(daemon.allocator, rec);
        if (daemon.registry.findCompletion(rec.info_hash_hex) != null) return error.StateCorruption;
        validatePersistedSession(daemon, entry.name, &rec) catch |err| switch (err) {
            error.StateCorruption => return err,
            else => {
                rec.status = .failed;
                if (rec.tracker_error) |old| daemon.allocator.free(old);
                rec.tracker_error = try std.fmt.allocPrint(daemon.allocator, "startup validation failed: {s}", .{@errorName(err)});
            },
        };
        try daemon.registry.add(rec);
        const stored = daemon.registry.find(entry.name).?;
        try state.writeTorrentState(daemon.io, daemon.allocator, daemon.cfg.staging_area, stored.*);
    }
}

fn deleteTorrentStateFile(daemon: *Daemon, info_hash: []const u8) !void {
    const path = try std.fs.path.join(daemon.allocator, &.{ daemon.cfg.staging_area, info_hash, "state.json" });
    defer daemon.allocator.free(path);
    try deleteFile(daemon.io, path);
}

fn loadOrCreatePeerId(io: std.Io, allocator: std.mem.Allocator, staging_root: []const u8) ![20]u8 {
    const path = try std.fs.path.join(allocator, &.{ staging_root, "client-peer-id" });
    defer allocator.free(path);
    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64))) |bytes| {
        defer allocator.free(bytes);
        if (bytes.len >= 20) return bytes[0..20].*;
    } else |_| {}
    var peer_id: [20]u8 = undefined;
    @memcpy(peer_id[0..8], "-NT0002-");
    var seed: u64 = @intCast(std.os.linux.getpid());
    seed ^= @intFromPtr(&peer_id);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(peer_id[8..]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &peer_id });
    return peer_id;
}

fn ensureDirectory(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn ensureParentDirectory(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try ensureDirectory(io, parent);
}

fn acquireDaemonLock(io: std.Io, allocator: std.mem.Allocator, staging_area: []const u8) !std.Io.File {
    const lock_path = try std.fs.path.join(allocator, &.{ staging_area, "daemon.lock" });
    defer allocator.free(lock_path);
    return std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => error.DaemonAlreadyRunning,
        else => err,
    };
}

fn prepareSocketPath(io: std.Io, socket_path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, socket_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) {
        try deleteFile(io, socket_path);
        return;
    }

    const ua = try net.UnixAddress.init(socket_path);
    var existing = ua.connect(io) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            deleteFile(io, socket_path) catch {};
            return;
        },
    };
    existing.close(io);
    return error.DaemonAlreadyRunning;
}

fn deleteFile(io: std.Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.deleteFileAbsolute(io, path);
    return std.Io.Dir.cwd().deleteFile(io, path);
}

fn deleteOwnedSocket(io: std.Io, path: []const u8, owned_inode: std.Io.File.INode) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .unix_domain_socket and stat.inode == owned_inode) try deleteFile(io, path);
}

fn installSignalHandlers() void {
    if (std.posix.Sigaction == void) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    shutting_down = true;
    wakeAccept();
}

fn wakeAccept() void {
    if (signal_socket_path_len == 0) return;
    const linux = std.os.linux;
    const fd_usize = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (fd_usize > std.math.maxInt(i32)) return;
    const fd: i32 = @intCast(fd_usize);
    var addr: linux.sockaddr.un = undefined;
    addr.family = linux.AF.UNIX;
    @memset(&addr.path, 0);
    const n = @min(signal_socket_path_len, addr.path.len - 1);
    @memcpy(addr.path[0..n], signal_socket_path_buf[0..n]);
    _ = linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un));
    _ = linux.close(fd);
}
