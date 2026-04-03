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

    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_module_unit_tests.step);

    const muaddiff_mod = b.createModule(.{
        .root_source_file = b.path("src/muad_diff.zig"),
        .target = target,
        .optimize = optimize,
    });
    muaddiff_mod.addImport("dmp", dmp_module);

    const delta_tool_mod = b.createModule(.{
        .root_source_file = b.path("src/delta_tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    delta_tool_mod.addImport("dmp", dmp_module);

    const delta_maker_mod = b.createModule(.{
        .root_source_file = b.path("tools/delta_maker.zig"),
        .target = target,
        .optimize = optimize,
    });
    delta_maker_mod.addImport("dmp", dmp_module);

    const all_tests_mod = b.createModule(.{
        .root_source_file = b.path("all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ztap_dep = b.dependency("ztap", .{
        .target = b.graph.host,
        .optimize = optimize,
        .timed = true,
    });

    if (b.lazyDependency("clap", .{
        .target = target,
        .optimize = optimize,
    })) |clap_dep| {
        muaddiff_mod.addImport("clap", clap_dep.module("clap"));
        all_tests_mod.addImport("clap", clap_dep.module("clap"));
    }

    const muad_diff = b.addExecutable(.{
        .name = "muad-diff",
        .root_module = muaddiff_mod,
    });

    b.installArtifact(muad_diff);

    const run_cmd = b.addRunArtifact(muad_diff);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the muad-diff CLI");
    run_step.dependOn(&run_cmd.step);

    const delta_tool = b.addExecutable(.{
        .name = "delta-tool",
        .root_module = delta_tool_mod,
    });

    b.installArtifact(delta_tool);

    const run_delta_tool = b.addRunArtifact(delta_tool);
    run_delta_tool.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_delta_tool.addArgs(args);
    }

    const delta_tool_step = b.step("delta-tool", "Run the specialized interactive zdelta corpus tool");
    delta_tool_step.dependOn(&run_delta_tool.step);

    const delta_maker = b.addExecutable(.{
        .name = "delta-maker",
        .root_module = delta_maker_mod,
    });

    const run_delta_maker = b.addRunArtifact(delta_maker);
    if (b.args) |args| {
        run_delta_maker.addArgs(args);
    }

    const delta_maker_step = b.step(
        "delta-maker",
        "Build batch zdelta set files from a wiki corpus",
    );
    delta_maker_step.dependOn(&run_delta_maker.step);

    const mdiff_unit_tests = b.addTest(.{
        .root_module = muaddiff_mod,
        .filters = test_filters,
    });

    const run_mdiff_unit_tests = b.addRunArtifact(mdiff_unit_tests);
    test_step.dependOn(&run_mdiff_unit_tests.step);

    const delta_tool_unit_tests = b.addTest(.{
        .root_module = delta_tool_mod,
        .filters = test_filters,
    });

    const run_delta_tool_unit_tests = b.addRunArtifact(delta_tool_unit_tests);
    test_step.dependOn(&run_delta_tool_unit_tests.step);

    const delta_maker_unit_tests = b.addTest(.{
        .root_module = delta_maker_mod,
        .filters = test_filters,
    });

    const run_delta_maker_unit_tests = b.addRunArtifact(delta_maker_unit_tests);
    test_step.dependOn(&run_delta_maker_unit_tests.step);

    const corpus_step = b.step("corpus", "Run offline corpus-backed tests");
    corpus_step.dependOn(&run_corpus_unit_tests.step);
    test_step.dependOn(&run_corpus_unit_tests.step);

    const ztap_unit_tests = b.addTest(.{
        .name = "ztap-all",
        .root_module = all_tests_mod,
        .filters = test_filters,
        .test_runner = .{ .path = ztap_dep.namedLazyPath("runner"), .mode = .simple },
    });
    ztap_unit_tests.root_module.addImport("ztap", ztap_dep.module("ztap"));
    const run_ztap_unit_tests = b.addRunArtifact(ztap_unit_tests);

    const ztap_step = b.step("ztap", "Run tests with ZTAP");
    ztap_step.dependOn(&run_ztap_unit_tests.step);

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
