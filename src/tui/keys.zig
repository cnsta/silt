const std = @import("std");
const isDigit = std.ascii.isDigit;

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    esc,
    tab,
    backtab,
    backspace,
    ctrl_c,
    ctrl_d,
    ctrl_u,
};

pub const Iterator = struct {
    buf: []const u8,
    i: usize = 0,

    pub fn next(it: *Iterator) ?Key {
        if (it.i >= it.buf.len) return null;
        const b = it.buf[it.i];
        it.i += 1;
        return switch (b) {
            0x1b => it.escape(),
            '\r', '\n' => .enter,
            '\t' => .tab,
            0x7f, 0x08 => .backspace,
            0x03 => .ctrl_c,
            0x04 => .ctrl_d,
            0x15 => .ctrl_u,
            else => .{ .char = b },
        };
    }

    /// CSI/SS3 sequences, anything unrecognised is a plain Esc.
    fn escape(it: *Iterator) Key {
        const buf = it.buf;
        if (it.i >= buf.len or (buf[it.i] != '[' and buf[it.i] != 'O')) return .esc;
        it.i += 1;
        var param: u32 = 0;
        while (it.i < buf.len and isDigit(buf[it.i])) : (it.i += 1) param = param *| 10 +| (buf[it.i] - '0');
        // Modifier parameters (";5") don't change the key here.
        while (it.i < buf.len and (buf[it.i] == ';' or isDigit(buf[it.i]))) it.i += 1;
        if (it.i >= buf.len) return .esc;
        const final = buf[it.i];
        it.i += 1;
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .backtab,
            '~' => switch (param) {
                1, 7 => .home,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => .esc,
            },
            else => .esc,
        };
    }
};

test Iterator {
    var it: Iterator = .{ .buf = "j\x1b[A\x1b[6~\x1b\r\x1b[Z\x1b[1;5B" };
    const want = [_]Key{ .{ .char = 'j' }, .up, .page_down, .esc, .enter, .backtab, .down };
    for (want) |k| try std.testing.expectEqual(k, it.next().?);
    try std.testing.expectEqual(null, it.next());
}
