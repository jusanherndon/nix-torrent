const std = @import("std");

pub const Config = struct {
    staging_area: []const u8,
    final_destination: []const u8,
    socket_path: []const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.staging_area);
        allocator.free(self.final_destination);
        allocator.free(self.socket_path);
    }
};

pub const ConfigError = error{
    MissingFlagValue,
    UnknownFlag,
};

pub fn load(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    return loadFromArgs(allocator, args[1..]);
}

pub fn loadFromArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var config = Config{
        .staging_area = try envOrDefaultPath(allocator, "NIX_TORRENT_STAGING_AREA", &.{ "nix-torrent", "staging" }, .state),
        .final_destination = try envOrDefaultPath(allocator, "NIX_TORRENT_FINAL_DESTINATION", &.{ "Downloads", "nix-torrent" }, .home),
        .socket_path = try envOrDefaultPath(allocator, "NIX_TORRENT_SOCKET_PATH", &.{"nix-torrent.sock"}, .runtime),
    };
    errdefer config.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--staging-area")) {
            const value = try nextValue(args, &i);
            config.staging_area = try replaceValue(allocator, config.staging_area, value);
        } else if (std.mem.eql(u8, arg, "--final-destination")) {
            const value = try nextValue(args, &i);
            config.final_destination = try replaceValue(allocator, config.final_destination, value);
        } else if (std.mem.eql(u8, arg, "--socket-path")) {
            const value = try nextValue(args, &i);
            config.socket_path = try replaceValue(allocator, config.socket_path, value);
        } else {
            return ConfigError.UnknownFlag;
        }
    }

    return config;
}

pub fn usage(program_name: []const u8, writer: anytype) !void {
    try writer.print(
        \\Usage: {s} [options]
        \\
        \\Options:
        \\  --staging-area PATH       Client-owned incomplete content directory
        \\  --final-destination PATH  Completed-content handoff directory
        \\  --socket-path PATH        Unix domain socket path for daemon control
        \\
        \\Environment:
        \\  NIX_TORRENT_STAGING_AREA
        \\  NIX_TORRENT_FINAL_DESTINATION
        \\  NIX_TORRENT_SOCKET_PATH
        \\
    , .{program_name});
}

fn nextValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return ConfigError.MissingFlagValue;
    return args[index.*];
}

fn replaceValue(allocator: std.mem.Allocator, old_value: []const u8, new_value: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, new_value);
    allocator.free(old_value);
    return owned;
}

const Base = enum { home, state, runtime };

fn envOrDefaultPath(allocator: std.mem.Allocator, env_name: []const u8, tail: []const []const u8, base: Base) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, env_name)) |value| {
        return value;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const root = try defaultRoot(allocator, base);
    defer allocator.free(root);

    var parts = try allocator.alloc([]const u8, tail.len + 1);
    defer allocator.free(parts);
    parts[0] = root;
    @memcpy(parts[1..], tail);

    return std.fs.path.join(allocator, parts);
}

fn defaultRoot(allocator: std.mem.Allocator, base: Base) ![]const u8 {
    switch (base) {
        .runtime => {
            if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |value| {
                return value;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => return allocator.dupe(u8, "/tmp"),
                else => return err,
            }
        },
        .state => {
            if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |value| {
                return value;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {},
                else => return err,
            }
            const home = try homeDir(allocator);
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".local", "state" });
        },
        .home => return homeDir(allocator),
    }
}

fn homeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |value| {
        return value;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, "."),
        else => return err,
    }
}

test "loads explicit paths from flags" {
    const cfg = try loadFromArgs(std.testing.allocator, &.{
        "--staging-area", "var/staging",
        "--final-destination", "srv/downloads",
        "--socket-path", "run/nix-torrent.sock",
    });
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("var/staging", cfg.staging_area);
    try std.testing.expectEqualStrings("srv/downloads", cfg.final_destination);
    try std.testing.expectEqualStrings("run/nix-torrent.sock", cfg.socket_path);
}

test "rejects unknown flags" {
    try std.testing.expectError(ConfigError.UnknownFlag, loadFromArgs(std.testing.allocator, &.{"--wat"}));
}
