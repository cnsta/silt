const std = @import("std");
const c = @import("c");

const process = std.process;
const log = std.log;
const Io = std.Io;

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
    }).parse(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        process.exit(1);
    };
    if (result.flags.h) {
        std.debug.print("{s}", .{usage});
        process.exit(0);
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

    c.tzset();

    const journal = Journal.open() catch {
        log.err("cannot open the journal", .{});
        process.exit(1);
    };
    defer journal.close();
    const boots = try journal.boots(gpa);
    defer gpa.free(boots);

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    const tty = Io.File.stdout().isTty(io) catch false;

    if (result.flags.list) {
        try listBoots(w, boots);
        try w.flush();
        return;
    }

    const index = Model.bootIndex(boots.len, offset) orelse {
        log.err("no boot {d} (the journal has {d})", .{ offset, boots.len });
        process.exit(1);
    };
    var model = try Model.load(gpa, journal, boots, index, result.flags.noise);
    const store = pstore.check(io);

    if (result.flags.plain or !tty) {
        defer model.deinit();
        try plain.write(w, &model, store, tty);
        try w.flush();
        return;
    }

    const term = Term.enter() catch |err| {
        model.deinit();
        log.err("cannot open the terminal: {s}", .{@errorName(err)});
        process.exit(1);
    };
    defer term.leave();
    var app: App = .init(gpa, term, journal, boots, model, result.flags.noise, store);
    defer app.deinit();
    try app.run();
}

fn listBoots(w: *Io.Writer, boots: []const Journal.Boot) !void {
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
}
