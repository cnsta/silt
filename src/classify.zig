const std = @import("std");
const mem = std.mem;

const Entry = @import("Entry.zig");

pub const Category = enum {
    kernel,
    hardware,
    oom,
    crash,
    gpu,
    unit,
    err,
    warn,
    none,

    /// Shown on the Notable tab, warnings only make the All tab.
    pub fn notable(cat: Category) bool {
        return switch (cat) {
            .warn, .none => false,
            else => true,
        };
    }

    pub fn label(cat: Category) []const u8 {
        return switch (cat) {
            .kernel => "kernel",
            .hardware => "hardware",
            .oom => "oom",
            .crash => "crash",
            .gpu => "gpu",
            .unit => "unit",
            .err => "error",
            .warn => "warning",
            .none => "",
        };
    }
};

/// systemd catalog MESSAGE_IDs (`journalctl --list-catalog`).
pub const id = struct {
    pub const coredump = "fc2e22bc6ee647b6b90729ab34a250b1";
    pub const terminated_abnormally = "1f4e0a44a88649939aaea34fc6da8c95";
    pub const unit_failed = "d9b373ed55a64feb8242e02dbe79a49c";
    pub const job_failed = "be02cf6855d2428ba40df7e9d022f03d";
    pub const oomd_kill = "d989611b15e44c9dbf31e3c81256e4ed";
    pub const shutdown = "98268866d1d54a499c4e98921d93bc40";
    pub const job_done = "39f53479d3a045ac8e11786248231fbf";
    pub const journal_started = "f77379a8490b408bbe5f6940505a777b";
    pub const journal_stopped = "d93fb3c9c24d451a97cea615ce59c00b";
};

const process_crash = [_][]const u8{ "segfault at", "traps: " };

const kernel_trouble = [_][]const u8{
    "Kernel panic",
    "BUG: ",
    "kernel BUG",
    "Oops",
    "general protection fault",
    "soft lockup",
    "hard LOCKUP",
    "detected stall",
    "blocked for more than",
    "WARNING: CPU:",
};

/// Always hardware trouble, whatever the priority.
const hardware_fatal = [_][]const u8{ "Machine check", "Hardware Error" };

/// Hardware trouble at warning priority or worse ("EDAC MC: Ver: 3.0.0" is info).
const hardware_trouble = [_][]const u8{
    "EDAC",
    "I/O error",
    "Medium Error",
    "PCIe Bus Error",
    "temperature above threshold",
    "critical temperature",
};

const gpu_drivers = [_][]const u8{ "amdgpu", "[drm", "NVRM", "nouveau", "i915", "xe " };
/// Not plain "fault": "(default)" contains it.
const gpu_trouble = [_][]const u8{ "timeout", "timed out", "reset", "hang", "page fault", "GPU fault", "lockup", "recover", "failed", "*ERROR*" };

pub fn of(e: *const Entry) Category {
    if (eqlAny(e.message_id, &.{ id.coredump, id.terminated_abnormally })) return .crash;
    if (mem.eql(u8, e.message_id, id.oomd_kill)) return .oom;
    if (eqlAny(e.message_id, &.{ id.unit_failed, id.job_failed })) return .unit;
    if (e.kernel) {
        // Before kernel_trouble: user-space traps also say "general protection fault".
        if (containsAny(e.message, &process_crash)) return .crash;
        if (mem.indexOf(u8, e.message, "Out of memory") != null) return .oom;
        if (containsAny(e.message, &kernel_trouble)) return .kernel;
        if (containsAny(e.message, &hardware_fatal)) return .hardware;
        if (e.priority <= 4 and containsAny(e.message, &hardware_trouble)) return .hardware;
        if (containsAny(e.message, &gpu_drivers) and containsAny(e.message, &gpu_trouble)) return .gpu;
    }
    if (e.priority <= 3) return .err;
    if (e.priority == 4) return .warn;
    return .none;
}

const Noise = struct {
    ident: []const u8 = "",
    text: []const u8,
};

/// Routine complaints that are never why a boot went wrong.
const noise = [_]Noise{
    .{ .ident = "dbus-broker-launch", .text = "Ignoring duplicate name" },
    .{ .text = "without calling gtk_widget_measure" },
    .{ .text = "is invalid or out of range for property" },
    .{ .text = "Failed to adjust io pressure threshold" },
    .{ .ident = "systemd-logind", .text = ": Version string " },
    // Logged at crit on every boot when amdgpu overclocking is unlocked.
    .{ .ident = "kernel", .text = "amdgpu: Overdrive is enabled" },
};

/// Only plain errors and warnings can be noise, the specific categories never are.
pub fn isNoise(e: *const Entry, cat: Category) bool {
    if (cat != .err and cat != .warn) return false;
    for (noise) |n| {
        if (n.ident.len != 0 and !mem.eql(u8, n.ident, e.ident)) continue;
        if (mem.indexOf(u8, e.message, n.text) != null) return true;
    }
    return false;
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (mem.eql(u8, s, o)) return true;
    return false;
}

fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (mem.indexOf(u8, s, n) != null) return true;
    return false;
}

test of {
    const t = std.testing;
    try t.expectEqual(.crash, of(&.{ .usec = 0, .message_id = id.coredump }));
    try t.expectEqual(.unit, of(&.{ .usec = 0, .priority = 3, .message_id = id.unit_failed }));
    try t.expectEqual(.kernel, of(&.{ .usec = 0, .kernel = true, .message = "BUG: kernel NULL pointer dereference" }));
    try t.expectEqual(.crash, of(&.{ .usec = 0, .kernel = true, .message = "traps: foo[12] general protection fault ip:1" }));
    try t.expectEqual(.oom, of(&.{ .usec = 0, .kernel = true, .message = "Out of memory: Killed process 1234 (zen)" }));
    try t.expectEqual(.gpu, of(&.{ .usec = 0, .kernel = true, .message = "amdgpu 0000:03:00.0: amdgpu: ring gfx_0.0.0 timeout" }));
    try t.expectEqual(.none, of(&.{ .usec = 0, .kernel = true, .message = "amdgpu: SMU is initialized successfully!" }));
    try t.expectEqual(.none, of(&.{ .usec = 0, .kernel = true, .message = "amdgpu: TMZ feature disabled as experimental (default)" }));
    try t.expectEqual(.none, of(&.{ .usec = 0, .kernel = true, .message = "EDAC MC: Ver: 3.0.0" }));
    try t.expectEqual(.hardware, of(&.{ .usec = 0, .kernel = true, .priority = 3, .message = "mce: [Hardware Error]: CPU 0" }));
    // Only kernel lines count as kernel trouble.
    try t.expectEqual(.none, of(&.{ .usec = 0, .message = "BUG: in my app" }));
    try t.expectEqual(.err, of(&.{ .usec = 0, .priority = 3, .message = "boom" }));
    try t.expectEqual(.warn, of(&.{ .usec = 0, .priority = 4, .message = "hmm" }));
}

test isNoise {
    const dup: Entry = .{ .usec = 0, .priority = 4, .ident = "dbus-broker-launch", .message = "Ignoring duplicate name 'x'" };
    try std.testing.expect(isNoise(&dup, .warn));
    try std.testing.expect(!isNoise(&dup, .unit));
    const other: Entry = .{ .usec = 0, .priority = 4, .ident = "foo", .message = "Ignoring duplicate name 'x'" };
    try std.testing.expect(!isNoise(&other, .warn));
}
