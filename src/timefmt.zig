const std = @import("std");
const c = @import("c");

const Writer = std.Io.Writer;
const us_per_s = std.time.us_per_s;

const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

fn local(usec: u64) c.struct_tm {
    const t: c.time_t = @intCast(usec / us_per_s);
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    _ = c.localtime_r(&t, &tm);
    return tm;
}

/// "19:45:23"
pub fn clock(w: *Writer, usec: u64) Writer.Error!void {
    const tm = local(usec);
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)), @as(u32, @intCast(tm.tm_sec)) });
}

/// "Fri 2026-10-23 19:45"
pub fn date(w: *Writer, usec: u64) Writer.Error!void {
    const tm = local(usec);
    try w.print("{s} {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        weekdays[@intCast(tm.tm_wday)],
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
    });
}

/// "Fri 2026-10-23 16:11 -> 19:45", with the end's date only if it differs.
pub fn range(w: *Writer, first: u64, last: u64) Writer.Error!void {
    try date(w, first);
    try w.writeAll(" → ");
    const a = local(first);
    const b = local(last);
    if (a.tm_year == b.tm_year and a.tm_yday == b.tm_yday) {
        try w.print("{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(b.tm_hour)), @as(u32, @intCast(b.tm_min)) });
    } else {
        try date(w, last);
    }
}

/// A rough duration: "42s", "5m 12s", "3h 33m", "2d 4h".
pub fn span(w: *Writer, usec: u64) Writer.Error!void {
    const s = usec / us_per_s;
    if (s < 60) return w.print("{d}s", .{s});
    if (s < 3600) return w.print("{d}m {d}s", .{ s / 60, s % 60 });
    if (s < 86400) return w.print("{d}h {d}m", .{ s / 3600, s % 3600 / 60 });
    return w.print("{d}d {d}h", .{ s / 86400, s % 86400 / 3600 });
}

test span {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { u64, []const u8 }{
        .{ 42 * us_per_s, "42s" },
        .{ 312 * us_per_s, "5m 12s" },
        .{ (3 * 3600 + 33 * 60 + 9) * us_per_s, "3h 33m" },
        .{ (2 * 86400 + 4 * 3600) * us_per_s, "2d 4h" },
    };
    for (cases) |case| {
        var w: Writer = .fixed(&buf);
        try span(&w, case[0]);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
}
