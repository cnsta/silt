const std = @import("std");
const c = @import("c");

const mem = std.mem;
const Allocator = mem.Allocator;

const Entry = @import("Entry.zig");
const catalog = @import("classify.zig").id;
const classified_ids = @import("classify.zig").classified_ids;
const ending_ids = @import("ending.zig").ids;

const Journal = @This();

pub const Boot = struct {
    id: [32]u8,
    first: u64,
    last: u64,
    /// The boot's last entry is journald's "Journal stopped".
    clean: bool,
};

pub const Error = error{ JournalOpen, JournalRead, OutOfMemory };

j: *c.sd_journal,

pub fn open() Error!Journal {
    var j: ?*c.sd_journal = null;
    // The system journal plus the caller's user journal, like plain journalctl.
    if (c.sd_journal_open(&j, c.SD_JOURNAL_LOCAL_ONLY) < 0) return error.JournalOpen;
    return .{ .j = j.? };
}

pub fn close(self: Journal) void {
    c.sd_journal_close(self.j);
}

/// Every boot in the journal, oldest first. Caller owns the slice.
/// Walks boot to boot in journal order, as journalctl does, so the offsets match
/// `journalctl -b`. Sorting by wall-clock start would reorder boots after an
/// RTC jump.
pub fn boots(self: Journal, gpa: Allocator) Error![]Boot {
    var list: std.ArrayList(Boot) = .empty;
    errdefer list.deinit(gpa);

    if (c.sd_journal_seek_head(self.j) < 0) return error.JournalRead;
    if (c.sd_journal_next(self.j) <= 0) return list.toOwnedSlice(gpa);
    var id = self.bootId() orelse return error.JournalRead;
    while (true) {
        try self.matchBoot(id);
        const found = c.sd_journal_seek_head(self.j) >= 0 and c.sd_journal_next(self.j) > 0;
        const first = if (found) self.realtime() else null;
        const at_tail = c.sd_journal_seek_tail(self.j) >= 0 and c.sd_journal_previous(self.j) > 0;
        const last = if (at_tail) self.realtime() else null;
        const clean = at_tail and mem.eql(u8, self.field("MESSAGE_ID") orelse "", catalog.journal_stopped);
        var raw: [*c]u8 = null;
        if (at_tail and c.sd_journal_get_cursor(self.j, &raw) < 0) raw = null;
        defer c.free(raw);
        c.sd_journal_flush_matches(self.j);
        if (first == null or last == null or raw == null) return error.JournalRead;
        try list.append(gpa, .{ .id = id, .first = first.?, .last = last.?, .clean = clean });

        // The entry after this boot's last one, in journal order, starts the next boot.
        if (c.sd_journal_seek_cursor(self.j, raw) < 0 or c.sd_journal_next(self.j) <= 0) return error.JournalRead;
        id = while (c.sd_journal_next(self.j) > 0) {
            const next = self.bootId() orelse continue;
            if (!mem.eql(u8, &next, &id) and !self.seen(list.items, next)) break next;
        } else break;
    }
    return list.toOwnedSlice(gpa);
}

fn bootId(self: Journal) ?[32]u8 {
    const value = self.field("_BOOT_ID") orelse return null;
    if (value.len != 32) return null;
    return value[0..32].*;
}

fn seen(_: Journal, list: []const Boot, id: [32]u8) bool {
    for (list) |b| if (mem.eql(u8, &b.id, &id)) return true;
    return false;
}

pub const Scope = enum {
    all,
    /// Only what `classify.of` can give a category: warnings and worse, kernel
    /// lines and the catalog ids it knows. A fraction of a boot, and sd-journal
    /// finds it through its field index without visiting the rest.
    classified,
    /// `classified` plus the catalog ids `ending.Analyzer` reads.
    viewed,
};

/// Limits reading to `boot` and `scope` until the next `filter` or `unfilter`.
pub fn filter(self: Journal, boot: [32]u8, scope: Scope) Error!void {
    self.unfilter();
    try self.matchBoot(boot);
    if (scope == .all) return;
    // Same field: OR. Different fields: AND. So this is
    // (boot AND prio 0..4) OR (boot AND kernel) OR (boot AND one of the ids).
    inline for (.{ "0", "1", "2", "3", "4" }) |p| try self.match("PRIORITY=" ++ p);
    if (c.sd_journal_add_disjunction(self.j) < 0) return error.JournalRead;
    try self.matchBoot(boot);
    try self.match("_TRANSPORT=kernel");
    if (c.sd_journal_add_disjunction(self.j) < 0) return error.JournalRead;
    try self.matchBoot(boot);
    inline for (classified_ids) |id| try self.match("MESSAGE_ID=" ++ id);
    if (scope == .viewed) {
        inline for (ending_ids) |id| try self.match("MESSAGE_ID=" ++ id);
    }
}

pub fn unfilter(self: Journal) void {
    c.sd_journal_flush_matches(self.j);
}

pub const Position = union(enum) {
    head,
    tail,
    /// From `Entry.cursor`.
    cursor: [:0]const u8,
};

/// After this, `step` lands on the first (`.next`) or last (`.previous`)
/// matching entry. For a cursor that is the entry itself if it matches.
pub fn seek(self: Journal, pos: Position) Error!void {
    const rc = switch (pos) {
        .head => c.sd_journal_seek_head(self.j),
        .tail => c.sd_journal_seek_tail(self.j),
        .cursor => |s| c.sd_journal_seek_cursor(self.j, s.ptr),
    };
    if (rc < 0) return error.JournalRead;
}

pub const Direction = enum { next, previous };

/// False at the end.
pub fn step(self: Journal, dir: Direction) Error!bool {
    const rc = switch (dir) {
        .next => c.sd_journal_next(self.j),
        .previous => c.sd_journal_previous(self.j),
    };
    if (rc < 0) return error.JournalRead;
    return rc > 0;
}

/// The fields `entry` reads, in the order they're tried.
const Wanted = enum {
    PRIORITY,
    _TRANSPORT,
    SYSLOG_IDENTIFIER,
    _COMM,
    MESSAGE,
    UNIT,
    USER_UNIT,
    _SYSTEMD_USER_UNIT,
    _SYSTEMD_UNIT,
    MESSAGE_ID,
};

pub const Cursor = enum { without_cursor, with_cursor };

/// The current entry with its strings in `arena`. Null for an entry without a
/// timestamp. A cursor costs an allocation, so only ask when it's kept.
pub fn entry(self: Journal, arena: Allocator, want: Cursor) Error!?Entry {
    var e: Entry = .{ .usec = self.realtime() orelse return null };
    // One pass over the entry's fields: sd_journal_get_data scans (and
    // decompresses) them from the start for every name.
    var found: std.EnumArray(Wanted, ?[]const u8) = .initFill(null);
    c.sd_journal_restart_data(self.j);
    var data: ?*const anyopaque = null;
    var len: usize = 0;
    while (c.sd_journal_enumerate_available_data(self.j, &data, &len) > 0) {
        const bytes = @as([*]const u8, @ptrCast(data orelse continue))[0..len];
        const eq = mem.findScalar(u8, bytes, '=') orelse continue;
        const name = std.meta.stringToEnum(Wanted, bytes[0..eq]) orelse continue;
        // The first of a repeated field wins, as with get_data. Copy now: the
        // next call may reuse the buffer.
        if (found.get(name) == null) found.set(name, try arena.dupe(u8, bytes[eq + 1 ..]));
    }

    if (found.get(.PRIORITY)) |p| {
        if (p.len == 1 and p[0] >= '0' and p[0] <= '7') e.priority = @intCast(p[0] - '0');
    }
    e.kernel = mem.eql(u8, found.get(._TRANSPORT) orelse "", "kernel");
    e.ident = found.get(.SYSLOG_IDENTIFIER) orelse found.get(._COMM) orelse "";
    e.message = found.get(.MESSAGE) orelse "";
    if (found.get(.UNIT)) |u| {
        e.unit = u;
    } else if (found.get(.USER_UNIT) orelse found.get(._SYSTEMD_USER_UNIT)) |u| {
        e.unit = u;
        e.user_unit = true;
    } else {
        e.unit = found.get(._SYSTEMD_UNIT) orelse "";
    }
    e.message_id = found.get(.MESSAGE_ID) orelse "";
    if (want == .with_cursor) e.cursor = try self.cursor(arena);
    return e;
}

pub fn cursor(self: Journal, arena: Allocator) Error![:0]const u8 {
    var raw: [*c]u8 = null;
    if (c.sd_journal_get_cursor(self.j, &raw) < 0) return error.JournalRead;
    defer c.free(raw);
    return arena.dupeSentinel(u8, mem.span(raw), 0);
}

/// The current entry is the one `cursor` names.
pub fn at(self: Journal, cur: [:0]const u8) bool {
    return c.sd_journal_test_cursor(self.j, cur.ptr) > 0;
}

pub const Window = struct {
    entries: []Entry,
    /// Index of the entry the window was opened at.
    focus: usize,
    /// Nothing before or after the window in this boot.
    at_head: bool,
    at_tail: bool,
};

/// Up to `span` entries of `boot` on each side of `pos`, oldest first.
pub fn around(self: Journal, arena: Allocator, boot: [32]u8, pos: Position, span: usize) Error!Window {
    try self.filter(boot, .all);
    defer self.unfilter();

    try self.seek(pos);
    const anchor = while (try self.step(if (pos == .tail) .previous else .next)) {
        if (try self.entry(arena, .with_cursor)) |e| break e;
    } else return .{ .entries = &.{}, .focus = 0, .at_head = true, .at_tail = true };

    var after: std.ArrayList(Entry) = .empty;
    while (after.items.len < span and try self.step(.next)) {
        if (try self.entry(arena, .with_cursor)) |e| try after.append(arena, e);
    }
    const at_tail = after.items.len < span;

    // Back to the anchor. A cursor seek is inclusive, so skip the anchor itself.
    try self.seek(.{ .cursor = anchor.cursor });
    var before: std.ArrayList(Entry) = .empty;
    while (before.items.len < span and try self.step(.previous)) {
        if (self.at(anchor.cursor)) continue;
        if (try self.entry(arena, .with_cursor)) |e| try before.append(arena, e);
    }
    const at_head = before.items.len < span;

    const all = try arena.alloc(Entry, before.items.len + 1 + after.items.len);
    for (before.items, 0..) |e, i| all[before.items.len - 1 - i] = e;
    all[before.items.len] = anchor;
    @memcpy(all[before.items.len + 1 ..], after.items);
    return .{ .entries = all, .focus = before.items.len, .at_head = at_head, .at_tail = at_tail };
}

fn matchBoot(self: Journal, id: [32]u8) Error!void {
    const prefix = "_BOOT_ID=";
    var buf: [prefix.len + 32]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], &id);
    if (c.sd_journal_add_match(self.j, &buf, buf.len) < 0) return error.JournalRead;
}

fn match(self: Journal, comptime expr: []const u8) Error!void {
    if (c.sd_journal_add_match(self.j, expr.ptr, expr.len) < 0) return error.JournalRead;
}

fn realtime(self: Journal) ?u64 {
    var usec: u64 = 0;
    if (c.sd_journal_get_realtime_usec(self.j, &usec) < 0) return null;
    return usec;
}

/// The value of `name` in the current entry. Valid until the next sd-journal call.
fn field(self: Journal, comptime name: [:0]const u8) ?[]const u8 {
    var data: ?*const anyopaque = null;
    var len: usize = 0;
    if (c.sd_journal_get_data(self.j, name.ptr, &data, &len) < 0) return null;
    return fieldValue(data, len, name);
}

/// sd-journal hands out "NAME=value", strip the name.
fn fieldValue(data: ?*const anyopaque, len: usize, name: []const u8) ?[]const u8 {
    const bytes = @as([*]const u8, @ptrCast(data orelse return null))[0..len];
    if (bytes.len <= name.len or !mem.startsWith(u8, bytes, name) or bytes[name.len] != '=') return null;
    return bytes[name.len + 1 ..];
}

test fieldValue {
    const raw = "MESSAGE=hello";
    try std.testing.expectEqualStrings("hello", fieldValue(raw, raw.len, "MESSAGE").?);
    try std.testing.expect(fieldValue(raw, raw.len, "MESSAGE_ID") == null);
    try std.testing.expect(fieldValue(raw, raw.len, "MESS") == null);
}
