//! Muad-Diff
//!
//! The Patch must Flow.

const std = @import("std");
const clap = @import("clap");
const dmp = @import("dmp");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Command = enum {
    diff,
    patch,
    apply,
    @"zdelta-encode",
    @"zdelta-decode",
};

const CleanupMode = enum {
    none,
    semantic,
    lossless,
    efficiency,
};

const ColorMode = enum {
    auto,
    always,
    never,
};

const ZDeltaVersionArg = enum {
    a,
    b,
};

const plain_diff_decorations: dmp.DiffDecorations = .{
    .delete_start = "[-",
    .delete_end = "-]",
    .insert_start = "{+",
    .insert_end = "+}",
};

const diff_show_lines: usize = 3;

const main_parsers = .{
    .command = clap.parsers.enumeration(Command),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>   Command to run.
    \\
);

const diff_parsers = .{
    .FILE = clap.parsers.string,
    .MODE = clap.parsers.enumeration(CleanupMode),
    .COLOR = clap.parsers.enumeration(ColorMode),
};

const diff_params = clap.parseParamsComptime(
    \\-h, --help               Display this help and exit.
    \\    --cleanup <MODE>    Cleanup mode: none, semantic, lossless, efficiency.
    \\    --color <COLOR>     Color mode: auto, always, never.
    \\<FILE>                  Before file.
    \\<FILE>                  After file.
    \\
);

const patch_parsers = .{
    .FILE = clap.parsers.string,
};

const patch_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<FILE>      Before file.
    \\<FILE>      After file.
    \\
);

const apply_parsers = .{
    .FILE = clap.parsers.string,
};

const apply_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<FILE>      Patch file.
    \\<FILE>      Text file.
    \\
);

const zdelta_encode_parsers = .{
    .FILE = clap.parsers.string,
    .VERSION = clap.parsers.enumeration(ZDeltaVersionArg),
};

const zdelta_encode_params = clap.parseParamsComptime(
    \\-h, --help                Display this help and exit.
    \\    --version <VERSION>   ZDelta version: a or b.
    \\<FILE>                    Before file.
    \\<FILE>                    After file.
    \\
);

const zdelta_decode_parsers = .{
    .FILE = clap.parsers.string,
};

const zdelta_decode_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<FILE>      ZDelta file.
    \\<FILE>      Before file.
    \\
);

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(result: *RunResult, allocator: Allocator) void {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        result.* = .{
            .stdout = &.{},
            .stderr = &.{},
            .exit_code = 0,
        };
    }
};

const StdinSource = union(enum) {
    file: std.fs.File,
    bytes: []const u8,
};

const InputResolver = struct {
    allocator: Allocator,
    stdin: StdinSource,
    consumed_stdin: bool = false,
    owned_stdin: ?[]u8 = null,

    fn resolve(self: *InputResolver, arg: []const u8) ![]const u8 {
        if (!std.mem.eql(u8, arg, "-")) return arg;
        if (self.consumed_stdin) return error.MultipleStdinInputs;
        self.consumed_stdin = true;

        self.owned_stdin = switch (self.stdin) {
            .file => |file| try file.readToEndAlloc(self.allocator, std.math.maxInt(usize)),
            .bytes => |bytes| try self.allocator.dupe(u8, bytes),
        };
        return self.owned_stdin.?;
    }

    fn deinit(self: *InputResolver) void {
        if (self.owned_stdin) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var iter = try std.process.ArgIterator.initWithAllocator(arena_state.allocator());
    const exe_name = iter.next() orelse "muad-diff";

    const stdout_supports_color = std.io.tty.detectConfig(std.fs.File.stdout()) != .no_color;
    var result = try runIterator(
        arena_state.allocator(),
        allocator,
        &iter,
        exe_name,
        .{ .file = std.fs.File.stdin() },
        stdout_supports_color,
    );
    defer result.deinit(allocator);

    try std.fs.File.stdout().writeAll(result.stdout);
    try std.fs.File.stderr().writeAll(result.stderr);
    if (result.exit_code == 0)
        std.process.cleanExit()
    else
        std.process.exit(result.exit_code);
}

fn runForTesting(
    allocator: Allocator,
    args: []const []const u8,
    stdin_bytes: []const u8,
    stdout_supports_color: bool,
) !RunResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const exe_name = if (args.len > 0) args[0] else "muad-diff";
    var iter = clap.args.SliceIterator{
        .args = if (args.len > 1) args[1..] else &.{},
    };

    return runIterator(
        arena_state.allocator(),
        allocator,
        &iter,
        exe_name,
        .{ .bytes = stdin_bytes },
        stdout_supports_color,
    );
}

fn runIterator(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    stdin: StdinSource,
    stdout_supports_color: bool,
) !RunResult {
    var stdout_buffer = ArrayList(u8).init(allocator);
    errdefer stdout_buffer.deinit();

    var stderr_buffer = ArrayList(u8).init(allocator);
    errdefer stderr_buffer.deinit();

    const stdout_writer = stdout_buffer.writer();
    const stderr_writer = stderr_buffer.writer();

    const exit_code = dispatch(
        arena_allocator,
        allocator,
        iter,
        exe_name,
        stdin,
        stdout_supports_color,
        stdout_writer,
        stderr_writer,
    ) catch |err| {
        try stderr_writer.print("error: {s}\n", .{@errorName(err)});
        return .{
            .stdout = try stdout_buffer.toOwnedSlice(),
            .stderr = try stderr_buffer.toOwnedSlice(),
            .exit_code = 1,
        };
    };

    return .{
        .stdout = try stdout_buffer.toOwnedSlice(),
        .stderr = try stderr_buffer.toOwnedSlice(),
        .exit_code = exit_code,
    };
}

fn dispatch(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    stdin: StdinSource,
    stdout_supports_color: bool,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    var diag = clap.Diagnostic{};
    var main_res = clap.parseEx(clap.Help, &main_params, main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = arena_allocator,
        .terminating_positional = 0,
    }) catch |err| {
        try reportDiagnostic(stderr_writer, diag, err);
        try stderr_writer.writeByte('\n');
        try writeMainHelp(stderr_writer, exe_name);
        return 1;
    };
    defer main_res.deinit();

    if (main_res.args.help != 0 and main_res.positionals[0] == null) {
        try writeMainHelp(stderr_writer, exe_name);
        return 0;
    }

    const command = main_res.positionals[0] orelse {
        try writeMainHelp(stderr_writer, exe_name);
        return 1;
    };

    var inputs = InputResolver{
        .allocator = allocator,
        .stdin = stdin,
    };
    defer inputs.deinit();

    return switch (command) {
        .diff => try runDiff(
            arena_allocator,
            allocator,
            iter,
            exe_name,
            &inputs,
            stdout_supports_color,
            stdout_writer,
            stderr_writer,
        ),
        .patch => try runPatch(
            arena_allocator,
            allocator,
            iter,
            exe_name,
            &inputs,
            stdout_writer,
            stderr_writer,
        ),
        .apply => try runApply(
            arena_allocator,
            allocator,
            iter,
            exe_name,
            &inputs,
            stdout_writer,
            stderr_writer,
        ),
        .@"zdelta-encode" => try runZDeltaEncode(
            arena_allocator,
            allocator,
            iter,
            exe_name,
            &inputs,
            stdout_writer,
            stderr_writer,
        ),
        .@"zdelta-decode" => try runZDeltaDecode(
            arena_allocator,
            allocator,
            iter,
            exe_name,
            &inputs,
            stdout_writer,
            stderr_writer,
        ),
    };
}

fn runDiff(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    _: *InputResolver,
    stdout_supports_color: bool,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &diff_params, diff_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = arena_allocator,
    }) catch |err| {
        try reportDiagnostic(stderr_writer, diag, err);
        try stderr_writer.writeByte('\n');
        try writeSubcommandHelp(stderr_writer, exe_name, "diff", &diff_params);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeSubcommandHelp(stderr_writer, exe_name, "diff", &diff_params);
        return 0;
    }

    const before_path = res.positionals[0] orelse return error.MissingBeforeFile;
    const after_path = res.positionals[1] orelse return error.MissingAfterFile;
    const before = try readInputFile(allocator, before_path);
    defer allocator.free(before);
    const after = try readInputFile(allocator, after_path);
    defer allocator.free(after);

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);
    try applyCleanupMode(&diff, allocator, res.args.cleanup orelse .semantic);

    var ctx = try dmp.DiffContext.fromDiff(allocator, diff);
    defer ctx.deinit(allocator);
    const diff_name = std.fs.path.basename(before_path);

    const color_mode = res.args.color orelse .auto;
    switch (color_mode) {
        .never => _ = try ctx.render(stdout_writer, plain_diff_decorations, diff_name, diff_show_lines),
        .always => _ = try ctx.render(stdout_writer, .xterm_classic, diff_name, diff_show_lines),
        .auto => {
            if (stdout_supports_color) {
                _ = try ctx.render(stdout_writer, .xterm_classic, diff_name, diff_show_lines);
            } else {
                _ = try ctx.render(stdout_writer, plain_diff_decorations, diff_name, diff_show_lines);
            }
        },
    }
    return 0;
}

fn runPatch(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    _: *InputResolver,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &patch_params, patch_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = arena_allocator,
    }) catch |err| {
        try reportDiagnostic(stderr_writer, diag, err);
        try stderr_writer.writeByte('\n');
        try writeSubcommandHelp(stderr_writer, exe_name, "patch", &patch_params);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeSubcommandHelp(stderr_writer, exe_name, "patch", &patch_params);
        return 0;
    }

    const before_path = res.positionals[0] orelse return error.MissingBeforeFile;
    const after_path = res.positionals[1] orelse return error.MissingAfterFile;
    const before = try readInputFile(allocator, before_path);
    defer allocator.free(before);
    const after = try readInputFile(allocator, after_path);
    defer allocator.free(after);

    var patch: dmp.Patch = .default;
    defer patch.deinit(allocator);
    _ = try patch.fromTexts(allocator, before, after);

    try patch.writeTextPatch(stdout_writer);
    return 0;
}

fn runApply(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    _: *InputResolver,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &apply_params, apply_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = arena_allocator,
    }) catch |err| {
        try reportDiagnostic(stderr_writer, diag, err);
        try stderr_writer.writeByte('\n');
        try writeSubcommandHelp(stderr_writer, exe_name, "apply", &apply_params);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeSubcommandHelp(stderr_writer, exe_name, "apply", &apply_params);
        return 0;
    }

    const patch_path = res.positionals[0] orelse return error.MissingPatchFile;
    const text_path = res.positionals[1] orelse return error.MissingTextFile;
    const patch_text = try readInputFile(allocator, patch_path);
    defer allocator.free(patch_text);
    const text = try readInputFile(allocator, text_path);
    defer allocator.free(text);

    var patch: dmp.Patch = .default;
    defer patch.deinit(allocator);
    _ = try patch.fromTextPatch(allocator, patch_text);

    const result_text, const success = try patch.apply(allocator, text);
    defer allocator.free(result_text);

    try stdout_writer.writeAll(result_text);
    return if (success) 0 else 2;
}

fn runZDeltaEncode(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    _: *InputResolver,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &zdelta_encode_params, zdelta_encode_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = arena_allocator,
    }) catch |err| {
        try reportDiagnostic(stderr_writer, diag, err);
        try stderr_writer.writeByte('\n');
        try writeSubcommandHelp(stderr_writer, exe_name, "zdelta-encode", &zdelta_encode_params);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeSubcommandHelp(stderr_writer, exe_name, "zdelta-encode", &zdelta_encode_params);
        return 0;
    }

    const before_path = res.positionals[0] orelse return error.MissingBeforeFile;
    const after_path = res.positionals[1] orelse return error.MissingAfterFile;
    const before = try readInputFile(allocator, before_path);
    defer allocator.free(before);
    const after = try readInputFile(allocator, after_path);
    defer allocator.free(after);

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);

    const version = switch (res.args.version orelse .b) {
        .a => dmp.ZDeltaVersion.a,
        .b => dmp.ZDeltaVersion.b,
    };
    const encoded = try diff.toZDelta(allocator, version);
    defer allocator.free(encoded);
    try stdout_writer.writeAll(encoded);
    return 0;
}

fn runZDeltaDecode(
    arena_allocator: Allocator,
    allocator: Allocator,
    iter: anytype,
    exe_name: []const u8,
    _: *InputResolver,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &zdelta_decode_params, zdelta_decode_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = arena_allocator,
    }) catch |err| {
        try reportDiagnostic(stderr_writer, diag, err);
        try stderr_writer.writeByte('\n');
        try writeSubcommandHelp(stderr_writer, exe_name, "zdelta-decode", &zdelta_decode_params);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try writeSubcommandHelp(stderr_writer, exe_name, "zdelta-decode", &zdelta_decode_params);
        return 0;
    }

    const zdelta_path = res.positionals[0] orelse return error.MissingZDeltaFile;
    const before_path = res.positionals[1] orelse return error.MissingBeforeFile;
    const zdelta = try readInputFile(allocator, zdelta_path);
    defer allocator.free(zdelta);
    const before = try readInputFile(allocator, before_path);
    defer allocator.free(before);

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.fromZDelta(allocator, before, zdelta);

    const after = try diff.afterText(allocator);
    defer allocator.free(after);
    try stdout_writer.writeAll(after);
    return 0;
}

fn applyCleanupMode(
    diff: *dmp.Diff,
    allocator: Allocator,
    mode: CleanupMode,
) !void {
    switch (mode) {
        .none => {},
        .semantic => _ = try diff.cleanupSemantic(allocator),
        .lossless => {
            _ = try diff.cleanupSemantic(allocator);
            _ = try diff.cleanupSemanticLossless(allocator);
        },
        .efficiency => _ = try diff.cleanupEfficiency(allocator),
    }
}

fn readInputFile(allocator: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

fn writeMainHelp(writer: anytype, exe_name: []const u8) !void {
    try writer.print("Usage: {s} <command> [options]\n\n", .{exe_name});
    try writeClapHelp(writer, &main_params);
    try writer.writeAll(
        "\n\nCommands:\n" ++
            "    diff             Compute a diff and print a human-readable result.\n" ++
            "    patch            Build textual patch output from two texts.\n" ++
            "    apply            Apply patch text to input text.\n" ++
            "    zdelta-encode    Encode a diff as zdelta.\n" ++
            "    zdelta-decode    Decode zdelta and print the reconstructed after-text.\n",
    );
}

fn writeSubcommandHelp(
    writer: anytype,
    exe_name: []const u8,
    subcommand: []const u8,
    comptime params: anytype,
) !void {
    try writer.print("Usage: {s} {s}", .{ exe_name, subcommand });
    try writeClapUsage(writer, params);
    try writer.writeAll("\n\n");
    try writeClapHelp(writer, params);
}

fn reportDiagnostic(writer: anytype, diag: clap.Diagnostic, err: anyerror) !void {
    var scratch: [1024]u8 = undefined;
    var adapter = writer.adaptToNewApi(&scratch);
    try diag.report(&adapter.new_interface, err);
    try adapter.new_interface.flush();
    if (adapter.err) |write_err| return write_err;
}

fn writeClapHelp(writer: anytype, comptime params: anytype) !void {
    var scratch: [1024]u8 = undefined;
    var adapter = writer.adaptToNewApi(&scratch);
    try clap.help(&adapter.new_interface, clap.Help, params, .{});
    try adapter.new_interface.flush();
    if (adapter.err) |write_err| return write_err;
}

fn writeClapUsage(writer: anytype, comptime params: anytype) !void {
    var scratch: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&scratch);
    try clap.usage(&adapter.new_interface, clap.Help, params);
    try adapter.new_interface.flush();
    if (adapter.err) |write_err| return write_err;
}

test "top-level help goes to stderr" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "muad-diff", "--help" }, "", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Commands:"));
}

test "diff command prints a readable diff" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "before.txt", .data = "cat" });
    try tmp.dir.writeFile(.{ .sub_path = "after.txt", .data = "cart" });

    const before_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/before.txt", .{tmp.sub_path});
    defer allocator.free(before_path);
    const after_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/after.txt", .{tmp.sub_path});
    defer allocator.free(after_path);

    var result = try runForTesting(
        allocator,
        &.{ "muad-diff", "diff", before_path, after_path },
        "",
        false,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "diff -- before.txt\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "\n ca{+r+}t"));
}

test "diff command reads files as positionals" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "before.txt", .data = "alpha" });
    try tmp.dir.writeFile(.{ .sub_path = "after.txt", .data = "alphaβ" });

    const before_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/before.txt", .{tmp.sub_path});
    defer allocator.free(before_path);
    const after_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/after.txt", .{tmp.sub_path});
    defer allocator.free(after_path);

    var result = try runForTesting(
        allocator,
        &.{ "muad-diff", "diff", before_path, after_path },
        "",
        false,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "diff -- before.txt\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, " alpha{+β+}"));
}

test "diff requires both file positionals" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(
        allocator,
        &.{ "muad-diff", "diff", "before.txt" },
        "",
        false,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "MissingAfterFile"));
}

test "invalid cleanup value is reported" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "before.txt", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "after.txt", .data = "b" });

    const before_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/before.txt", .{tmp.sub_path});
    defer allocator.free(before_path);
    const after_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/after.txt", .{tmp.sub_path});
    defer allocator.free(after_path);

    var result = try runForTesting(
        allocator,
        &.{ "muad-diff", "diff", "--cleanup", "weird", before_path, after_path },
        "",
        false,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "--cleanup"));
}

test "patch emits patch text" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "before.txt", .data = "Καλημέρα" });
    try tmp.dir.writeFile(.{ .sub_path = "after.txt", .data = "Καλησπέρα" });

    const before_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/before.txt", .{tmp.sub_path});
    defer allocator.free(before_path);
    const after_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/after.txt", .{tmp.sub_path});
    defer allocator.free(after_path);

    var result = try runForTesting(
        allocator,
        &.{ "muad-diff", "patch", before_path, after_path },
        "",
        false,
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "λη"));
}

test "apply returns partial-apply exit code" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "before.txt", .data = "The quick brown fox jumps over the lazy dog." });
    try tmp.dir.writeFile(.{ .sub_path = "after.txt", .data = "That quick brown fox jumped over a lazy dog." });
    try tmp.dir.writeFile(.{ .sub_path = "text.txt", .data = "I am the very model of a modern major general." });

    const before_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/before.txt", .{tmp.sub_path});
    defer allocator.free(before_path);
    const after_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/after.txt", .{tmp.sub_path});
    defer allocator.free(after_path);
    const text_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/text.txt", .{tmp.sub_path});
    defer allocator.free(text_path);

    var patch_result = try runForTesting(
        allocator,
        &.{
            "muad-diff",
            "patch",
            before_path,
            after_path,
        },
        "",
        false,
    );
    defer patch_result.deinit(allocator);

    try tmp.dir.writeFile(.{ .sub_path = "change.patch", .data = patch_result.stdout });
    const patch_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/change.patch", .{tmp.sub_path});
    defer allocator.free(patch_path);

    var apply_result = try runForTesting(
        allocator,
        &.{
            "muad-diff",
            "apply",
            patch_path,
            text_path,
        },
        "",
        false,
    );
    defer apply_result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 2), apply_result.exit_code);
    try std.testing.expect(apply_result.stdout.len != 0);
}

test "zdelta encode and decode round-trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "before.txt", .data = "Καλημέρα" });
    try tmp.dir.writeFile(.{ .sub_path = "after.txt", .data = "Καλησπέρα" });

    const before_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/before.txt", .{tmp.sub_path});
    defer allocator.free(before_path);
    const after_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/after.txt", .{tmp.sub_path});
    defer allocator.free(after_path);

    var encoded = try runForTesting(
        allocator,
        &.{
            "muad-diff",
            "zdelta-encode",
            before_path,
            after_path,
        },
        "",
        false,
    );
    defer encoded.deinit(allocator);

    try tmp.dir.writeFile(.{ .sub_path = "change.zdelta", .data = encoded.stdout });
    const zdelta_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/change.zdelta", .{tmp.sub_path});
    defer allocator.free(zdelta_path);

    var decoded = try runForTesting(
        allocator,
        &.{
            "muad-diff",
            "zdelta-decode",
            zdelta_path,
            before_path,
        },
        "",
        false,
    );
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), encoded.exit_code);
    try std.testing.expectEqual(@as(u8, 0), decoded.exit_code);
    try std.testing.expectEqualStrings("Καλησπέρα", decoded.stdout);
}
