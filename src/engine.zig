const std = @import("std");
const storage = @import("storage.zig");

pub const Request = struct { piece_index: usize, started_at_ms: i64 };

pub const Scheduler = struct {
    layout: *storage.Layout,
    inflight: std.AutoHashMap(usize, Request),
    timeout_ms: i64 = 30_000,

    pub fn init(allocator: std.mem.Allocator, layout: *storage.Layout) Scheduler {
        return .{ .layout = layout, .inflight = std.AutoHashMap(usize, Request).init(allocator) };
    }

    pub fn deinit(self: *Scheduler) void { self.inflight.deinit(); }

    pub fn nextSequential(self: *Scheduler, now_ms: i64) !?usize {
        for (self.layout.piece_states, 0..) |state, i| {
            if (state == .missing and !self.inflight.contains(i)) {
                try self.inflight.put(i, .{ .piece_index = i, .started_at_ms = now_ms });
                self.layout.mark(i, .in_progress);
                return i;
            }
        }
        return null;
    }

    pub fn completePiece(self: *Scheduler, piece_index: usize, verified: bool) void {
        _ = self.inflight.remove(piece_index);
        self.layout.mark(piece_index, if (verified) .verified else .missing);
    }

    pub fn recoverTimedOut(self: *Scheduler, now_ms: i64) void {
        var it = self.inflight.iterator();
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.started_at_ms >= self.timeout_ms) {
                self.layout.mark(entry.key_ptr.*, .missing);
            }
        }
        it = self.inflight.iterator();
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.started_at_ms >= self.timeout_ms) _ = self.inflight.remove(entry.key_ptr.*);
        }
    }

    pub fn isComplete(self: Scheduler) bool { return self.layout.complete(); }
};

test "selects pieces sequentially without duplicate in-flight requests" {
    var states = [_]storage.PieceState{ .missing, .missing };
    var lengths = [_]u64{8};
    var layout = storage.Layout{ .allocator = std.testing.allocator, .file_lengths = &lengths, .piece_length = 4, .total_length = 8, .piece_states = &states };
    var scheduler = Scheduler.init(std.testing.allocator, &layout);
    defer scheduler.deinit();
    try std.testing.expectEqual(@as(?usize, 0), try scheduler.nextSequential(0));
    try std.testing.expectEqual(@as(?usize, 1), try scheduler.nextSequential(1));
    try std.testing.expectEqual(@as(?usize, null), try scheduler.nextSequential(2));
}

test "recovers timed out pieces and completes verified pieces" {
    var states = [_]storage.PieceState{ .missing };
    var lengths = [_]u64{4};
    var layout = storage.Layout{ .allocator = std.testing.allocator, .file_lengths = &lengths, .piece_length = 4, .total_length = 4, .piece_states = &states };
    var scheduler = Scheduler.init(std.testing.allocator, &layout);
    defer scheduler.deinit();
    _ = try scheduler.nextSequential(0);
    scheduler.recoverTimedOut(30_000);
    try std.testing.expectEqual(storage.PieceState.missing, states[0]);
    _ = try scheduler.nextSequential(31_000);
    scheduler.completePiece(0, true);
    try std.testing.expect(scheduler.isComplete());
}
