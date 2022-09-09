const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "1d9a976f1088cb96160c676120f2ed778ab69a19",
    });

    const exe = b.addExecutable("videoserver", "videoserver.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    exe.step.dependOn(&zigx_repo.step);
    exe.addPackagePath("x", b.pathJoin(&.{ zigx_repo.getPath(&exe.step), "x.zig" }));

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
