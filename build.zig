const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });
    addNixIncludePaths(b, c);

    const exe = b.addExecutable(.{
        .name = "silt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = c.createModule() },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("libsystemd", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run silt").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addNixIncludePaths(b: *std.Build, tc: *std.Build.Step.TranslateC) void {
    const cflags = b.graph.environ_map.get("NIX_CFLAGS_COMPILE") orelse return;
    var it = std.mem.tokenizeScalar(u8, cflags, ' ');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "-isystem")) {
            if (it.next()) |path| tc.addSystemIncludePath(.{ .cwd_relative = path });
        }
    }
}
