const std = @import("std");
const Allocator = std.mem.Allocator;

const Entry = @import("Entry.zig");
const Cache = @import("cache.zig");
const Journal = @import("Journal.zig");
const Progress = @import("Progress.zig");
const classify = @import("classify.zig");
const dedup = @import("dedup.zig");
const ending = @import("ending.zig");

const Category = classify.Category;
const Model = @This();

/// How far back the Last tab reaches from the boot's final entry.
pub const tail_usec = 60 * std.time.us_per_s;
/// And at most this many entries of it, should something flood.
pub const tail_max = 10_000;

arena: std.heap.ArenaAllocator,
boot: Journal.Boot,
/// journalctl-style: 0 is the current boot, -1 the previous one.
offset: i32,
/// When the following boot started, if there is one.
next_first: ?u64,
/// What the views show, not the whole boot: the first entry of each group,
/// then the Last tab's entries from `tail` on.
entries: []Entry,
/// Per entry. Noise is reclassified as `.none`.
cats: []Category,
/// Deduplicated notable categories (no warnings).
notable: []dedup.Group,
/// Deduplicated everything that has a category, warnings included.
all: []dedup.Group,
/// Index of the first entry in the last `tail_usec` (at most `tail_max`).
tail: usize,
end: ending.Ending,
/// Entries per category, after noise filtering. Exact, unlike `entries`.
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

/// `cache` holds earlier boots' keys; null reads them from the journal every time.
/// `progress` is ticked per entry read.
pub fn load(gpa: Allocator, journal: Journal, cache: ?Cache, progress: ?*Progress, boots: []const Journal.Boot, index: usize, options: Options) !Model {
    const last = boots.len - 1;
    const offsetOf = struct {
        fn f(i: usize, n: usize) i64 {
            return @as(i64, @intCast(i)) - @as(i64, @intCast(n - 1));
        }
    }.f;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Strings of entries that are looked at and dropped.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    defer journal.unfilter();

    // What the earlier boots complained about, as dedup keys.
    var known: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer known.deinit(gpa);
    const compared: u32 = @intCast(@min(index, options.history));
    var keys: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    defer keys.deinit(gpa);
    for (boots[index - compared .. index], index - compared..) |*boot, bi| {
        if (cache) |cc| if (try cc.load(gpa, boot, &known)) continue;
        keys.clearRetainingCapacity();
        if (progress) |p| p.phase("comparing with boot {d}{s}", .{ offsetOf(bi, boots.len), if (cache != null) " (cached after this)" else "" });
        try journal.filter(boot.id, .classified);
        try journal.seek(.head);
        while (try journal.step(.next)) {
            _ = scratch.reset(.retain_capacity);
            if (progress) |p| p.tick();
            const e = try journal.entry(scratch.allocator(), .without_cursor) orelse continue;
            if (classify.of(&e) != .none) try keys.put(gpa, dedup.key(&e), {});
        }
        // Earlier boots are finished, so this is final.
        if (cache) |cc| cc.store(gpa, boot, keys.keys());
        try known.ensureUnusedCapacity(gpa, @intCast(keys.count()));
        for (keys.keys()) |k| known.putAssumeCapacity(k, {});
    }

    const boot = &boots[index];

    // The Last tab: every entry of the final `tail_usec`, read backwards.
    var tail_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tail_arena.deinit();
    var tail: std.ArrayList(Entry) = .empty;
    if (progress) |p| p.phase("reading boot {d}", .{offsetOf(index, boots.len)});
    try journal.filter(boot.id, .all);
    try journal.seek(.tail);
    var cutoff: ?u64 = null;
    while (tail.items.len < tail_max and try journal.step(.previous)) {
        if (progress) |p| p.tick();
        const e = try journal.entry(tail_arena.allocator(), .with_cursor) orelse continue;
        cutoff = cutoff orelse e.usec -| tail_usec;
        if (e.usec < cutoff.?) break;
        try tail.append(tail_arena.allocator(), e);
    }
    std.mem.reverse(Entry, tail.items);

    // Before it only what can matter: everything classified, plus what the
    // ending is read from. The millions of routine lines a busy server logs
    // are never visited; the detail view reads them around an entry on demand.
    var b: Builder = .{ .arena = a, .keep_noise = options.keep_noise };
    try journal.filter(boot.id, .viewed);
    // The last such entry before the tail, to stop at.
    var stop: ?Entry = null;
    if (tail.items.len > 0) {
        const start = tail.items[0].cursor;
        try journal.seek(.{ .cursor = start });
        while (try journal.step(.previous)) {
            if (journal.at(start)) continue;
            stop = try journal.entry(a, .with_cursor) orelse continue;
            break;
        }
    }
    if (stop != null or tail.items.len == 0) {
        try journal.seek(.head);
        while (try journal.step(.next)) {
            _ = scratch.reset(.retain_capacity);
            if (progress) |p| p.tick();
            const e = try journal.entry(scratch.allocator(), .without_cursor) orelse continue;
            // Stored entries need their place for the detail view.
            if (try b.add(&e, false)) |kept| kept.cursor = try journal.cursor(a);
            if (stop) |s| if (e.usec == s.usec and journal.at(s.cursor)) break;
        }
    }
    const tail_start: usize = b.entries.items.len;
    for (tail.items) |*e| _ = try b.add(e, true);

    var new_notable: u32 = 0;
    if (compared > 0) {
        for (b.notable.groups.items) |*g| {
            g.new = !known.contains(g.key);
            if (g.new) new_notable += 1;
        }
        for (b.all.groups.items) |*g| g.new = !known.contains(g.key);
    }

    return .{
        .arena = arena,
        .boot = boots[index],
        .offset = @as(i32, @intCast(index)) - @as(i32, @intCast(last)),
        .next_first = if (index < last) boots[index + 1].first else null,
        .entries = b.entries.items,
        .cats = b.cats.items,
        .notable = b.notable.groups.items,
        .all = b.all.groups.items,
        .tail = tail_start,
        .end = b.ending.finish(index == last),
        .counts = b.counts,
        .compared = compared,
        .new_notable = new_notable,
    };
}

/// `classify.of`, with noise reclassified as `.none` unless it's kept.
pub fn categorize(e: *const Entry, keep_noise: bool) Category {
    const cat = classify.of(e);
    return if (!keep_noise and classify.isNoise(e, cat)) .none else cat;
}

/// Collects a boot's entries in journal order. Everything is counted, grouped
/// and fed to the ending; only what the views show is stored: each group's
/// first occurrence and the forced (tail) entries.
const Builder = struct {
    arena: Allocator,
    keep_noise: bool,
    entries: std.ArrayList(Entry) = .empty,
    cats: std.ArrayList(Category) = .empty,
    notable: dedup.Grouper = .{},
    all: dedup.Grouper = .{},
    counts: std.EnumArray(Category, u32) = .initFill(0),
    ending: ending.Analyzer = .{},

    /// The stored copy, if `e` was kept.
    fn add(b: *Builder, e: *const Entry, force: bool) Allocator.Error!?*Entry {
        const cat = categorize(e, b.keep_noise);
        b.counts.getPtr(cat).* += 1;
        b.ending.feed(e);
        var keep = force;
        if (cat != .none) {
            const k = dedup.key(e);
            const index: u32 = @intCast(b.entries.items.len);
            // Both, no short-circuit: each grouper counts every occurrence.
            const new_all = try b.all.add(b.arena, k, cat, index, e.usec);
            const new_notable = cat.notable() and try b.notable.add(b.arena, k, cat, index, e.usec);
            keep = keep or new_all or new_notable;
        }
        if (!keep) return null;
        try b.entries.append(b.arena, try e.dupe(b.arena));
        try b.cats.append(b.arena, cat);
        return &b.entries.items[b.entries.items.len - 1];
    }
};

test Builder {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var b: Builder = .{ .arena = arena.allocator(), .keep_noise = false };
    const flood: Entry = .{ .usec = 1, .priority = 3, .ident = "x", .message = "retry 1" };
    _ = try b.add(&flood, false);
    for (2..1000) |i| {
        var e = flood;
        e.usec = i;
        try std.testing.expect(try b.add(&e, false) == null);
    }
    _ = try b.add(&.{ .usec = 1000, .ident = "x", .message = "routine" }, false);
    _ = try b.add(&.{ .usec = 1001, .priority = 3, .ident = "x", .message = "retry 1001" }, true);
    _ = try b.add(&.{ .usec = 1002, .message_id = classify.id.journal_stopped }, false);

    // The flood is one stored entry, the routine line none; the forced one stays.
    try std.testing.expectEqual(2, b.entries.items.len);
    try std.testing.expectEqual(1000, b.counts.get(.err));
    try std.testing.expectEqual(1, b.all.groups.items.len);
    const g = b.notable.groups.items[0];
    try std.testing.expectEqual(1000, g.count);
    try std.testing.expectEqual(1001, g.last_usec);
    try std.testing.expectEqual(0, g.first);
    try std.testing.expectEqual(.shutdown, b.ending.finish(false).kind);
    try std.testing.expectEqual(1002, b.ending.finish(false).last);
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
