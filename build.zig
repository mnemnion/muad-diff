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

    const memex_dep = b.dependency("memex", .{
        .target = target,
        .optimize = optimize,
    });
    const memex_module = memex_dep.module("memex");
    dmp_module.addImport("memex", memex_module);

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
    const dmp_test_step = b.step("dmp-test", "Run only the dmp module tests");
    dmp_test_step.dependOn(&run_module_unit_tests.step);

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

    const corpus_contract_mod = b.createModule(.{
        .root_source_file = b.path("corpus/diff_contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    const delta_maker_mod = b.createModule(.{
        .root_source_file = b.path("tools/delta_maker.zig"),
        .target = target,
        .optimize = optimize,
    });
    delta_maker_mod.addImport("dmp", dmp_module);
    delta_maker_mod.addImport("corpus_contract", corpus_contract_mod);

    const all_tests_mod = b.createModule(.{
        .root_source_file = b.path("all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    all_tests_mod.addImport("corpus_contract", corpus_contract_mod);
    all_tests_mod.addImport("memex", memex_module);

    const all_unit_tests = b.addTest(.{
        .name = "all",
        .root_module = all_tests_mod,
        .filters = test_filters,
    });

    const run_all_unit_tests = b.addRunArtifact(all_unit_tests);
    test_step.dependOn(&run_all_unit_tests.step);

    const ztap_dep = b.dependency("ztap", .{
        .target = target,
        .optimize = optimize,
        .timed = true,
        .threaded = true,
    });

    const ztap_unit_tests = b.addTest(.{
        .name = "ztap-run",
        .root_module = all_tests_mod,
        .filters = test_filters,
        .test_runner = .{
            .path = ztap_dep.namedLazyPath("runner"),
            .mode = .simple,
        },
    });
    ztap_unit_tests.root_module.addImport("ztap", ztap_dep.module("ztap"));

    const run_ztap_unit_tests = b.addRunArtifact(ztap_unit_tests);
    run_ztap_unit_tests.has_side_effects = true;

    const ztap_step = b.step("ztap", "Run tests with timed, threaded ZTAP output");
    ztap_step.dependOn(&run_ztap_unit_tests.step);

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

    const delta_maker_unit_tests = b.addTest(.{
        .root_module = delta_maker_mod,
        .filters = test_filters,
    });

    const run_delta_maker_unit_tests = b.addRunArtifact(delta_maker_unit_tests);
    test_step.dependOn(&run_delta_maker_unit_tests.step);

    const corpus_step = b.step("corpus", "Run offline corpus-backed tests");
    corpus_step.dependOn(&run_corpus_unit_tests.step);
    b.default_step = dmp_test_step;

    const refresh_corpus = b.addSystemCommand(&.{
        "/Users/atman/Dropbox/deck/m/skills/.venv/bin/python",
    });
    refresh_corpus.addFileArg(b.path("tools/refresh_corpus.py"));
    if (b.args) |args| {
        refresh_corpus.addArgs(args);
    }

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
