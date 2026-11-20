/// Wall-clock time, microseconds since the epoch.
usec: u64,
/// syslog priority: 0 emerg ... 7 debug.
priority: u3 = 6,
/// Logged by the kernel (`_TRANSPORT=kernel`).
kernel: bool = false,
ident: []const u8 = "",
message: []const u8 = "",
/// The unit the message is about (`UNIT`), else the one that logged it.
unit: []const u8 = "",
/// `unit` belongs to a user manager (a logout's "Reached target Shutdown" isn't
/// the system shutting down).
user_unit: bool = false,
message_id: []const u8 = "",
/// Where the entry sits in the journal, for reading its surroundings later.
/// Empty for entries that weren't read from a journal.
cursor: [:0]const u8 = "",

const Allocator = @import("std").mem.Allocator;

/// A copy whose strings live in `arena`.
pub fn dupe(e: *const @This(), arena: Allocator) Allocator.Error!@This() {
    var copy = e.*;
    inline for (.{ "ident", "message", "unit", "message_id" }) |name| {
        @field(copy, name) = try arena.dupe(u8, @field(e, name));
    }
    copy.cursor = try arena.dupeSentinel(u8, e.cursor, 0);
    return copy;
}
