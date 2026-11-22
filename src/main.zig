const std = @import("std");
const c = @import("c");

const process = std.process;
const log = std.log;
const Io = std.Io;

const flags = @import("flags.zig");
const Cache = @import("cache.zig");
const Journal = @import("Journal.zig");
const Model = @import("Model.zig");
const Progress = @import("Progress.zig");
const pstore = @import("pstore.zig");
const plain = @import("plain.zig");
const timefmt = @import("timefmt.zig");
const App = @import("tui/App.zig");
const Term = @import("tui/Term.zig");

test {
    _ = @import("cache.zig");
    _ = @import("Journal.zig");
    _ = @import("classify.zig");
    _ = @import("dedup.zig");
    _ = @import("ending.zig");
    _ = @import("Model.zig");
    _ = @import("Progress.zig");
    _ = @import("timefmt.zig");
    _ = @import("ui.zig");
    _ = @import("tui/keys.zig");
    _ = @import("tui/App.zig");
}

const usage =
    \\usage: silt [options]
    \\
    \\Shows how a boot ended and what notable happened in it, with repeats
    \\collapsed and routine noise hidden. Opens the previous boot by default.
    \\
    \\  -h          Print this help message and exit.
    \\  -b <n>      Open boot n, like journalctl: 0 is this boot, -1 the previous
    \\              one (default), 1 the oldest.
    \\  -list       List the boots and how each ended, then exit.
    \\  -plain      Print a summary instead of opening the viewer (the default
    \\              when stdout isn't a terminal).
    \\  -noise      Keep the warnings silt normally hides as noise.
    \\  -history <n>
    \\              Mark an event as new (+) if nothing like it was logged in the
    \\              n boots before (default 5, 0 turns it off).
    \\  -new        With -plain, list only the new notable events.
    \\  -no-cache   Don't read or write ~/.cache/silt (earlier boots' events,
    \\              kept so a flood in one is read only once).
    \\
;

/// Leave the alternate screen and raw mode before printing the panic.
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (Term.active) |t| t.leave();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.call);

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    const result = flags.parser(&.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "b", .kind = .arg },
        .{ .name = "list", .kind = .boolean },
        .{ .name = "plain", .kind = .boolean },
        .{ .name = "noise", .kind = .boolean },
        .{ .name = "history", .kind = .arg },
        .{ .name = "new", .kind = .boolean },
        .{ .name = "no-cache", .kind = .boolean },
    }).parse(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        process.exit(1);
    };
    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    const tty = Io.File.stdout().isTty(io) catch false;

    if (result.flags.h) {
        w.writeAll(usage) catch {};
        w.flush() catch {};
        return;
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        std.debug.print("{s}", .{usage});
        process.exit(1);
    }
    const offset = std.fmt.parseInt(i32, result.flags.b orelse "-1", 10) catch {
        log.err("invalid boot '{s}'", .{result.flags.b.?});
        process.exit(1);
    };
    var options: Model.Options = .{ .keep_noise = result.flags.noise };
    if (result.flags.history) |arg| {
        options.history = std.fmt.parseInt(u32, arg, 10) catch {
            log.err("invalid history '{s}'", .{arg});
            process.exit(1);
        };
    }

    c.tzset();

    var sink_ctx: u8 = 0;
    var progress: Progress = .init(.{ .ctx = &sink_ctx, .show = showStderr });
    const stderr_tty = Io.File.stderr().isTty(io) catch false;
    const p: ?*Progress = if (stderr_tty) &progress else null;

    const journal = Journal.open() catch {
        log.err("cannot open the journal", .{});
        process.exit(1);
    };
    defer journal.close();
    const boots = journal.boots(gpa, p) catch |err| {
        progress.finish();
        return err;
    };
    defer gpa.free(boots);

    if (boots.len == 0) {
        progress.finish();
        log.err("the journal has no boots; reading the system journal needs the systemd-journal or wheel group", .{});
        process.exit(1);
    }

    if (result.flags.list) {
        progress.finish();
        listBoots(w, boots) catch |err| writeFailed(&out, err);
        return;
    }

    const index = Model.bootIndex(boots.len, offset) orelse {
        progress.finish();
        log.err("no boot {d} (the journal has {d})", .{ offset, boots.len });
        process.exit(1);
    };
    const cache: ?Cache = if (@field(result.flags, "no-cache")) null else Cache.open(io, init.environ_map);
    defer if (cache) |cc| cc.close();
    if (cache) |cc| cc.prune(boots);
    const loaded = Model.load(gpa, journal, cache, p, boots, index, options);
    progress.finish();
    var model = try loaded;
    const store = pstore.check(io);

    if (result.flags.plain or !tty) {
        defer model.deinit();
        // https://no-color.org
        const no_color = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;
        plain.write(w, &model, store, .{
            .colored = tty and !no_color,
            .only_new = result.flags.new,
        }) catch |err| writeFailed(&out, err);
        return;
    }

    const term = Term.enter() catch |err| {
        model.deinit();
        log.err("cannot open the terminal: {s}", .{@errorName(err)});
        process.exit(1);
    };
    defer term.leave();
    var app: App = .init(gpa, term, journal, cache, boots, model, options, store);
    defer app.deinit();
    try app.run();
}

/// A closed pipe (`silt -plain | head`) is a normal way to end, not an error trace.
fn writeFailed(out: *Io.File.Writer, err: Io.Writer.Error) noreturn {
    const cause: anyerror = out.err orelse err;
    if (cause == error.BrokenPipe) process.exit(0);
    log.err("cannot write to stdout: {s}", .{@errorName(cause)});
    process.exit(1);
}

fn listBoots(w: *Io.Writer, boots: []const Journal.Boot) Io.Writer.Error!void {
    for (boots, 0..) |boot, i| {
        const offset = @as(i64, @intCast(i)) - @as(i64, @intCast(boots.len - 1));
        var num: [16]u8 = undefined;
        try w.print("{s: >4}  {s}  ", .{ std.fmt.bufPrint(&num, "{d}", .{offset}) catch "?", boot.id[0..8] });
        try timefmt.date(w, boot.first);
        try w.writeAll("  ");
        var buf: [32]u8 = undefined;
        var span: Io.Writer = .fixed(&buf);
        try timefmt.span(&span, boot.last -| boot.first);
        try w.print("{s: <9}", .{span.buffered()});
        try w.writeAll(if (i == boots.len - 1) "running\n" else if (boot.clean) "clean\n" else "unclean\n");
    }
    try w.flush();
}

fn showStderr(_: *anyopaque, line: []const u8) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\r\x1b[K{s}", .{line}) catch return;
    _ = std.os.linux.write(2, s.ptr, s.len);
}
