const std = @import("std");
const c = @import("c");

const Progress = @This();

/// Where the line goes: stderr before the TUI, its footer after.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Replaces the shown line with `line` (empty: removes it).
    show: *const fn (ctx: *anyopaque, line: []const u8) void,
};

const delay_ms = 200;
const frame_ms = 80;
const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

sink: Sink,
start_ms: i64,
last_ms: i64 = 0,
frame: usize = 0,
shown: bool = false,
count: u64 = 0,
label_buf: [80]u8 = undefined,
label: []const u8 = "",

pub fn init(sink: Sink) Progress {
    return .{ .sink = sink, .start_ms = now() };
}

/// Starts a step: the label replaces the last one and the line count restarts.
pub fn phase(p: *Progress, comptime fmt: []const u8, args: anytype) void {
    p.label = std.fmt.bufPrint(&p.label_buf, fmt, args) catch p.label_buf[0..0];
    p.count = 0;
    p.redraw(.now);
}

/// One journal entry read.
pub fn tick(p: *Progress) void {
    p.count += 1;
    // The clock is cheap, but not per entry cheap. A cold page cache can make
    // a thousand entries take most of a second, so not much rarer.
    if (p.count % 64 == 0) p.redraw(.throttled);
}

/// Keeps the spinner turning in a loop that doesn't read lines.
pub fn poll(p: *Progress) void {
    p.redraw(.throttled);
}

/// Removes the line, if it was shown.
pub fn finish(p: *Progress) void {
    if (p.shown) p.sink.show(p.sink.ctx, "");
    p.shown = false;
}

/// `.now` skips the frame limit, so a new label isn't lost to it; nothing is
/// shown before `delay_ms` either way.
fn redraw(p: *Progress, when: enum { now, throttled }) void {
    const t = now();
    if (t - p.start_ms < delay_ms) return;
    if (when == .throttled and p.shown and t - p.last_ms < frame_ms) return;
    p.last_ms = t;
    p.frame = (p.frame + 1) % frames.len;
    var buf: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{s} {s}", .{ frames[p.frame], p.label }) catch {};
    if (p.count > 0) {
        w.writeAll(" · ") catch {};
        lines(&w, p.count) catch {};
    }
    p.sink.show(p.sink.ctx, w.buffered());
    p.shown = true;
}

/// "812 lines", "34k lines", "1.2M lines".
fn lines(w: *std.Io.Writer, n: u64) std.Io.Writer.Error!void {
    if (n < 10_000) return w.print("{d} lines", .{n});
    if (n < 1_000_000) return w.print("{d}k lines", .{n / 1000});
    try w.print("{d}.{d}M lines", .{ n / 1_000_000, n / 100_000 % 10 });
}

fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

test lines {
    var buf: [32]u8 = undefined;
    for ([_]struct { u64, []const u8 }{
        .{ 812, "812 lines" },
        .{ 34_567, "34k lines" },
        .{ 1_234_567, "1.2M lines" },
    }) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try lines(&w, case[0]);
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
}
