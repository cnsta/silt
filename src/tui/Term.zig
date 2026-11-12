const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const Term = @This();

fd: posix.fd_t,
orig: posix.termios,

/// Read by the panic handler, so a crash never leaves the terminal raw.
pub var active: ?Term = null;

pub const Size = struct { rows: usize, cols: usize };

pub fn enter() !Term {
    const rc = linux.open("/dev/tty", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (posix.errno(rc) != .SUCCESS) return error.NoTty;
    const fd: posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    const orig = try posix.tcgetattr(fd);
    var raw = orig;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .FLUSH, raw);

    const term: Term = .{ .fd = fd, .orig = orig };
    term.write("\x1b[?1049h\x1b[?25l");
    active = term;
    return term;
}

pub fn leave(self: Term) void {
    self.write("\x1b[0m\x1b[?25h\x1b[?1049l");
    posix.tcsetattr(self.fd, .FLUSH, self.orig) catch {};
    _ = linux.close(self.fd);
    active = null;
}

pub fn size(self: Term) Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(self.fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS or ws.row == 0 or ws.col == 0) return .{ .rows = 24, .cols = 80 };
    return .{ .rows = ws.row, .cols = ws.col };
}

pub fn write(self: Term, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(self.fd, rest.ptr, rest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => {},
            else => return,
        }
    }
}

/// Waits up to `timeout_ms` for input. Empty on timeout (the caller re-checks the size).
pub fn read(self: Term, buf: []u8, timeout_ms: i32) ![]u8 {
    var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
    if (try posix.poll(&fds, timeout_ms) == 0) return buf[0..0];
    const n = try posix.read(self.fd, buf);
    if (n == 0) return error.EndOfStream;
    return buf[0..n];
}
