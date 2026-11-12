const std = @import("std");
const Allocator = std.mem.Allocator;

const Entry = @import("Entry.zig");
const Journal = @import("Journal.zig");
const classify = @import("classify.zig");
const dedup = @import("dedup.zig");
const ending = @import("ending.zig");

const Category = classify.Category;
const Model = @This();

/// How far back the Last tab reaches from the boot's final entry.
pub const tail_usec = 60 * std.time.us_per_s;

arena: std.heap.ArenaAllocator,
boot: Journal.Boot,
/// journalctl-style: 0 is the current boot, -1 the previous one.
offset: i32,
/// When the following boot started, if there is one.
next_first: ?u64,
entries: []Entry,
/// Per entry. Noise is reclassified as `.none`.
cats: []Category,
/// Deduplicated notable categories (no warnings).
notable: []dedup.Group,
/// Deduplicated everything that has a category, warnings included.
all: []dedup.Group,
/// Index of the first entry in the last `tail_usec`.
tail: usize,
end: ending.Ending,
/// Entries per category, after noise filtering.
counts: std.EnumArray(Category, u32),

pub fn load(gpa: Allocator, journal: Journal, boots: []const Journal.Boot, index: usize, keep_noise: bool) !Model {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const entries = try journal.entries(a, &boots[index]);
    const cats = try a.alloc(Category, entries.len);
    var counts: std.EnumArray(Category, u32) = .initFill(0);
    var notable: std.ArrayList(u32) = .empty;
    var all: std.ArrayList(u32) = .empty;
    for (entries, cats, 0..) |*e, *cat, i| {
        cat.* = classify.of(e);
        if (!keep_noise and classify.isNoise(e, cat.*)) cat.* = .none;
        counts.getPtr(cat.*).* += 1;
        if (cat.notable()) try notable.append(a, @intCast(i));
        if (cat.* != .none) try all.append(a, @intCast(i));
    }

    var tail = entries.len;
    if (entries.len > 0) {
        const cutoff = entries[entries.len - 1].usec -| tail_usec;
        while (tail > 0 and entries[tail - 1].usec >= cutoff) tail -= 1;
    }

    const last = boots.len - 1;
    return .{
        .arena = arena,
        .boot = boots[index],
        .offset = @as(i32, @intCast(index)) - @as(i32, @intCast(last)),
        .next_first = if (index < last) boots[index + 1].first else null,
        .entries = entries,
        .cats = cats,
        .notable = try dedup.group(a, entries, cats, notable.items),
        .all = try dedup.group(a, entries, cats, all.items),
        .tail = tail,
        .end = ending.analyze(entries, index == last),
        .counts = counts,
    };
}

pub fn deinit(self: *Model) void {
    self.arena.deinit();
}

/// Maps a journalctl-style offset (0, -1, ... or 1, 2, … from the oldest) to an index.
pub fn bootIndex(count: usize, offset: i32) ?usize {
    const n: i64 = @intCast(count);
    const i: i64 = if (offset <= 0) n - 1 + offset else offset - 1;
    if (i < 0 or i >= n) return null;
    return @intCast(i);
}

test bootIndex {
    try std.testing.expectEqual(4, bootIndex(5, 0));
    try std.testing.expectEqual(3, bootIndex(5, -1));
    try std.testing.expectEqual(0, bootIndex(5, 1));
    try std.testing.expectEqual(null, bootIndex(5, -5));
    try std.testing.expectEqual(null, bootIndex(5, 6));
    try std.testing.expectEqual(null, bootIndex(0, 0));
}
