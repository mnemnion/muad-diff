// Build script for muad-diff
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const dmp_module = b.addModule("dmp", .{
        .root_source_file = b.path("src/dmp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const module_unit_tests = b.addTest(.{
        .root_module = dmp_module,
        .filters = test_filters,
    });

    const run_module_unit_tests = b.addRunArtifact(module_unit_tests);

    const corpus_tests_module = b.createModule(.{
        .root_source_file = b.path("src/corpus_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const corpus_unit_tests = b.addTest(.{
        .root_module = corpus_tests_module,
        .filters = test_filters,
    });

    const run_corpus_unit_tests = b.addRunArtifact(corpus_unit_tests);

    // const exe_unit_tests = b.addTest(.{
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .filters = test_filters,
    // });
    //
    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_module_unit_tests.step);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_module.addImport("dmp", dmp_module);

    if (b.lazyDependency("clap", .{
        .target = target,
        .optimize = optimize,
    })) |clap_dep| {
        exe_module.addImport("dmp", dmp_module);
        exe_module.addImport("clap", clap_dep.module("clap"));
        cli_test_module.addImport("clap", clap_dep.module("clap"));
    }

    const exe = b.addExecutable(.{
        .name = "muad-diff",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the muad-diff CLI");
    run_step.dependOn(&run_cmd.step);

    const cli_unit_tests = b.addTest(.{
        .root_module = cli_test_module,
        .filters = test_filters,
    });

    const run_cli_unit_tests = b.addRunArtifact(cli_unit_tests);
    test_step.dependOn(&run_cli_unit_tests.step);

    const corpus_step = b.step("corpus", "Run offline corpus-backed tests");
    corpus_step.dependOn(&run_corpus_unit_tests.step);
    test_step.dependOn(&run_corpus_unit_tests.step);

    const refresh_corpus = b.addSystemCommand(&.{
        "/Users/atman/Dropbox/deck/m/skills/.venv/bin/python",
    });
    refresh_corpus.addFileArg(b.path("tools/refresh_corpus.py"));

    const refresh_corpus_step = b.step(
        "refresh-corpus",
        "Refresh checked-in Wikipedia corpus fixtures",
    );
    refresh_corpus_step.dependOn(&refresh_corpus.step);

    const run_kcov = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--exclude-line=unreachable,expect(false),@panic,kcov-defer-error,kcov-test-cleanup,kcov-miss",
    });
    run_kcov.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
    const coverage_output = run_kcov.addOutputDirectoryArg(".");

    // Pick your coverage entry point here:
    run_kcov.addArtifactArg(module_unit_tests);

    run_kcov.enableTestRunnerMode();

    const install_coverage = b.addInstallDirectory(.{
        .source_dir = coverage_output,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = "",
    });

    const coverage_step = b.step("coverage", "Generate coverage (kcov must be installed)");
    coverage_step.dependOn(&install_coverage.step);
}
