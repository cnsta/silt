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
/// How many earlier boots the groups' `new` flags were compared against. 0 when
/// there are none or `Options.history` is 0: nothing is marked new then.
compared: u32,
/// Notable groups that are new.
new_notable: u32,

pub const Options = struct {
    /// Keep what `classify.isNoise` would hide.
    keep_noise: bool = false,
    /// A group is new if nothing like it was logged in this many earlier boots.
    history: u32 = default_history,
};

pub const default_history = 5;

pub fn load(gpa: Allocator, journal: Journal, boots: []const Journal.Boot, index: usize, options: Options) !Model {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const keep_noise = options.keep_noise;

    // What the earlier boots complained about, as dedup keys.
    var known: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer known.deinit(gpa);
    const compared: u32 = @intCast(@min(index, options.history));
    {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        for (boots[index - compared .. index]) |*boot| {
            for (try journal.entries(scratch.allocator(), boot, .classified)) |*e| {
                if (classify.of(e) != .none) try known.put(gpa, dedup.key(e), {});
            }
            _ = scratch.reset(.retain_capacity);
        }
    }

    const entries = try journal.entries(a, &boots[index], .all);
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

    const notable_groups = try dedup.group(a, entries, cats, notable.items);
    const all_groups = try dedup.group(a, entries, cats, all.items);
    var new_notable: u32 = 0;
    if (compared > 0) {
        for (notable_groups) |*g| {
            g.new = !known.contains(g.key);
            if (g.new) new_notable += 1;
        }
        for (all_groups) |*g| g.new = !known.contains(g.key);
    }

    const last = boots.len - 1;
    return .{
        .arena = arena,
        .boot = boots[index],
        .offset = @as(i32, @intCast(index)) - @as(i32, @intCast(last)),
        .next_first = if (index < last) boots[index + 1].first else null,
        .entries = entries,
        .cats = cats,
        .notable = notable_groups,
        .all = all_groups,
        .tail = tail,
        .end = ending.analyze(entries, index == last),
        .counts = counts,
        .compared = compared,
        .new_notable = new_notable,
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
