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
        while (i < s.len and l.used < l.width) {
            const len = unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (i + len > s.len or (len > 1 and !unicode.utf8ValidateSlice(s[i .. i + len]))) {
                try l.w.writeByte('?');
                i += 1;
            } else if (len == 1 and (s[i] < 0x20 or s[i] == 0x7f)) {
                try l.w.writeByte(' ');
                i += 1;
            } else {
                try l.w.writeAll(s[i .. i + len]);
                i += len;
            }
            l.used += 1;
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

/// "  19:01:02  gpu       kernel            amdgpu: ring gfx timeout  ×3"
pub fn groupRow(l: *Line, m: *const Model, g: dedup.Group) Writer.Error!void {
    const e = &m.entries[g.first];
    try l.text("  ");
    try l.fg(color.base01);
    try l.clock(e.usec);
    try l.text("  ");
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
    try l.text(e.message);
}

/// The Summary tab, and the top of `-plain`.
pub fn summary(rows: *Rows, m: *const Model, store: pstore.Status) Writer.Error!void {
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

    if (m.notable.len == 0) return;
    l = try rows.next() orelse return;
    l = try rows.next() orelse return;
    try key(l, "latest");
    try l.fg(color.base01);
    try l.text("notable events, newest last");
    const shown = @min(m.notable.len, 8);
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
