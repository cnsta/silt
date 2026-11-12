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
