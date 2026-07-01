const std = @import("std");

pub const Limits = struct {
    max_peer_message_bytes: u64 = 1_048_576,
    max_torrent_file_bytes: u64 = 16_777_216,
    max_content_bytes: u64 = 1_099_511_627_776,
    max_files_per_torrent: u64 = 10_000,
    max_path_depth: u64 = 32,
    max_path_component_bytes: u64 = 255,
    max_piece_bytes: u64 = 67_108_864,
    max_piece_count: u64 = 1_000_000,
    max_active_torrents: u64 = 20,
    max_peers_per_torrent: u64 = 50,
    max_in_progress_pieces_per_torrent: u64 = 4,
    max_in_flight_blocks_per_peer: u64 = 8,
};

pub const Engine = struct { block_request_bytes: u64 = 16_384 };
pub const Network = struct {
    dht_base_port: u64 = 6881,
    peer_connect_timeout_ms: u64 = 10_000,
    peer_request_timeout_ms: u64 = 30_000,
    tracker_request_timeout_ms: u64 = 10_000,
    tracker_retry_min_ms: u64 = 30_000,
    tracker_retry_max_ms: u64 = 300_000,
};
pub const Logging = struct { level: []const u8 = "info", format: []const u8 = "json" };

pub const Config = struct {
    staging_area: []const u8,
    final_destination: []const u8,
    socket_path: []const u8,
    limits: Limits = .{},
    engine: Engine = .{},
    network: Network = .{},
    logging: Logging = .{},

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.staging_area);
        allocator.free(self.final_destination);
        allocator.free(self.socket_path);
        if (!std.mem.eql(u8, self.logging.level, "info")) allocator.free(self.logging.level);
        if (!std.mem.eql(u8, self.logging.format, "json")) allocator.free(self.logging.format);
    }
};

pub const ConfigError = error{
    MissingFlagValue,
    UnknownFlag,
    MissingExplicitConfig,
    InvalidConfig,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args, environ_map: ?*const std.process.Environ.Map) !Config {
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();

    const args = try process_args.toSlice(args_arena.allocator());
    return loadFromArgsWithEnvAndIo(allocator, io, args[1..], environ_map);
}

pub fn loadFromArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    return loadFromArgsWithEnv(allocator, args, null);
}

pub fn loadFromArgsWithEnv(allocator: std.mem.Allocator, args: []const []const u8, environ_map: ?*const std.process.Environ.Map) !Config {
    return loadFromArgsWithEnvAndIo(allocator, std.testing.io, args, environ_map);
}

pub fn loadFromArgsWithEnvAndIo(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, environ_map: ?*const std.process.Environ.Map) !Config {
    var cfg = try defaults(allocator, environ_map);
    errdefer cfg.deinit(allocator);

    const selected = try selectedConfigPath(allocator, args, environ_map);
    defer if (selected.path) |p| allocator.free(p);

    if (selected.path) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024))) |bytes| {
            defer allocator.free(bytes);
            try parseTomlInto(allocator, &cfg, bytes);
        } else |err| switch (err) {
            error.FileNotFound => if (selected.explicit) return ConfigError.MissingExplicitConfig,
            else => if (selected.explicit) return ConfigError.MissingExplicitConfig else {},
        }
    }

    try validateDaemon(cfg);
    return cfg;
}

const SelectedConfig = struct { path: ?[]u8, explicit: bool };

fn selectedConfigPath(allocator: std.mem.Allocator, args: []const []const u8, environ_map: ?*const std.process.Environ.Map) !SelectedConfig {
    var explicit: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return ConfigError.MissingFlagValue;
            explicit = args[i];
        } else if (std.mem.eql(u8, arg, "--staging-area") or std.mem.eql(u8, arg, "--final-destination") or std.mem.eql(u8, arg, "--socket-path")) {
            i += 1; // legacy v1 flags are silently ignored in v2
            if (i >= args.len) return ConfigError.MissingFlagValue;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return ConfigError.UnknownFlag;
        }
    }
    if (explicit) |p| return .{ .path = try allocator.dupe(u8, p), .explicit = true };
    return .{ .path = try defaultConfigPath(allocator, environ_map), .explicit = false };
}

fn defaults(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) !Config {
    const home = try homeDir(allocator, environ_map);
    defer allocator.free(home);
    const state_root = try stateRoot(allocator, environ_map, home);
    defer allocator.free(state_root);
    const runtime_root = try runtimeRoot(allocator, environ_map);
    defer allocator.free(runtime_root);
    return .{
        .staging_area = try std.fs.path.join(allocator, &.{ state_root, "nix-torrent", "staging" }),
        .final_destination = try std.fs.path.join(allocator, &.{ home, "Downloads", "nix-torrent" }),
        .socket_path = try std.fs.path.join(allocator, &.{ runtime_root, "nix-torrent.sock" }),
    };
}

fn defaultConfigPath(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    const config_root = if (environ_map) |map| map.get("XDG_CONFIG_HOME") orelse null else null;
    if (config_root) |root| return std.fs.path.join(allocator, &.{ root, "nix-torrent", "config.toml" });
    const home = try homeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "nix-torrent", "config.toml" });
}

fn stateRoot(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map, home: []const u8) ![]u8 {
    if (environ_map) |map| if (map.get("XDG_STATE_HOME")) |value| return allocator.dupe(u8, value);
    return std.fs.path.join(allocator, &.{ home, ".local", "state" });
}

fn runtimeRoot(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    if (environ_map) |map| if (map.get("XDG_RUNTIME_DIR")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "/tmp");
}

fn homeDir(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map) ![]u8 {
    if (environ_map) |map| if (map.get("HOME")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, ".");
}

pub fn validateDaemon(cfg: Config) !void {
    if (cfg.staging_area.len == 0 or cfg.final_destination.len == 0 or cfg.socket_path.len == 0) return ConfigError.InvalidConfig;
    if (cfg.limits.max_peer_message_bytes == 0 or cfg.limits.max_torrent_file_bytes == 0 or cfg.limits.max_content_bytes == 0) return ConfigError.InvalidConfig;
    if (cfg.limits.max_files_per_torrent == 0 or cfg.limits.max_path_depth == 0 or cfg.limits.max_path_component_bytes == 0) return ConfigError.InvalidConfig;
    if (cfg.limits.max_piece_bytes == 0 or cfg.limits.max_piece_count == 0 or cfg.limits.max_active_torrents == 0) return ConfigError.InvalidConfig;
    if (cfg.limits.max_peers_per_torrent == 0 or cfg.limits.max_in_progress_pieces_per_torrent == 0 or cfg.limits.max_in_flight_blocks_per_peer == 0) return ConfigError.InvalidConfig;
    if (cfg.engine.block_request_bytes == 0 or cfg.engine.block_request_bytes > cfg.limits.max_piece_bytes) return ConfigError.InvalidConfig;
    if (cfg.network.dht_base_port == 0 or cfg.network.dht_base_port > 65535) return ConfigError.InvalidConfig;
    if (cfg.network.dht_base_port + cfg.limits.max_active_torrents > 65535) return ConfigError.InvalidConfig;
    if (cfg.network.tracker_retry_min_ms > cfg.network.tracker_retry_max_ms) return ConfigError.InvalidConfig;
    if (!std.mem.eql(u8, cfg.logging.format, "json")) return ConfigError.InvalidConfig;
}

pub fn usage(program_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\Usage: {s} [options]
        \\
        \\Options:
        \\  --config PATH       TOML configuration file
        \\  --validate-config  Validate daemon configuration and exit (torrentd only)
        \\
    , .{program_name});
}

fn parseTomlInto(allocator: std.mem.Allocator, cfg: *Config, bytes: []const u8) !void {
    var section: enum { root, paths, limits, engine, network, logging } = .root;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |n| raw_line[0..n] else raw_line;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = line[1 .. line.len - 1];
            section = if (std.mem.eql(u8, name, "paths")) .paths else if (std.mem.eql(u8, name, "limits")) .limits else if (std.mem.eql(u8, name, "engine")) .engine else if (std.mem.eql(u8, name, "network")) .network else if (std.mem.eql(u8, name, "logging")) .logging else return ConfigError.InvalidConfig;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return ConfigError.InvalidConfig;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        switch (section) {
            .paths => try parsePath(allocator, cfg, key, value),
            .limits => try parseLimit(&cfg.limits, key, value),
            .engine => try parseEngine(&cfg.engine, key, value),
            .network => try parseNetwork(&cfg.network, key, value),
            .logging => try parseLogging(allocator, &cfg.logging, key, value),
            .root => return ConfigError.InvalidConfig,
        }
    }
}

fn parseString(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return ConfigError.InvalidConfig;
    return value[1 .. value.len - 1];
}
fn parseInt(value: []const u8) !u64 { return std.fmt.parseInt(u64, value, 10) catch ConfigError.InvalidConfig; }
fn replace(allocator: std.mem.Allocator, old: []const u8, new: []const u8) ![]const u8 { allocator.free(old); return allocator.dupe(u8, new); }

fn parsePath(allocator: std.mem.Allocator, cfg: *Config, key: []const u8, value: []const u8) !void {
    const s = try parseString(value);
    if (std.mem.eql(u8, key, "staging_area")) cfg.staging_area = try replace(allocator, cfg.staging_area, s)
    else if (std.mem.eql(u8, key, "final_destination")) cfg.final_destination = try replace(allocator, cfg.final_destination, s)
    else if (std.mem.eql(u8, key, "socket_path")) cfg.socket_path = try replace(allocator, cfg.socket_path, s)
    else return ConfigError.InvalidConfig;
}

fn parseLimit(l: *Limits, key: []const u8, value: []const u8) !void {
    const n = try parseInt(value);
    inline for (@typeInfo(Limits).@"struct".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) { @field(l, field.name) = n; return; }
    }
    return ConfigError.InvalidConfig;
}
fn parseEngine(e: *Engine, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "block_request_bytes")) e.block_request_bytes = try parseInt(value) else return ConfigError.InvalidConfig;
}
fn parseNetwork(n: *Network, key: []const u8, value: []const u8) !void {
    const v = try parseInt(value);
    if (std.mem.eql(u8, key, "announce_port")) {
        n.dht_base_port = v;
        return;
    }
    inline for (@typeInfo(Network).@"struct".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) { @field(n, field.name) = v; return; }
    }
    return ConfigError.InvalidConfig;
}
fn parseLogging(allocator: std.mem.Allocator, logging: *Logging, key: []const u8, value: []const u8) !void {
    const s = try parseString(value);
    if (std.mem.eql(u8, key, "level")) {
        if (!std.mem.eql(u8, logging.level, "info")) allocator.free(logging.level);
        logging.level = if (std.mem.eql(u8, s, "info")) "info" else try allocator.dupe(u8, s);
    } else if (std.mem.eql(u8, key, "format")) {
        if (!std.mem.eql(u8, logging.format, "json")) allocator.free(logging.format);
        logging.format = if (std.mem.eql(u8, s, "json")) "json" else try allocator.dupe(u8, s);
    } else return ConfigError.InvalidConfig;
}

test "loads explicit paths from toml and ignores legacy flags while selecting config" {
    const selected = try selectedConfigPath(std.testing.allocator, &.{ "--staging-area", "ignored", "--config", "config.toml" }, null);
    defer if (selected.path) |p| std.testing.allocator.free(p);
    try std.testing.expect(selected.explicit);
    try std.testing.expectEqualStrings("config.toml", selected.path.?);

    var cfg = try defaults(std.testing.allocator, null);
    defer cfg.deinit(std.testing.allocator);
    try parseTomlInto(std.testing.allocator, &cfg,
        \\[paths]
        \\staging_area = "var/staging"
        \\final_destination = "srv/downloads"
        \\socket_path = "run/nix-torrent.sock"
        \\[limits]
        \\max_active_torrents = 7
    );
    try std.testing.expectEqualStrings("var/staging", cfg.staging_area);
    try std.testing.expectEqualStrings("srv/downloads", cfg.final_destination);
    try std.testing.expectEqualStrings("run/nix-torrent.sock", cfg.socket_path);
    try std.testing.expectEqual(@as(u64, 7), cfg.limits.max_active_torrents);
}

test "rejects unknown flags" {
    try std.testing.expectError(ConfigError.UnknownFlag, loadFromArgs(std.testing.allocator, &.{"--wat"}));
}

test "validates impossible config relationships" {
    var cfg = try defaults(std.testing.allocator, null);
    defer cfg.deinit(std.testing.allocator);
    cfg.network.tracker_retry_min_ms = 2;
    cfg.network.tracker_retry_max_ms = 1;
    try std.testing.expectError(ConfigError.InvalidConfig, validateDaemon(cfg));
}
