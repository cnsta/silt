const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const Entry = @import("Entry.zig");
const Category = @import("classify.zig").Category;

pub const Group = struct {
    /// Index of the first occurrence, the only one kept.
    first: u32,
    /// When the latest occurrence was logged.
    last_usec: u64,
    count: u32,
    cat: Category,
    /// `key` of its entries.
    key: u64,
    /// Nothing like it in the boots before (set by Model).
    new: bool = false,
};

/// Groups entries by `key`, in order of first appearance. Only the first
/// occurrence needs storing: later ones just bump `count` and `last_usec`, so a
/// flood costs one entry.
pub const Grouper = struct {
    seen: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    groups: std.ArrayList(Group) = .empty,

    pub fn deinit(g: *Grouper, gpa: Allocator) void {
        g.seen.deinit(gpa);
        g.groups.deinit(gpa);
    }

    /// True if `k` starts a new group, whose first occurrence is `index`.
    pub fn add(g: *Grouper, gpa: Allocator, k: u64, cat: Category, index: u32, usec: u64) Allocator.Error!bool {
        const gop = try g.seen.getOrPut(gpa, k);
        if (gop.found_existing) {
            const group = &g.groups.items[gop.value_ptr.*];
            group.last_usec = usec;
            group.count += 1;
            return false;
        }
        gop.value_ptr.* = @intCast(g.groups.items.len);
        try g.groups.append(gpa, .{ .first = index, .last_usec = usec, .count = 1, .cat = cat, .key = k });
        return true;
    }
};

/// Runs of hex digits containing a decimal digit (pids, addresses, counters) hash
/// as one placeholder, so "pid 12" and "pid 3456" match but "dead" stays a word.
pub fn key(e: *const Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.ident);
    h.update(&.{0});
    const m = e.message;
    var i: usize = 0;
    while (i < m.len) {
        if (!ascii.isHex(m[i])) {
            h.update(m[i .. i + 1]);
            i += 1;
            continue;
        }
        var j = i;
        var digit = false;
        while (j < m.len and ascii.isHex(m[j])) : (j += 1) digit = digit or ascii.isDigit(m[j]);
        h.update(if (digit) "#" else m[i..j]);
        i = j;
    }
    return h.final();
}

test key {
    const a: Entry = .{ .usec = 0, .ident = "kernel", .message = "pid 12 at 0x7ffe1234" };
    const b: Entry = .{ .usec = 0, .ident = "kernel", .message = "pid 3456 at 0x7f00aa99" };
    const c: Entry = .{ .usec = 0, .ident = "other", .message = "pid 12 at 0x7ffe1234" };
    const d: Entry = .{ .usec = 0, .ident = "kernel", .message = "dead beef" };
    const e: Entry = .{ .usec = 0, .ident = "kernel", .message = "face beef" };
    try std.testing.expectEqual(key(&a), key(&b));
    try std.testing.expect(key(&a) != key(&c));
    try std.testing.expect(key(&d) != key(&e));
}

test Grouper {
    const gpa = std.testing.allocator;
    var g: Grouper = .{};
    defer g.deinit(gpa);
    try std.testing.expect(try g.add(gpa, 7, .err, 0, 10));
    try std.testing.expect(try g.add(gpa, 8, .warn, 1, 11));
    try std.testing.expect(!try g.add(gpa, 7, .err, 99, 12));
    try std.testing.expectEqual(2, g.groups.items.len);
    try std.testing.expectEqual(Group{ .first = 0, .last_usec = 12, .count = 2, .cat = .err, .key = 7 }, g.groups.items[0]);
    try std.testing.expectEqual(1, g.groups.items[1].first);
}
