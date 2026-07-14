//! Non-blocking control plane (V3 Milestone 8).
//!
//! The engine runs on a dedicated worker thread. Mutating control commands
//! (add / pause / resume / remove) are enqueued and wait for a worker ack;
//! `status` / `show` / `list` read only the Registry Projection under a short
//! `projection` mutex and never run peer/tracker I/O on the accept loop.
//!
//! See docs/adr/0006-control-plane-worker.md.

const std = @import("std");

pub const MutateKind = enum { add, pause, @"resume", remove };

/// Opaque handled by the daemon's worker callback that builds a protocol.Response.
pub const ResponseSlot = struct {
    /// Set by the worker to an owned `protocol.Response` pointer boxed with the
    /// daemon allocator, or left null on enqueue failure. The control thread
    //  takes ownership after the Event is set.
    ptr: ?*anyopaque = null,
};

pub const MutateCmd = struct {
    kind: MutateKind,
    /// Owned by the command; freed by the worker after handling.
    argument: []u8,
    done: *std.Io.Event,
    result: *ResponseSlot,
};

/// Short-hold mutex around registry projection publish and control reads.
pub const ProjectionGate = struct {
    mutex: std.Io.Mutex = .init,

    pub fn lock(self: *ProjectionGate, io: std.Io) void {
        self.mutex.lockUncancelable(io);
    }

    pub fn unlock(self: *ProjectionGate, io: std.Io) void {
        self.mutex.unlock(io);
    }
};

pub const CommandQueue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    cmds: std.ArrayList(MutateCmd) = .empty,
    allocator: std.mem.Allocator,
    shutdown: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator) CommandQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        for (self.cmds.items) |cmd| {
            self.allocator.free(cmd.argument);
            cmd.done.set(io);
        }
        self.cmds.deinit(self.allocator);
        self.mutex.unlock(io);
    }

    pub fn requestShutdown(self: *CommandQueue, io: std.Io) void {
        self.shutdown.store(true, .release);
        self.cond.signal(io);
    }

    pub fn enqueue(self: *CommandQueue, io: std.Io, cmd: MutateCmd) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.shutdown.load(.acquire)) return error.ShuttingDown;
        try self.cmds.append(self.allocator, cmd);
        self.cond.signal(io);
    }

    /// Wait up to `timeout_ns` for a command. Returns null on timeout or empty queue.
    pub fn waitNext(self: *CommandQueue, io: std.Io, timeout_ns: u64) ?MutateCmd {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.cmds.items.len == 0 and !self.shutdown.load(.acquire)) {
            self.mutex.unlock(io);
            std.Io.sleep(io, .fromNanoseconds(@intCast(timeout_ns)), .real) catch {};
            self.mutex.lockUncancelable(io);
        }
        if (self.cmds.items.len == 0) return null;
        return self.cmds.orderedRemove(0);
    }

    pub fn isShutdown(self: *const CommandQueue) bool {
        return self.shutdown.load(.acquire);
    }
};

test "command queue delivers and drains" {
    const io = std.testing.io;
    var q = CommandQueue.init(std.testing.allocator);
    defer q.deinit(io);
    var done: std.Io.Event = .unset;
    var slot: ResponseSlot = .{};
    const arg = try std.testing.allocator.dupe(u8, "deadbeef");
    try q.enqueue(io, .{ .kind = .pause, .argument = arg, .done = &done, .result = &slot });
    const cmd = q.waitNext(io, 1 * std.time.ns_per_ms) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(MutateKind.pause, cmd.kind);
    try std.testing.expectEqualStrings("deadbeef", cmd.argument);
    std.testing.allocator.free(cmd.argument);
    cmd.done.set(io);
}

test "projection gate serializes readers" {
    const io = std.testing.io;
    var gate: ProjectionGate = .{};
    gate.lock(io);
    gate.unlock(io);
}
