const std = @import("std");
const unicode = std.unicode;
const Writer = std.Io.Writer;

const Entry = @import("Entry.zig");
const Model = @import("Model.zig");
pub const Category = @import("classify.zig").Category;
const dedup = @import("dedup.zig");
const pstore = @import("pstore.zig");
const timefmt = @import("timefmt.zig");

pub const color = struct {
    pub const base03: u24 = 0x002b36;
    pub const base02: u24 = 0x073642;
    pub const base01: u24 = 0x586e75;
    pub const base00: u24 = 0x657b83;
    pub const base0: u24 = 0x839496;
    pub const base1: u24 = 0x93a1a1;
    pub const yellow: u24 = 0xb58900;
    pub const orange: u24 = 0xcb4b16;
    pub const red: u24 = 0xdc322f;
    pub const magenta: u24 = 0xd33682;
    pub const violet: u24 = 0x6c71c4;
    pub const blue: u24 = 0x268bd2;
    pub const cyan: u24 = 0x2aa198;
    pub const green: u24 = 0x859900;

    /// The "+" of a group that is new in this boot.
    pub const new = yellow;

    pub fn of(cat: Category) u24 {
        return switch (cat) {
            .kernel => red,
            .hardware => magenta,
            .oom => orange,
            .crash => violet,
            .gpu => yellow,
            .unit => blue,
            .err => cyan,
            .warn => base00,
            .none => base0,
        };
    }

    pub fn priority(p: u3) u24 {
        return switch (p) {
            0...2 => red,
            3 => orange,
            4 => yellow,
            5 => base1,
            6 => base0,
            7 => base01,
        };
    }
};

/// One output line, cut at `width` columns. Control characters become spaces.
pub const Line = struct {
    w: *Writer,
    width: usize,
    colored: bool,
    used: usize = 0,
    background: ?u24 = null,

    pub fn fg(l: *Line, rgb: u24) Writer.Error!void {
        if (l.colored) try l.w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb >> 16, (rgb >> 8) & 0xff, rgb & 0xff });
    }

    pub fn bg(l: *Line, rgb: u24) Writer.Error!void {
        l.background = rgb;
        if (l.colored) try l.w.print("\x1b[48;2;{d};{d};{d}m", .{ rgb >> 16, (rgb >> 8) & 0xff, rgb & 0xff });
    }

    pub fn bold(l: *Line) Writer.Error!void {
        if (l.colored) try l.w.writeAll("\x1b[1m");
    }

    /// Drops colors and bold, keeping the line's background.
    pub fn reset(l: *Line) Writer.Error!void {
        if (!l.colored) return;
        try l.w.writeAll("\x1b[0m");
        if (l.background) |rgb| try l.bg(rgb);
    }

    pub fn text(l: *Line, s: []const u8) Writer.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            const g = glyph(s[i..]);
            if (l.used + g.cols > l.width) {
                // Half a wide character left: blank it so later text can't use it.
                try l.padTo(l.width);
                break;
            }
            switch (g.out) {
                .keep => try l.w.writeAll(s[i..][0..g.len]),
                .byte => |b| try l.w.writeByte(b),
                .drop => {},
            }
            i += g.len;
            l.used += g.cols;
        }
    }

    pub fn print(l: *Line, comptime fmt: []const u8, args: anytype) Writer.Error!void {
        var buf: [256]u8 = undefined;
        try l.text(std.fmt.bufPrint(&buf, fmt, args) catch &buf);
    }

    pub fn clock(l: *Line, usec: u64) Writer.Error!void {
        try l.call(timefmt.clock, usec);
    }

    pub fn date(l: *Line, usec: u64) Writer.Error!void {
        try l.call(timefmt.date, usec);
    }

    pub fn span(l: *Line, usec: u64) Writer.Error!void {
        try l.call(timefmt.span, usec);
    }

    pub fn range(l: *Line, first: u64, last: u64) Writer.Error!void {
        var buf: [64]u8 = undefined;
        var w: Writer = .fixed(&buf);
        timefmt.range(&w, first, last) catch {};
        try l.text(w.buffered());
    }

    fn call(l: *Line, f: fn (*Writer, u64) Writer.Error!void, usec: u64) Writer.Error!void {
        var buf: [64]u8 = undefined;
        var w: Writer = .fixed(&buf);
        f(&w, usec) catch {};
        try l.text(w.buffered());
    }

    pub fn padTo(l: *Line, col: usize) Writer.Error!void {
        while (l.used < @min(col, l.width)) : (l.used += 1) try l.w.writeByte(' ');
    }

    pub fn fill(l: *Line) Writer.Error!void {
        try l.padTo(l.width);
    }
};

const Glyph = struct {
    /// Bytes of the input it covers.
    len: usize,
    /// Terminal columns it takes.
    cols: u2,
    out: union(enum) { keep, byte: u8, drop },
};

/// The first character of `s` (not empty) as it may be shown: journal text is
/// untrusted, so invalid UTF-8 becomes "?", control characters (C1 too, U+009B
/// is CSI) a space, and invisible format characters (bidi overrides, joiners)
/// are dropped.
fn glyph(s: []const u8) Glyph {
    const bad: Glyph = .{ .len = 1, .cols = 1, .out = .{ .byte = '?' } };
    const len = unicode.utf8ByteSequenceLength(s[0]) catch return bad;
    if (len > s.len) return bad;
    const cp = unicode.utf8Decode(s[0..len]) catch return bad;
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return .{ .len = len, .cols = 1, .out = .{ .byte = ' ' } };
    if (inRanges(cp, &format_ranges)) return .{ .len = len, .cols = 0, .out = .drop };
    return .{ .len = len, .cols = width(cp), .out = .keep };
}

const Range = struct { u21, u21 };

const format_ranges = [_]Range{
    .{ 0x200b, 0x200f }, .{ 0x202a, 0x202e }, .{ 0x2060, 0x206f }, .{ 0xfeff, 0xfeff },
};

const zero_ranges = [_]Range{
    .{ 0x0300, 0x036f }, .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05bd },   .{ 0x0610, 0x061a },
    .{ 0x064b, 0x065f }, .{ 0x1ab0, 0x1aff }, .{ 0x1dc0, 0x1dff },   .{ 0x20d0, 0x20ff },
    .{ 0xfe00, 0xfe0f }, .{ 0xfe20, 0xfe2f }, .{ 0xe0100, 0xe01ef },
};

const wide_ranges = [_]Range{
    .{ 0x1100, 0x115f },   .{ 0x2e80, 0x303e },   .{ 0x3041, 0x33ff },   .{ 0x3400, 0x4dbf },
    .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },   .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },
    .{ 0xfe30, 0xfe4f },   .{ 0xff00, 0xff60 },   .{ 0xffe0, 0xffe6 },   .{ 0x1f300, 0x1f64f },
    .{ 0x1f680, 0x1f6ff }, .{ 0x1f900, 0x1f9ff }, .{ 0x20000, 0x3fffd },
};

fn inRanges(cp: u21, ranges: []const Range) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

/// Columns a printable codepoint takes: a small wcwidth covering combining
/// marks, CJK and emoji.
fn width(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inRanges(cp, &zero_ranges)) return 0;
    if (inRanges(cp, &wide_ranges)) return 2;
    return 1;
}

/// Splits text into display lines: at newlines, and wherever `cols` columns are full.
pub const Wrap = struct {
    rest: []const u8,
    cols: usize,

    pub fn next(w: *Wrap) ?[]const u8 {
        if (w.rest.len == 0) return null;
        var i: usize = 0;
        var used: usize = 0;
        while (i < w.rest.len and w.rest[i] != '\n') {
            const g = glyph(w.rest[i..]);
            // Always take one character, however narrow the line is.
            if (used + g.cols > w.cols and i > 0) break;
            i += g.len;
            used += g.cols;
        }
        const line = w.rest[0..i];
        w.rest = w.rest[i..];
        if (w.rest.len > 0 and w.rest[0] == '\n') w.rest = w.rest[1..];
        return line;
    }
};

test "Line.text sanitises and counts columns" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var l: Line = .{ .w = &w, .width = 10, .colored = false };
    // ESC, a stray continuation byte, C1 CSI (U+009B), a bidi override, a wide character.
    try l.text("a\x1bb\x80c\xc2\x9b\xe2\x80\xae世");
    try std.testing.expectEqualStrings("a b?c 世", w.buffered());
    try std.testing.expectEqual(8, l.used);
    // Two columns left, the second wide character doesn't fit in the one after "x".
    try l.text("x世y");
    try std.testing.expectEqualStrings("a b?c 世x ", w.buffered());
    try std.testing.expectEqual(10, l.used);
}

test Wrap {
    var w: Wrap = .{ .rest = "abcde\n\nf世界\n", .cols = 3 };
    const want = [_][]const u8{ "abc", "de", "", "f世", "界" };
    for (want) |line| try std.testing.expectEqualStrings(line, w.next().?);
    try std.testing.expectEqual(null, w.next());
}

/// A sequence of lines: newline-separated for `-plain`, or placed on screen rows
/// `first..end` for the TUI.
pub const Rows = struct {
    w: *Writer,
    width: usize,
    colored: bool,
    screen: ?struct { row: usize, end: usize } = null,
    line: Line = undefined,
    open: bool = false,

    /// Finishes the previous line and starts a new one, null once the screen area is full.
    pub fn next(r: *Rows) Writer.Error!?*Line {
        try r.close();
        if (r.screen) |*s| {
            if (s.row >= s.end) return null;
            try r.w.print("\x1b[{d};1H", .{s.row + 1});
            s.row += 1;
        }
        r.line = .{ .w = r.w, .width = r.width, .colored = r.colored };
        r.open = true;
        return &r.line;
    }

    pub fn close(r: *Rows) Writer.Error!void {
        if (!r.open) return;
        r.open = false;
        if (r.colored) try r.w.writeAll("\x1b[0m");
        try r.w.writeAll(if (r.screen != null) "\x1b[K" else "\n");
    }
};

pub const label_width = 9;
pub const ident_width = 18;

/// "  19:01:02 + gpu       kernel            amdgpu: ring gfx timeout  ×3"
/// The "+" marks a group the earlier boots didn't have.
pub fn groupRow(l: *Line, m: *const Model, g: dedup.Group) Writer.Error!void {
    const e = &m.entries[g.first];
    try l.text("  ");
    try l.fg(color.base01);
    try l.clock(e.usec);
    if (g.new) {
        try l.fg(color.new);
        try l.bold();
        try l.text(" + ");
        try l.reset();
    } else {
        try l.text("   ");
    }
    const start = l.used;
    try l.fg(color.of(g.cat));
    try l.bold();
    try l.text(g.cat.label());
    try l.reset();
    try l.padTo(start + label_width + 1);
    try identAndMessage(l, e, color.base1);
    if (g.count > 1) {
        try l.text("  ");
        try l.fg(color.yellow);
        try l.print("×{d}", .{g.count});
    }
}

/// "  19:44:30 ● systemd           Stopping ...", colored by priority.
pub fn entryRow(l: *Line, e: *const Entry, cat: Category) Writer.Error!void {
    try l.text("  ");
    try l.fg(color.base01);
    try l.clock(e.usec);
    if (cat != .none) {
        try l.fg(color.of(cat));
        try l.text(" ● ");
    } else {
        try l.text("   ");
    }
    try identAndMessage(l, e, color.priority(e.priority));
}

fn identAndMessage(l: *Line, e: *const Entry, message_color: u24) Writer.Error!void {
    const start = l.used;
    try l.fg(color.base0);
    try l.text(e.ident);
    try l.padTo(start + ident_width);
    try l.text(" ");
    try l.fg(message_color);
    // Only the first line: a coredump's message carries its whole stack trace.
    const body = std.mem.trim(u8, e.message, "\r\n");
    const end = std.mem.findScalar(u8, body, '\n') orelse body.len;
    try l.text(body[0..end]);
    if (end < body.len) try l.text(" …");
}

/// The Summary tab, and the top of `-plain` (without `latest`: there the whole
/// notable list follows anyway).
pub fn summary(rows: *Rows, m: *const Model, store: pstore.Status, latest: bool) Writer.Error!void {
    const kind = m.end.kind;
    var l = try rows.next() orelse return;

    l = try rows.next() orelse return;
    try key(l, "boot");
    try l.fg(color.base1);
    try l.print("{d}", .{m.offset});
    try l.fg(color.base01);
    try l.print(" · {s} · ", .{m.boot.id[0..8]});
    try l.fg(color.base1);
    try l.range(m.boot.first, m.boot.last);
    try l.fg(color.base01);
    try l.text("  (");
    if (m.boot.last >= m.boot.first) try l.span(m.boot.last - m.boot.first) else try l.text("clock jumped back");
    try l.text(")");

    l = try rows.next() orelse return;
    try key(l, "ended");
    try l.fg(if (kind == .running) color.blue else if (kind.clean()) color.green else color.red);
    try l.bold();
    try l.text("● ");
    try l.text(kind.label());

    l = try rows.next() orelse return;
    try l.padTo(12);
    try l.fg(color.base0);
    try l.text("last entry ");
    try l.clock(m.end.last);
    if (m.next_first) |next| {
        try l.text(" · next boot ");
        try l.clock(next);
        try l.text(", ");
        try l.span(next -| m.end.last);
        try l.text(" later");
    }
    if (m.end.slept_at) |t| {
        l = try rows.next() orelse return;
        try l.padTo(12);
        try l.fg(color.base0);
        try l.text("went to sleep at ");
        try l.clock(t);
        try l.text(" and never logged a wake-up");
    } else if (m.end.shutdown_at != null and !kind.clean()) {
        l = try rows.next() orelse return;
        try l.padTo(12);
        try l.fg(color.base0);
        try l.text("shutdown began at ");
        try l.clock(m.end.shutdown_at.?);
        try l.text(" but never finished");
    } else if (kind == .abrupt) {
        l = try rows.next() orelse return;
        try l.padTo(12);
        try l.fg(color.base0);
        try l.text("the journal just stops; Last 60s shows what came right before");
    }

    l = try rows.next() orelse return;
    try key(l, "pstore");
    try l.fg(color.base0);
    switch (store) {
        .empty => |e| if (e.denied == pstore.paths.len) {
            try l.text("not readable without root; kernel panics may be saved there");
        } else if (e.denied > 0) {
            try l.print("nothing found; {d} of {d} pstore dirs need root", .{ e.denied, pstore.paths.len });
        } else {
            try l.text("empty");
        },
        .found => |f| {
            try l.fg(color.red);
            try l.print("{d} record(s) in {s}; not tied to a boot, check their dates", .{ f.count, pstore.paths[f.dir] });
        },
    }

    l = try rows.next() orelse return;
    l = try rows.next() orelse return;
    try key(l, "found");
    var any = false;
    for (std.enums.values(Category)) |cat| {
        if (cat == .none) continue;
        const n = m.counts.get(cat);
        if (n == 0) continue;
        any = true;
        try l.fg(color.of(cat));
        try l.bold();
        try l.text(cat.label());
        try l.reset();
        try l.fg(color.base1);
        try l.print(" {d}   ", .{n});
    }
    if (!any) {
        try l.fg(color.green);
        try l.text("nothing notable");
    }

    if (m.compared > 0) {
        l = try rows.next() orelse return;
        try key(l, "new");
        var buf: [32]u8 = undefined;
        const before = if (m.compared == 1)
            "the boot before"
        else
            std.fmt.bufPrint(&buf, "the {d} boots before", .{m.compared}) catch "the boots before";
        if (m.new_notable > 0) {
            try l.fg(color.new);
            try l.bold();
            try l.print("+ {d}", .{m.new_notable});
            try l.reset();
            try l.fg(color.base0);
            try l.print(" of {d} notable events didn't happen in {s}", .{ m.notable.len, before });
        } else {
            try l.fg(color.base0);
            try l.print("nothing that {s} didn't log too", .{before});
        }
    }

    if (!latest or m.notable.len == 0) return;
    const max_rows = 8;
    l = try rows.next() orelse return;
    l = try rows.next() orelse return;
    if (m.new_notable > 0) {
        // The new ones are what the reader is after, the rest is on the Notable tab.
        try key(l, "+");
        try l.fg(color.base01);
        try l.text("new in this boot, newest last");
        var skip = m.new_notable -| max_rows;
        for (m.notable) |g| {
            if (!g.new) continue;
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            l = try rows.next() orelse return;
            try groupRow(l, m, g);
        }
        return;
    }
    try key(l, "latest");
    try l.fg(color.base01);
    try l.text("notable events, newest last");
    const shown = @min(m.notable.len, max_rows);
    for (m.notable[m.notable.len - shown ..]) |g| {
        l = try rows.next() orelse return;
        try groupRow(l, m, g);
    }
}

fn key(l: *Line, name: []const u8) Writer.Error!void {
    try l.text("  ");
    try l.fg(color.base01);
    try l.text(name);
    try l.padTo(12);
}
