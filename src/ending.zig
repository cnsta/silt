const std = @import("std");
const mem = std.mem;

const Entry = @import("Entry.zig");
const id = @import("classify.zig").id;

pub const Kind = enum {
    running,
    poweroff,
    reboot,
    halt,
    kexec,
    shutdown,
    shutdown_hung,
    asleep,
    abrupt,

    pub fn clean(kind: Kind) bool {
        return switch (kind) {
            .shutdown_hung, .asleep, .abrupt => false,
            else => true,
        };
    }

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .running => "still running",
            .poweroff => "powered off",
            .reboot => "rebooted",
            .halt => "halted",
            .kexec => "kexec'd",
            .shutdown => "shut down",
            .shutdown_hung => "hung while shutting down",
            .asleep => "never woke from sleep",
            .abrupt => "ended abruptly: crash, hang or power loss",
        };
    }
};

pub const Ending = struct {
    kind: Kind,
    /// The boot's last entry.
    last: u64,
    /// When a shutdown was first announced, if one was.
    shutdown_at: ?u64 = null,
    /// When the boot last went to sleep without waking up.
    slept_at: ?u64 = null,
};

pub fn analyze(entries: []const Entry, running: bool) Ending {
    var result: Ending = .{ .kind = .abrupt, .last = if (entries.len > 0) entries[entries.len - 1].usec else 0 };
    var target: ?Kind = null;
    // journald also stops once in the initrd, so only a stop that isn't followed
    // by another start counts.
    var stopped = false;
    var asleep: ?u64 = null;

    for (entries) |*e| {
        if (mem.eql(u8, e.message_id, id.journal_stopped)) stopped = true;
        if (mem.eql(u8, e.message_id, id.journal_started)) stopped = false;

        const job_done = mem.eql(u8, e.message_id, id.job_done) and !e.user_unit;
        const announced = mem.eql(u8, e.message_id, id.shutdown) or
            (job_done and mem.eql(u8, e.unit, "shutdown.target"));
        if (announced and result.shutdown_at == null) result.shutdown_at = e.usec;

        if (job_done) {
            if (targetKind(e.unit)) |k| target = k;
        }

        if (e.kernel) {
            if (contains(e.message, "suspend entry") or contains(e.message, "hibernation entry")) asleep = e.usec;
            if (contains(e.message, "suspend exit") or contains(e.message, "hibernation exit")) asleep = null;
        }
    }

    if (running) {
        result.kind = .running;
    } else if (stopped) {
        result.kind = target orelse .shutdown;
    } else if (asleep) |t| {
        result.kind = .asleep;
        result.slept_at = t;
    } else if (result.shutdown_at != null) {
        result.kind = .shutdown_hung;
    }
    return result;
}

fn targetKind(unit: []const u8) ?Kind {
    const map = [_]struct { []const u8, Kind }{
        .{ "reboot.target", .reboot },
        .{ "poweroff.target", .poweroff },
        .{ "halt.target", .halt },
        .{ "kexec.target", .kexec },
    };
    for (map) |m| if (mem.eql(u8, unit, m[0])) return m[1];
    return null;
}

fn contains(s: []const u8, needle: []const u8) bool {
    return mem.indexOf(u8, s, needle) != null;
}

test "clean reboot" {
    const entries = [_]Entry{
        .{ .usec = 1, .message_id = id.journal_stopped },
        .{ .usec = 2, .message_id = id.journal_started },
        .{ .usec = 3, .message_id = id.job_done, .unit = "shutdown.target" },
        .{ .usec = 4, .message_id = id.job_done, .unit = "reboot.target" },
        .{ .usec = 5, .message_id = id.journal_stopped },
    };
    const e = analyze(&entries, false);
    try std.testing.expectEqual(.reboot, e.kind);
    try std.testing.expectEqual(3, e.shutdown_at.?);
    try std.testing.expectEqual(5, e.last);
}

test "initrd stop and a logout are not a clean end" {
    const entries = [_]Entry{
        .{ .usec = 1, .message_id = id.journal_stopped },
        .{ .usec = 2, .message_id = id.journal_started },
        .{ .usec = 2, .message_id = id.job_done, .unit = "shutdown.target", .user_unit = true },
        .{ .usec = 3, .message = "tailscaled: magicsock: endpoints changed" },
    };
    try std.testing.expectEqual(.abrupt, analyze(&entries, false).kind);
    try std.testing.expectEqual(.running, analyze(&entries, true).kind);
}

test "died asleep and hung shutdown" {
    const asleep = [_]Entry{
        .{ .usec = 1, .kernel = true, .message = "PM: suspend entry (deep)" },
        .{ .usec = 2, .kernel = true, .message = "PM: suspend exit" },
        .{ .usec = 3, .kernel = true, .message = "PM: suspend entry (deep)" },
    };
    const e = analyze(&asleep, false);
    try std.testing.expectEqual(.asleep, e.kind);
    try std.testing.expectEqual(3, e.slept_at.?);

    const hung = [_]Entry{.{ .usec = 1, .message_id = id.shutdown }};
    try std.testing.expectEqual(.shutdown_hung, analyze(&hung, false).kind);
}
