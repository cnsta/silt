const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const Entry = @import("Entry.zig");
const Category = @import("classify.zig").Category;

pub const Group = struct {
    first: u32,
    last: u32,
    count: u32,
    cat: Category,
    /// `key` of its entries.
    key: u64,
    /// Nothing like it in the boots before (set by Model).
    new: bool = false,
};

/// Groups indices (ascending) by identifier plus message with numbers masked,
/// in order of first appearance.
pub fn group(gpa: Allocator, entries: []const Entry, cats: []const Category, indices: []const u32) Allocator.Error![]Group {
    var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer seen.deinit(gpa);
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(gpa);
    for (indices) |i| {
        const k = key(&entries[i]);
        const gop = try seen.getOrPut(gpa, k);
        if (gop.found_existing) {
            const g = &groups.items[gop.value_ptr.*];
            g.last = i;
            g.count += 1;
        } else {
            gop.value_ptr.* = @intCast(groups.items.len);
            try groups.append(gpa, .{ .first = i, .last = i, .count = 1, .cat = cats[i], .key = k });
        }
    }
    return groups.toOwnedSlice(gpa);
}

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

test group {
    const gpa = std.testing.allocator;
    const entries = [_]Entry{
        .{ .usec = 0, .ident = "x", .message = "retry 1" },
        .{ .usec = 1, .ident = "y", .message = "other" },
        .{ .usec = 2, .ident = "x", .message = "retry 2" },
    };
    const cats = [_]Category{ .err, .warn, .err };
    const groups = try group(gpa, &entries, &cats, &.{ 0, 1, 2 });
    defer gpa.free(groups);
    try std.testing.expectEqual(2, groups.len);
    try std.testing.expectEqual(Group{ .first = 0, .last = 2, .count = 2, .cat = .err, .key = key(&entries[0]) }, groups[0]);
    try std.testing.expectEqual(1, groups[1].first);
}
