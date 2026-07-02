const std = @import("std");

pub const ParseError = error{
    UnexpectedEnd,
    InvalidInteger,
    InvalidStringLength,
    InvalidToken,
    TrailingData,
    NonStringDictionaryKey,
};

pub const Pair = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    int: i64,
    string: []const u8,
    list: []Value,
    dict: Dict,

    pub const Dict = struct {
        pairs: []Pair,
        raw: []const u8,
    };

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .list => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .dict => |dict| {
                for (dict.pairs) |pair| pair.value.deinit(allocator);
                allocator.free(dict.pairs);
            },
            else => {},
        }
    }

    pub fn dictGet(self: Value, key: []const u8) ?Value {
        if (self != .dict) return null;
        for (self.dict.pairs) |pair| {
            if (std.mem.eql(u8, pair.key, key)) return pair.value;
        }
        return null;
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Value {
    var parser = Parser{ .allocator = allocator, .input = input };
    const value = try parser.value();
    errdefer value.deinit(allocator);
    if (parser.pos != input.len) return ParseError.TrailingData;
    return value;
}

pub fn parsePrefix(allocator: std.mem.Allocator, input: []const u8) !struct { value: Value, consumed: usize } {
    var parser = Parser{ .allocator = allocator, .input = input };
    const value = try parser.value();
    return .{ .value = value, .consumed = parser.pos };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn value(self: *Parser) anyerror!Value {
        if (self.pos >= self.input.len) return ParseError.UnexpectedEnd;
        return switch (self.input[self.pos]) {
            'i' => self.integer(),
            'l' => self.list(),
            'd' => self.dict(),
            '0'...'9' => self.string(),
            else => ParseError.InvalidToken,
        };
    }

    fn integer(self: *Parser) !Value {
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != 'e') self.pos += 1;
        if (self.pos >= self.input.len) return ParseError.UnexpectedEnd;
        const digits = self.input[start..self.pos];
        self.pos += 1;
        if (digits.len == 0) return ParseError.InvalidInteger;
        return .{ .int = std.fmt.parseInt(i64, digits, 10) catch return ParseError.InvalidInteger };
    }

    fn string(self: *Parser) !Value {
        const len_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != ':') {
            if (self.input[self.pos] < '0' or self.input[self.pos] > '9') return ParseError.InvalidStringLength;
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return ParseError.UnexpectedEnd;
        const len_digits = self.input[len_start..self.pos];
        self.pos += 1;
        const len = std.fmt.parseInt(usize, len_digits, 10) catch return ParseError.InvalidStringLength;
        if (self.pos + len > self.input.len) return ParseError.UnexpectedEnd;
        const bytes = self.input[self.pos .. self.pos + len];
        self.pos += len;
        return .{ .string = bytes };
    }

    fn list(self: *Parser) !Value {
        self.pos += 1;
        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (true) {
            if (self.pos >= self.input.len) return ParseError.UnexpectedEnd;
            if (self.input[self.pos] == 'e') {
                self.pos += 1;
                return .{ .list = try items.toOwnedSlice(self.allocator) };
            }
            try items.append(self.allocator, try self.value());
        }
    }

    fn dict(self: *Parser) !Value {
        const start = self.pos;
        self.pos += 1;
        var pairs: std.ArrayList(Pair) = .empty;
        errdefer {
            for (pairs.items) |pair| pair.value.deinit(self.allocator);
            pairs.deinit(self.allocator);
        }
        while (true) {
            if (self.pos >= self.input.len) return ParseError.UnexpectedEnd;
            if (self.input[self.pos] == 'e') {
                self.pos += 1;
                return .{ .dict = .{ .pairs = try pairs.toOwnedSlice(self.allocator), .raw = self.input[start..self.pos] } };
            }
            const key_value = try self.string();
            const key = switch (key_value) {
                .string => |s| s,
                else => return ParseError.NonStringDictionaryKey,
            };
            try pairs.append(self.allocator, .{ .key = key, .value = try self.value() });
        }
    }
};

test "parses nested dictionaries" {
    const value = try parse(std.testing.allocator, "d3:cow3:moo4:spamli1ei2eee");
    defer value.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("moo", value.dictGet("cow").?.string);
    try std.testing.expectEqual(@as(i64, 2), value.dictGet("spam").?.list[1].int);
}

test "rejects trailing data" {
    try std.testing.expectError(ParseError.TrailingData, parse(std.testing.allocator, "i1ee"));
}

test "parsePrefix allows trailing data" {
    const parsed = try parsePrefix(std.testing.allocator, "d8:msg_typei1e5:piecei0eehello");
    defer parsed.value.deinit(std.testing.allocator);
    try std.testing.expect(parsed.value == .dict);
    try std.testing.expectEqual(@as(usize, 25), parsed.consumed);
    try std.testing.expectEqualStrings("hello", "d8:msg_typei1e5:piecei0eehello"[parsed.consumed..]);
}
