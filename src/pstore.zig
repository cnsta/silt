const std = @import("std");
const Io = std.Io;

pub const paths = [_][]const u8{ "/sys/fs/pstore", "/var/lib/systemd/pstore" };

pub const Status = union(enum) {
    /// Nothing in the directories that could be read, `denied` couldn't be.
    empty: struct { denied: usize },
    /// Records found in `paths[dir]`. They aren't tied to a boot.
    found: struct { dir: usize, count: usize },
};

pub fn check(io: Io) Status {
    var denied: usize = 0;
    for (paths, 0..) |path, i| {
        var dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.AccessDenied, error.PermissionDenied => denied += 1,
                else => {},
            }
            continue;
        };
        defer dir.close(io);
        var count: usize = 0;
        var it = dir.iterate();
        while (it.next(io) catch null) |_| count += 1;
        if (count > 0) return .{ .found = .{ .dir = i, .count = count } };
    }
    return .{ .empty = .{ .denied = denied } };
}
