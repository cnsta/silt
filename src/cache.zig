//! The dedup keys of finished boots, for the "new" marks. A finished boot's
//! journal doesn't change, so reading its classified entries once is enough:
//! a flood in an old boot then costs nothing on later starts. Lives in
//! `$XDG_CACHE_HOME/silt` (else `~/.cache/silt`), one file per boot. Any
//! failure just means reading the journal again.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Journal = @import("Journal.zig");

const Cache = @This();

io: Io,
dir: Io.Dir,

/// A changed layout here, or changed rules for which entries count and how
/// they hash, makes every file stale: a new silt never trusts an old one's keys.
const format: u64 = format: {
    @setEvalBranchQuota(10_000_000);
    const layout = "1";
    break :format std.hash.Wyhash.hash(0, layout ++ @embedFile("classify.zig") ++ @embedFile("dedup.zig") ++ @embedFile("Journal.zig"));
};

const Header = extern struct {
    magic: [8]u8 = "silt-key".*,
    format: u64 = format,
    /// The boot as it was read. A vacuumed journal moves `first`.
    first: u64,
    last: u64,
    count: u64,
};

/// Files larger than this aren't read (a boot with 8M distinct problems).
const max_bytes = 64 << 20;

/// Null if there's no usable cache directory.
pub fn open(io: Io, environ: *const std.process.Environ.Map) ?Cache {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (environ.get("XDG_CACHE_HOME")) |x| if (x.len > 0 and x[0] == '/')
        std.fmt.bufPrint(&path_buf, "{s}/silt", .{x}) catch return null
    else
        null else null;
    const full = path orelse blk: {
        const home = environ.get("HOME") orelse return null;
        if (home.len == 0 or home[0] != '/') return null;
        break :blk std.fmt.bufPrint(&path_buf, "{s}/.cache/silt", .{home}) catch return null;
    };
    const root = Io.Dir.openDirAbsolute(io, "/", .{}) catch return null;
    defer root.close(io);
    const dir = root.createDirPathOpen(io, full[1..], .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true },
    }) catch return null;
    return .{ .io = io, .dir = dir };
}

pub fn close(self: Cache) void {
    self.dir.close(self.io);
}

/// Adds `boot`'s keys to `known`. False if they aren't cached (or are stale).
pub fn load(self: Cache, gpa: Allocator, boot: *const Journal.Boot, known: *std.AutoHashMapUnmanaged(u64, void)) Allocator.Error!bool {
    const name = fileName(boot);
    const bytes = self.dir.readFileAllocOptions(self.io, &name, gpa, .limited(max_bytes), .of(u64), null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(bytes);
    const keys = parse(bytes, boot) orelse return false;
    try known.ensureUnusedCapacity(gpa, @intCast(keys.len));
    for (keys) |k| known.putAssumeCapacity(k, {});
    return true;
}

/// Best effort: a failure only means reading the journal next time.
pub fn store(self: Cache, gpa: Allocator, boot: *const Journal.Boot, keys: []const u64) void {
    const bytes = serialize(gpa, boot, keys) catch return;
    defer gpa.free(bytes);
    const name = fileName(boot);
    var file = self.dir.createFileAtomic(self.io, &name, .{ .replace = true, .permissions = .fromMode(0o600) }) catch return;
    defer file.deinit(self.io);
    file.file.writeStreamingAll(self.io, bytes) catch return;
    file.replace(self.io) catch return;
}

/// Deletes the files of boots the journal no longer has.
pub fn prune(self: Cache, boots: []const Journal.Boot) void {
    var it = self.dir.iterate();
    while (it.next(self.io) catch return) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        const id = entry.name[0 .. entry.name.len - suffix.len];
        const kept = for (boots) |*b| {
            if (std.mem.eql(u8, &b.id, id)) break true;
        } else false;
        if (!kept) self.dir.deleteFile(self.io, entry.name) catch {};
    }
}

const suffix = ".keys";

fn fileName(boot: *const Journal.Boot) [32 + suffix.len]u8 {
    return boot.id ++ suffix.*;
}

/// Sorted and without duplicates, so files are deterministic.
fn serialize(gpa: Allocator, boot: *const Journal.Boot, keys: []const u64) Allocator.Error![]u8 {
    const sorted = try gpa.dupe(u64, keys);
    defer gpa.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    var n: usize = 0;
    for (sorted, 0..) |k, i| {
        if (i > 0 and k == sorted[n - 1]) continue;
        sorted[n] = k;
        n += 1;
    }
    const header: Header = .{ .first = boot.first, .last = boot.last, .count = n };
    const bytes = try gpa.alloc(u8, @sizeOf(Header) + n * @sizeOf(u64));
    @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(bytes[@sizeOf(Header)..], std.mem.sliceAsBytes(sorted[0..n]));
    return bytes;
}

/// The keys in `bytes`, if it's a current file for `boot`.
fn parse(bytes: []align(@alignOf(u64)) const u8, boot: *const Journal.Boot) ?[]const u64 {
    if (bytes.len < @sizeOf(Header)) return null;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);
    const want: Header = .{ .first = boot.first, .last = boot.last, .count = header.count };
    if (!std.meta.eql(header, want)) return null;
    const body = bytes[@sizeOf(Header)..];
    if (body.len != header.count * @sizeOf(u64)) return null;
    return @alignCast(std.mem.bytesAsSlice(u64, body));
}

test "round trip and staleness" {
    const gpa = std.testing.allocator;
    const boot: Journal.Boot = .{ .id = "0123456789abcdef0123456789abcdef".*, .first = 10, .last = 20, .clean = true };
    const bytes = try serialize(gpa, &boot, &.{ 3, 1, 3, 2 });
    defer gpa.free(bytes);
    const aligned = try gpa.alignedAlloc(u8, .of(u64), bytes.len);
    defer gpa.free(aligned);
    @memcpy(aligned, bytes);

    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, parse(aligned, &boot).?);
    var moved = boot;
    moved.first = 11;
    try std.testing.expect(parse(aligned, &moved) == null);
    try std.testing.expect(parse(aligned[0 .. aligned.len - 1], &boot) == null);
    aligned[0] = 'x';
    try std.testing.expect(parse(aligned, &boot) == null);
}

test "files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cache: Cache = .{ .io = io, .dir = tmp.dir };
    const a: Journal.Boot = .{ .id = @splat('a'), .first = 1, .last = 2, .clean = true };
    const b: Journal.Boot = .{ .id = @splat('b'), .first = 3, .last = 4, .clean = true };

    var known: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer known.deinit(gpa);
    try std.testing.expect(!try cache.load(gpa, &a, &known));
    cache.store(gpa, &a, &.{ 7, 8 });
    cache.store(gpa, &b, &.{9});
    try std.testing.expect(try cache.load(gpa, &a, &known));
    try std.testing.expectEqual(2, known.count());

    cache.prune(&.{b});
    try std.testing.expect(!try cache.load(gpa, &a, &known));
    try std.testing.expect(try cache.load(gpa, &b, &known));
    try std.testing.expectEqual(3, known.count());
}
