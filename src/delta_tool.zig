//! Specialized interactive zdelta corpus tool.

const std = @import("std");
const dmp = @import("dmp");
const zdelta_context = @import("zdelta/context.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const DeltaManager = dmp.DeltaManager;
const corpus_diff_root = "corpus/diff";
const default_runs_path = corpus_diff_root ++ "/delta_tool.runs";

const plain_diff_decorations: dmp.DiffDecorations = .{
    .delete_start = "[-",
    .delete_end = "-]",
    .insert_start = "{+",
    .insert_end = "+}",
};

const OutputClient = struct {
    allocator: Allocator,
    line_ending: []const u8,

    fn init(allocator: Allocator, raw_mode: bool) OutputClient {
        return .{
            .allocator = allocator,
            .line_ending = if (raw_mode) "\r\n" else "\n",
        };
    }

    fn writeLineEnding(self: OutputClient, writer: anytype) !void {
        try writer.writeAll(self.line_ending);
    }

    fn writeText(self: OutputClient, writer: anytype, text: []const u8) !void {
        if (self.line_ending.len == 1) {
            try writer.writeAll(text);
            return;
        }

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |idx| {
            try writer.writeAll(text[start..idx]);
            try writer.writeAll(self.line_ending);
            start = idx + 1;
        }
        try writer.writeAll(text[start..]);
    }

    fn print(self: OutputClient, writer: anytype, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.writeText(writer, text);
    }
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    runs: ?[]u8 = null,
    exit_code: u8,

    fn deinit(result: *RunResult, allocator: Allocator) void {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        if (result.runs) |runs| allocator.free(runs);
        result.* = .{
            .stdout = &.{},
            .stderr = &.{},
            .runs = null,
            .exit_code = 0,
        };
    }
};

const StdinSource = union(enum) {
    file: std.fs.File,
    bytes: []const u8,
};

const PromptInput = union(enum) {
    live: StdinSource,
    replay: []const u8,
};

const RunOptions = struct {
    use_pager: bool,
    runs_path: ?[]const u8 = default_runs_path,
    timestamp_secs: ?u64 = null,
};

const ParsedArgs = struct {
    replay_script: ?[]const u8 = null,
    start_revision_arg: []const u8,
    end_revision_arg: []const u8,
};

const DeltaPromptInput = struct {
    action: DeltaPromptAction,
    canonical: ?u8,
};

const EditPromptInput = struct {
    action: EditPromptAction,
    canonical: ?u8,
};

const ParsedDeltaPrompt = struct {
    action: DeltaPromptAction,
    canonical: u8,
};

const ParsedEditPrompt = struct {
    action: EditPromptAction,
    canonical: u8,
};

fn PromptParseResult(comptime Action: type) type {
    return union(enum) {
        accepted: if (Action == DeltaPromptAction) ParsedDeltaPrompt else ParsedEditPrompt,
        invalid,
        incomplete,
    };
}

const DeltaPromptParser = struct {
    fn feed(_: *DeltaPromptParser, byte: u8) PromptParseResult(DeltaPromptAction) {
        return switch (byte) {
            'y' => .{ .accepted = .{ .action = .apply, .canonical = 'y' } },
            'n' => .{ .accepted = .{ .action = .skip, .canonical = 'n' } },
            's' => .{ .accepted = .{ .action = .split, .canonical = 's' } },
            'q' => .{ .accepted = .{ .action = .quit, .canonical = 'q' } },
            '?' => .{ .accepted = .{ .action = .help, .canonical = '?' } },
            else => .invalid,
        };
    }
};

const EditPromptParser = struct {
    fn feed(_: *EditPromptParser, byte: u8) PromptParseResult(EditPromptAction) {
        return switch (byte) {
            'y' => .{ .accepted = .{ .action = .apply, .canonical = 'y' } },
            'n' => .{ .accepted = .{ .action = .skip, .canonical = 'n' } },
            'a' => .{ .accepted = .{ .action = .apply_rest, .canonical = 'a' } },
            'd' => .{ .accepted = .{ .action = .skip_rest, .canonical = 'd' } },
            'q' => .{ .accepted = .{ .action = .quit, .canonical = 'q' } },
            '?' => .{ .accepted = .{ .action = .help, .canonical = '?' } },
            else => .invalid,
        };
    }
};

const RawTerminalGuard = struct {
    file: ?std.fs.File = null,
    original_state: ?std.posix.termios = null,

    fn init(stdin: StdinSource) !RawTerminalGuard {
        const file = switch (stdin) {
            .file => |file| file,
            .bytes => return .{},
        };
        const original_state = std.posix.tcgetattr(file.handle) catch |err| switch (err) {
            error.NotATerminal => return .{},
            else => return err,
        };

        var raw = original_state;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(file.handle, .DRAIN, raw);

        return .{
            .file = file,
            .original_state = original_state,
        };
    }

    fn deinit(self: *const RawTerminalGuard) void {
        if (self.file) |file| {
            std.posix.tcsetattr(file.handle, .DRAIN, self.original_state.?) catch {};
        }
    }

    fn isActive(self: RawTerminalGuard) bool {
        return self.file != null;
    }
};

const PromptSource = struct {
    input: PromptInput,
    cursor: usize = 0,

    fn readLiveByte(self: *PromptSource) !?u8 {
        const stdin = switch (self.input) {
            .live => |stdin| stdin,
            .replay => unreachable,
        };

        switch (stdin) {
            .bytes => |bytes| {
                if (self.cursor >= bytes.len) return null;
                const byte = bytes[self.cursor];
                self.cursor += 1;
                return byte;
            },
            .file => |file| {
                var byte_buf: [1]u8 = undefined;
                const read_len = try file.read(byte_buf[0..]);
                if (read_len == 0) return null;
                return byte_buf[0];
            },
        }
    }

    fn readReplayCommand(self: *PromptSource) !u8 {
        const script = switch (self.input) {
            .live => unreachable,
            .replay => |script| script,
        };
        if (self.cursor >= script.len) return error.ReplayScriptExhausted;
        const command = script[self.cursor];
        self.cursor += 1;
        return command;
    }

    fn readDeltaInput(self: *PromptSource, writer: anytype, output: OutputClient) !?DeltaPromptInput {
        switch (self.input) {
            .live => {
                var parser = DeltaPromptParser{};
                while (true) {
                    const byte = (try self.readLiveByte()) orelse return null;
                    switch (parser.feed(byte)) {
                        .accepted => |accepted| {
                            try writer.writeByte(accepted.canonical);
                            try output.writeLineEnding(writer);
                            try writer.flush();
                            return .{
                                .action = accepted.action,
                                .canonical = accepted.canonical,
                            };
                        },
                        .invalid => {
                            try writer.writeByte(7);
                            try writer.flush();
                        },
                        .incomplete => {},
                    }
                }
            },
            .replay => {
                const command = try self.readReplayCommand();
                const parsed = parseReplayDeltaPromptAction(command) orelse return error.InvalidReplayDeltaCommand;
                return .{
                    .action = parsed.action,
                    .canonical = parsed.canonical,
                };
            },
        }
    }

    fn readEditInput(self: *PromptSource, writer: anytype, output: OutputClient) !?EditPromptInput {
        switch (self.input) {
            .live => {
                var parser = EditPromptParser{};
                while (true) {
                    const byte = (try self.readLiveByte()) orelse return null;
                    switch (parser.feed(byte)) {
                        .accepted => |accepted| {
                            try writer.writeByte(accepted.canonical);
                            try output.writeLineEnding(writer);
                            try writer.flush();
                            return .{
                                .action = accepted.action,
                                .canonical = accepted.canonical,
                            };
                        },
                        .invalid => {
                            try writer.writeByte(7);
                            try writer.flush();
                        },
                        .incomplete => {},
                    }
                }
            },
            .replay => {
                const command = try self.readReplayCommand();
                const parsed = parseReplayEditPromptAction(command) orelse return error.InvalidReplayEditCommand;
                return .{
                    .action = parsed.action,
                    .canonical = parsed.canonical,
                };
            },
        }
    }
};

const RunRecorder = struct {
    file: std.fs.File,
    last_command: ?u8 = null,

    fn init(
        runs_path: []const u8,
        timestamp_secs: u64,
        start_revision: usize,
        end_revision: usize,
    ) !RunRecorder {
        var file = if (std.fs.path.isAbsolute(runs_path))
            try std.fs.createFileAbsolute(runs_path, .{ .truncate = false })
        else
            try std.fs.cwd().createFile(runs_path, .{ .truncate = false });
        errdefer file.close();

        try file.seekFromEnd(0);

        var recorder: RunRecorder = .{
            .file = file,
        };
        try recorder.writeHeader(timestamp_secs, start_revision, end_revision);
        return recorder;
    }

    fn deinit(recorder: *RunRecorder) void {
        recorder.file.close();
        recorder.* = undefined;
    }

    fn writeHeader(
        recorder: *RunRecorder,
        timestamp_secs: u64,
        start_revision: usize,
        end_revision: usize,
    ) !void {
        var timestamp_buf: [32]u8 = undefined;
        const timestamp_text = try formatUtcTimestamp(&timestamp_buf, timestamp_secs);

        var header_buf: [96]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "\n{s}: {d} {d}\n", .{
            timestamp_text,
            start_revision,
            end_revision,
        });
        try recorder.file.writeAll(header);
        try recorder.file.sync();
    }

    fn recordCommand(recorder: *RunRecorder, command: u8) !void {
        const bytes = [1]u8{command};
        try recorder.file.writeAll(&bytes);
        try recorder.file.sync();
        recorder.last_command = command;
    }

    fn ensureSuccessQuit(recorder: *RunRecorder) !void {
        if (recorder.last_command == 'q') return;
        try recorder.recordCommand('q');
    }
};

const CorpusRevision = struct {
    ordinal: usize,
    relative_path: []u8,
    body: []u8,
    zdelta: ?[]u8 = null,

    fn deinit(revision: *CorpusRevision, allocator: Allocator) void {
        allocator.free(revision.relative_path);
        allocator.free(revision.body);
        if (revision.zdelta) |delta| allocator.free(delta);
        revision.* = undefined;
    }
};

const CorpusSelection = struct {
    revisions: []CorpusRevision,

    fn deinit(selection: *CorpusSelection, allocator: Allocator) void {
        for (selection.revisions) |*revision| revision.deinit(allocator);
        allocator.free(selection.revisions);
        selection.* = undefined;
    }
};

const ZDeltaSummary = struct {
    applied_deltas: usize = 0,
    skipped_deltas: usize = 0,
    partial_deltas: usize = 0,
    applied_edits: usize = 0,
    skipped_edits: usize = 0,
    processed_revision: usize = 0,
    quit_early: bool = false,
};

const DeltaPromptAction = enum {
    apply,
    skip,
    split,
    quit,
    help,
    invalid,
};

const EditPromptAction = enum {
    apply,
    skip,
    apply_rest,
    skip_rest,
    quit,
    help,
    invalid,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const args = try std.process.argsAlloc(arena_state.allocator());
    const exe_name = if (args.len > 0) args[0] else "delta-tool";
    const stdout_supports_color = std.io.tty.detectConfig(std.fs.File.stdout()) != .no_color;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);

    const exit_code = run(
        allocator,
        args[1..],
        exe_name,
        .{ .file = std.fs.File.stdin() },
        stdout_supports_color,
        .{ .use_pager = true },
        &stdout_writer.interface,
        &stderr_writer.interface,
    ) catch |err| {
        try stderr_writer.interface.print("error: {s}\n", .{@errorName(err)});
        try stderr_writer.interface.flush();
        std.process.exit(1);
    };

    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    if (exit_code == 0) std.process.cleanExit() else std.process.exit(exit_code);
}

fn runForTesting(
    allocator: Allocator,
    args: []const []const u8,
    stdin_bytes: []const u8,
    stdout_supports_color: bool,
) !RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_buffer.deinit();
    const runs_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/delta_tool.runs",
        .{&tmp.sub_path},
    );
    defer allocator.free(runs_path);

    const exe_name = if (args.len > 0) args[0] else "delta-tool";
    const exit_code = run(
        allocator,
        if (args.len > 1) args[1..] else &.{},
        exe_name,
        .{ .bytes = stdin_bytes },
        stdout_supports_color,
        .{
            .use_pager = false,
            .runs_path = runs_path,
            .timestamp_secs = 0,
        },
        &stdout_buffer.writer,
        &stderr_buffer.writer,
    ) catch |err| {
        try stderr_buffer.writer.print("error: {s}\n", .{@errorName(err)});
        return .{
            .stdout = try stdout_buffer.toOwnedSlice(),
            .stderr = try stderr_buffer.toOwnedSlice(),
            .runs = tmp.dir.readFileAlloc(allocator, "delta_tool.runs", std.math.maxInt(usize)) catch |read_err| switch (read_err) {
                error.FileNotFound => null,
                else => return read_err,
            },
            .exit_code = 1,
        };
    };

    return .{
        .stdout = try stdout_buffer.toOwnedSlice(),
        .stderr = try stderr_buffer.toOwnedSlice(),
        .runs = tmp.dir.readFileAlloc(allocator, "delta_tool.runs", std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        },
        .exit_code = exit_code,
    };
}

fn run(
    allocator: Allocator,
    args: []const []const u8,
    exe_name: []const u8,
    stdin: StdinSource,
    stdout_supports_color: bool,
    options: RunOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    if (args.len == 1 and isHelpArg(args[0])) {
        try writeHelp(stdout_writer, exe_name);
        return 0;
    }
    const parsed_args = parseCliArgs(args) orelse {
        try writeUsage(stderr_writer, exe_name);
        return 1;
    };

    const start_revision = try parseRevisionOrdinal(parsed_args.start_revision_arg);
    const end_revision = try parseRevisionOrdinal(parsed_args.end_revision_arg);
    if (start_revision < 1) return error.RevisionOrdinalTooSmall;
    if (end_revision <= start_revision) return error.RevisionRangeOutOfOrder;

    const should_record_runs = parsed_args.replay_script == null;

    var recorder: ?RunRecorder = null;
    if (should_record_runs) {
        if (options.runs_path) |runs_path| {
            recorder = try RunRecorder.init(
                runs_path,
                options.timestamp_secs orelse @as(u64, @intCast(std.time.timestamp())),
                start_revision,
                end_revision,
            );
        }
    }
    defer if (recorder) |*owned| owned.deinit();

    var selection = try loadCorpusSelection(allocator, start_revision, end_revision);
    defer selection.deinit(allocator);

    const settings: zdelta_context.RenderSettings = .{};
    var prompt = PromptSource{
        .input = if (parsed_args.replay_script) |script|
            .{ .replay = script }
        else
            .{ .live = stdin },
    };
    const raw_guard = if (parsed_args.replay_script == null)
        try RawTerminalGuard.init(stdin)
    else
        RawTerminalGuard{};
    defer raw_guard.deinit();
    const output = OutputClient.init(allocator, raw_guard.isActive());

    var tm = try DeltaManager.initText(allocator, selection.revisions[0].body);
    defer tm.deinit();

    var summary = ZDeltaSummary{
        .processed_revision = start_revision,
    };

    outer: for (selection.revisions[1..]) |revision| {
        const zdelta_text = revision.zdelta orelse return error.MissingCorpusZDelta;
        const owned_delta = try allocator.create(dmp.ZDelta);
        owned_delta.* = dmp.decode(allocator, zdelta_text) catch |err| {
            allocator.destroy(owned_delta);
            return err;
        };
        tm.addDelta(owned_delta) catch |err| {
            if (tm.zdelta == owned_delta) {
                tm.zdelta = null;
            }
            owned_delta.destroy(allocator);
            return err;
        };

        try writeDeltaHeader(
            output,
            stdout_writer,
            summary.processed_revision,
            revision.ordinal,
            revision.relative_path,
        );

        var delta_page = try zdelta_context.buildWholeDeltaPage(
            allocator,
            tm.view(),
            revision.body,
            std.fs.path.basename(revision.relative_path),
            settings,
        );
        defer delta_page.deinit();
        if (stdout_supports_color) {
            try renderPage(output, stdout_writer, delta_page, .xterm_classic);
        } else {
            try renderPage(output, stdout_writer, delta_page, plain_diff_decorations);
        }
        try stdout_writer.flush();

        while (true) {
            try output.writeText(stdout_writer, "\n[y] apply  [n] skip  [s] split  [q] quit  [?] help > ");
            try stdout_writer.flush();
            const input = (try prompt.readDeltaInput(stdout_writer, output)) orelse {
                summary.quit_early = true;
                break :outer;
            };
            if (input.canonical) |command| {
                if (recorder) |*owned| try owned.recordCommand(command);
            }

            switch (input.action) {
                .apply => {
                    try applyRemainingDelta(&tm, &summary.applied_edits);
                    summary.applied_deltas += 1;
                    summary.processed_revision = revision.ordinal;
                    continue :outer;
                },
                .skip => {
                    try skipRemainingDelta(&tm, &summary.skipped_edits);
                    summary.skipped_deltas += 1;
                    summary.processed_revision = revision.ordinal;
                    continue :outer;
                },
                .split => {
                    summary.partial_deltas += 1;
                    while (try tm.previewNext()) |preview| {
                        try writeEditHeader(
                            output,
                            stdout_writer,
                            summary.processed_revision,
                            revision.ordinal,
                            preview.delta_index + 1,
                            preview.op.state,
                        );

                        var edit_page = try zdelta_context.buildEditPage(
                            allocator,
                            tm.view(),
                            preview.text_index,
                            preview.op.effective,
                            tm.zdelta.?.insert_text,
                            std.fs.path.basename(revision.relative_path),
                            settings,
                        );
                        defer edit_page.deinit();
                        if (stdout_supports_color) {
                            try renderPage(output, stdout_writer, edit_page, .xterm_classic);
                        } else {
                            try renderPage(output, stdout_writer, edit_page, plain_diff_decorations);
                        }
                        try stdout_writer.flush();

                        while (true) {
                            try output.writeText(stdout_writer, "\n[y] apply  [n] skip  [a] apply rest  [d] skip rest  [q] quit  [?] help > ");
                            try stdout_writer.flush();
                            const edit_input = (try prompt.readEditInput(stdout_writer, output)) orelse {
                                summary.quit_early = true;
                                break :outer;
                            };
                            if (edit_input.canonical) |command| {
                                if (recorder) |*owned| try owned.recordCommand(command);
                            }

                            switch (edit_input.action) {
                                .apply => {
                                    _ = try tm.applyNext();
                                    summary.applied_edits += 1;
                                    break;
                                },
                                .skip => {
                                    _ = try tm.skipNext();
                                    summary.skipped_edits += 1;
                                    break;
                                },
                                .apply_rest => {
                                    try applyRemainingDelta(&tm, &summary.applied_edits);
                                    summary.processed_revision = revision.ordinal;
                                    continue :outer;
                                },
                                .skip_rest => {
                                    try skipRemainingDelta(&tm, &summary.skipped_edits);
                                    summary.processed_revision = revision.ordinal;
                                    continue :outer;
                                },
                                .quit => {
                                    summary.quit_early = true;
                                    break :outer;
                                },
                                .help => {
                                    try writeEditHelp(output, stdout_writer);
                                    try stdout_writer.flush();
                                },
                                .invalid => unreachable,
                            }
                        }
                    }

                    summary.processed_revision = revision.ordinal;
                    continue :outer;
                },
                .quit => {
                    summary.quit_early = true;
                    break :outer;
                },
                .help => {
                    try writeDeltaHelp(output, stdout_writer);
                    try stdout_writer.flush();
                },
                .invalid => unreachable,
            }
        }
    }

    try writeExitReview(
        allocator,
        stdout_writer,
        output,
        tm.view(),
        selection.revisions[selection.revisions.len - 1].body,
        stdout_supports_color,
        options.use_pager,
    );

    try writeSummary(
        output,
        stdout_writer,
        start_revision,
        end_revision,
        summary,
        tm.view().len,
        tm.skippedItems().len,
    );
    try stdout_writer.flush();
    if (recorder) |*owned| try owned.ensureSuccessQuit();
    return 0;
}

fn isHelpArg(arg: []const u8) bool {
    return std.ascii.eqlIgnoreCase(arg, "help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help");
}

fn parseCliArgs(args: []const []const u8) ?ParsedArgs {
    var replay_script: ?[]const u8 = null;
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--replay")) {
            if (replay_script != null) return null;
            idx += 1;
            if (idx >= args.len) return null;
            replay_script = args[idx];
            continue;
        }
        if (positional_len >= positional.len) return null;
        positional[positional_len] = arg;
        positional_len += 1;
    }

    if (positional_len != positional.len) return null;
    return .{
        .replay_script = replay_script,
        .start_revision_arg = positional[0],
        .end_revision_arg = positional[1],
    };
}

fn writeUsage(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} [--replay <script>] <first-revision> <last-revision>\n", .{exe_name});
    try writer.writeAll("Try --help for more information.\n");
}

fn writeHelp(writer: *std.Io.Writer, exe_name: []const u8) !void {
    try writer.print("Usage: {s} [--replay <script>] <first-revision> <last-revision>\n\n", .{exe_name});
    try writer.writeAll(
        "Interactive zdelta inspector for the checked-in corpus.\n\n" ++
            "Arguments:\n" ++
            "  --replay <script>  Replay a one-line command script of single-character actions.\n" ++
            "  <first-revision>  1-based starting revision ordinal.\n" ++
            "  <last-revision>   1-based ending revision ordinal, greater than the first.\n\n" ++
            "Revision 0 is the implicit pre-history baseline and is not passed on the command line.\n",
    );
}

fn parseRevisionOrdinal(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10);
}

fn loadCorpusSelection(
    allocator: Allocator,
    start_revision: usize,
    end_revision: usize,
) !CorpusSelection {
    var relative_paths = try collectSortedCorpusWikiPaths(allocator);
    defer {
        for (relative_paths.items) |path| allocator.free(path);
        relative_paths.deinit();
    }

    if (relative_paths.items.len == 0) return error.EmptyCorpus;
    if (end_revision > relative_paths.items.len) return error.RevisionOrdinalOutOfRange;

    const count = end_revision - start_revision + 1;
    var revisions = try allocator.alloc(CorpusRevision, count);
    var initialized: usize = 0;
    errdefer {
        for (revisions[0..initialized]) |*revision| revision.deinit(allocator);
        allocator.free(revisions);
    }

    var corpus_dir = try std.fs.cwd().openDir(corpus_diff_root, .{});
    defer corpus_dir.close();

    for (revisions, 0..) |*revision, idx| {
        const ordinal = start_revision + idx;
        const relative_path = relative_paths.items[ordinal - 1];
        const file_data = try corpus_dir.readFileAlloc(allocator, relative_path, std.math.maxInt(usize));
        defer allocator.free(file_data);

        revision.* = .{
            .ordinal = ordinal,
            .relative_path = try allocator.dupe(u8, relative_path),
            .body = try copyFixtureBody(allocator, file_data),
            .zdelta = null,
        };
        initialized += 1;
    }

    try loadSelectionZDeltas(allocator, revisions);
    return .{ .revisions = revisions };
}

fn collectSortedCorpusWikiPaths(allocator: Allocator) !ArrayList([]u8) {
    var paths = ArrayList([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    var dir = try std.fs.cwd().openDir(corpus_diff_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wiki")) continue;
        try paths.append(try allocator.dupe(u8, entry.path));
    }

    std.sort.heap([]u8, paths.items, {}, lessThanString);
    return paths;
}

fn loadSelectionZDeltas(allocator: Allocator, revisions: []CorpusRevision) !void {
    if (revisions.len <= 1) return;

    var dir = try std.fs.cwd().openDir(corpus_diff_root, .{ .iterate = true });
    defer dir.close();

    var zdset_names = ArrayList([]u8).init(allocator);
    defer {
        for (zdset_names.items) |name| allocator.free(name);
        zdset_names.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zdset")) continue;
        try zdset_names.append(try allocator.dupe(u8, entry.name));
    }
    std.sort.heap([]u8, zdset_names.items, {}, lessThanString);

    var next_needed: usize = 1;
    for (zdset_names.items) |name| {
        if (next_needed >= revisions.len) break;

        const file_data = try dir.readFileAlloc(allocator, name, std.math.maxInt(usize));
        defer allocator.free(file_data);

        var line_iter = std.mem.tokenizeScalar(u8, file_data, '\n');
        var pending_path: ?[]const u8 = null;
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "# baseline ")) {
                pending_path = null;
                continue;
            }
            if (std.mem.startsWith(u8, line, "# ")) {
                pending_path = line[2..];
                continue;
            }
            const path = pending_path orelse continue;
            pending_path = null;

            while (next_needed < revisions.len and std.mem.order(u8, revisions[next_needed].relative_path, path) == .lt) {
                next_needed += 1;
            }
            if (next_needed >= revisions.len) break;
            if (!std.mem.eql(u8, revisions[next_needed].relative_path, path)) continue;

            revisions[next_needed].zdelta = try allocator.dupe(u8, line);
            next_needed += 1;
        }
    }

    for (revisions[1..]) |revision| {
        if (revision.zdelta == null) return error.MissingCorpusZDelta;
    }
}

fn copyFixtureBody(allocator: Allocator, file_data: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, file_data, "---\n")) return error.MissingOpeningFrontmatter;
    const closing_rel = std.mem.indexOf(u8, file_data[4..], "\n---\n") orelse {
        return error.MissingClosingFrontmatter;
    };
    const start = 4 + closing_rel + "\n---\n".len;
    return allocator.dupe(u8, file_data[start..]);
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn parseReplayDeltaPromptAction(command: u8) ?ParsedDeltaPrompt {
    var parser = DeltaPromptParser{};
    return switch (parser.feed(command)) {
        .accepted => |accepted| accepted,
        .invalid, .incomplete => null,
    };
}

fn parseReplayEditPromptAction(command: u8) ?ParsedEditPrompt {
    var parser = EditPromptParser{};
    return switch (parser.feed(command)) {
        .accepted => |accepted| accepted,
        .invalid, .incomplete => null,
    };
}

fn applyRemainingDelta(tm: *DeltaManager, counter: *usize) !void {
    while (try tm.applyNext()) |_| {
        counter.* += 1;
    }
}

fn skipRemainingDelta(tm: *DeltaManager, counter: *usize) !void {
    while (try tm.skipNext()) |_| {
        counter.* += 1;
    }
}

fn renderPage(
    output: OutputClient,
    writer: anytype,
    page: zdelta_context.Page,
    deco: dmp.DiffDecorations,
) !void {
    var line_start = true;
    for (page.lines.items) |line| {
        switch (line) {
            .header => |text| {
                if (!line_start) try output.writeLineEnding(writer);
                try output.writeText(writer, text);
                try output.writeLineEnding(writer);
                line_start = true;
            },
            .diff => |diff| {
                if (line_start) {
                    try writer.writeByte(' ');
                    line_start = false;
                }
                const normalized_text = if (output.line_ending.len == 1)
                    diff.text
                else
                    try std.mem.replaceOwned(u8, output.allocator, diff.text, "\n", output.line_ending);
                defer if (output.line_ending.len != 1) output.allocator.free(normalized_text);
                _ = try dmp.writeDecoratedEdit(
                    output.allocator,
                    writer,
                    deco,
                    dmp.Edit.asBorrow(diff.operation, normalized_text),
                );
                if (diff.text.len != 0 and diff.text[diff.text.len - 1] == '\n') {
                    line_start = true;
                }
            },
            .elision => |elision| {
                if (!line_start) try output.writeLineEnding(writer);
                try writer.writeAll(" ... ");
                {
                    var before_buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
                    const before_text = try std.fmt.bufPrint(&before_buf, "{d}", .{elision.before});
                    _ = try dmp.writeDecoratedEdit(
                        output.allocator,
                        writer,
                        deco,
                        dmp.Edit.asBorrow(.delete, before_text),
                    );
                }
                try writer.writeByte(';');
                {
                    var after_buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
                    const after_text = try std.fmt.bufPrint(&after_buf, "{d}", .{elision.after});
                    _ = try dmp.writeDecoratedEdit(
                        output.allocator,
                        writer,
                        deco,
                        dmp.Edit.asBorrow(.insert, after_text),
                    );
                }
                try output.writeLineEnding(writer);
                line_start = true;
            },
            .eof_marker => {
                if (!line_start) try output.writeLineEnding(writer);
                try output.writeText(writer, " ---[eof]---\n\n");
                line_start = true;
            },
            .truncated => {
                if (!line_start) try output.writeLineEnding(writer);
                try output.writeText(writer, "... [truncated]\n");
                line_start = true;
            },
        }
    }
}

fn writeDeltaHeader(
    output: OutputClient,
    writer: *std.Io.Writer,
    current_revision: usize,
    target_revision: usize,
    relative_path: []const u8,
) !void {
    try output.print(writer, "\n=== revision {d} -> {d} ({s}) ===\n", .{
        current_revision,
        target_revision,
        relative_path,
    });
}

fn writeEditHeader(
    output: OutputClient,
    writer: *std.Io.Writer,
    current_revision: usize,
    target_revision: usize,
    delta_index: u32,
    state: dmp.HarmonizedOpState,
) !void {
    try output.print(writer, "\n--- revision {d} -> {d}, edit {d} [{s}] ---\n", .{
        current_revision,
        target_revision,
        delta_index,
        @tagName(state),
    });
}

fn writeDeltaHelp(output: OutputClient, writer: *std.Io.Writer) !void {
    try output.writeText(writer,
        "y: apply the whole delta\n" ++
            "n: skip the whole delta\n" ++
            "s: review one mutation at a time\n" ++
            "q: stop the session\n",
    );
}

fn writeEditHelp(output: OutputClient, writer: *std.Io.Writer) !void {
    try output.writeText(writer,
        "y: apply this mutation\n" ++
            "n: skip this mutation\n" ++
            "a: apply the rest of the current delta\n" ++
            "d: skip the rest of the current delta\n" ++
            "q: stop the session\n",
    );
}

fn writeSummary(
    output: OutputClient,
    writer: *std.Io.Writer,
    start_revision: usize,
    end_revision: usize,
    summary: ZDeltaSummary,
    current_len: usize,
    skipped_history_len: usize,
) !void {
    try output.print(
        writer,
        "\n=== zdelta summary ===\nrange: {d}..{d}\nprocessed through: {d}\nquit early: {any}\n" ++
            "applied deltas: {d}\nskipped deltas: {d}\npartial deltas: {d}\n" ++
            "applied edits: {d}\nskipped edits: {d}\ncurrent bytes: {d}\nskipped history: {d}\n",
        .{
            start_revision,
            end_revision,
            summary.processed_revision,
            summary.quit_early,
            summary.applied_deltas,
            summary.skipped_deltas,
            summary.partial_deltas,
            summary.applied_edits,
            summary.skipped_edits,
            current_len,
            skipped_history_len,
        },
    );
}

fn formatUtcTimestamp(buffer: []u8, timestamp_secs: u64) ![]const u8 {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = timestamp_secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return try std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn writeExitReview(
    allocator: Allocator,
    stdout_writer: *std.Io.Writer,
    _: OutputClient,
    final_text: []const u8,
    expected_text: []const u8,
    use_color: bool,
    use_pager: bool,
) !void {
    if (!use_pager or std.mem.eql(u8, final_text, expected_text)) return;

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, final_text, expected_text);
    _ = try diff.cleanupSemantic(allocator);

    try stdout_writer.flush();

    var pager = std.process.Child.init(
        if (use_color) &.{ "less", "-R" } else &.{"less"},
        allocator,
    );
    pager.stdin_behavior = .Pipe;
    pager.stdout_behavior = .Inherit;
    pager.stderr_behavior = .Inherit;
    try pager.spawn();

    {
        var pager_buf: [4096]u8 = undefined;
        var pager_writer = pager.stdin.?.writer(&pager_buf);
        if (use_color) {
            _ = try diff.writePrettyFormat(allocator, &pager_writer.interface, .xterm_classic);
        } else {
            _ = try diff.writePrettyFormat(allocator, &pager_writer.interface, plain_diff_decorations);
        }
        try pager_writer.interface.flush();
    }
    pager.stdin.?.close();
    pager.stdin = null;

    _ = try pager.wait();
}

test "command line help is sane" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--help" }, "", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Usage: delta-tool [--replay <script>] <first-revision> <last-revision>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "--replay <script>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "Revision 0 is the implicit pre-history baseline"));
    try std.testing.expectEqual(@as(?[]u8, null), result.runs);
}

test "range validates 1-based revision ordinals" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "0", "2" }, "", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "RevisionOrdinalTooSmall"));
}

test "whole delta application works" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "y", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "=== revision 1 -> 2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "[y] apply  [n] skip  [s] split  [q] quit  [?] help > y\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "applied deltas: 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "quit early: false"));
    try std.testing.expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nyq", result.runs.?);
}

test "interactive help key is accepted" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "?q", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "[y] apply  [n] skip  [s] split  [q] quit  [?] help > ?\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "y: apply the whole delta"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "quit early: true"));
    try std.testing.expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\n?q", result.runs.?);
}

test "replay script drives the session" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--replay", "y", "1", "2" }, "", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "applied deltas: 1"));
    try std.testing.expectEqual(@as(?[]u8, null), result.runs);
}

test "replay script exhaustion is reported" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--replay", "", "1", "2" }, "", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "ReplayScriptExhausted"));
    try std.testing.expectEqual(@as(?[]u8, null), result.runs);
}

test "replay script invalid commands fail immediately" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--replay", "help", "1", "2" }, "", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "InvalidReplayDeltaCommand"));
    try std.testing.expectEqual(@as(?[]u8, null), result.runs);
}

test "invalid live input is not logged" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "BOGUSq", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "\x07"));
    try std.testing.expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nq", result.runs.?);
}

test "uppercase live commands are invalid" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "Qq", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "\x07"));
    try std.testing.expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nq", result.runs.?);
}

test "user quit is not duplicated in runs log" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "q", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nq", result.runs.?);
}

test "delta prompt parser accepts lowercase commands only" {
    var parser = DeltaPromptParser{};

    try std.testing.expectEqualDeep(
        PromptParseResult(DeltaPromptAction){ .accepted = .{ .action = .apply, .canonical = 'y' } },
        parser.feed('y'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult(DeltaPromptAction){ .accepted = .{ .action = .help, .canonical = '?' } },
        parser.feed('?'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult(DeltaPromptAction){ .invalid = {} },
        parser.feed('Y'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult(DeltaPromptAction){ .invalid = {} },
        parser.feed('\n'),
    );
}

test "edit prompt parser accepts lowercase commands only" {
    var parser = EditPromptParser{};

    try std.testing.expectEqualDeep(
        PromptParseResult(EditPromptAction){ .accepted = .{ .action = .apply_rest, .canonical = 'a' } },
        parser.feed('a'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult(EditPromptAction){ .accepted = .{ .action = .help, .canonical = '?' } },
        parser.feed('?'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult(EditPromptAction){ .invalid = {} },
        parser.feed('A'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult(EditPromptAction){ .invalid = {} },
        parser.feed('\n'),
    );
}

test "render page writes plain semantic lines" {
    const allocator = std.testing.allocator;
    var page = zdelta_context.Page.init(allocator);
    defer page.deinit();

    try page.lines.append(.{ .header = try allocator.dupe(u8, "diff -- sample") });
    try page.lines.append(.{
        .diff = .{
            .operation = .equal,
            .text = try allocator.dupe(u8, "same\n"),
        },
    });
    try page.lines.append(.{ .elision = .{ .before = 4, .after = 9 } });
    try page.lines.append(.{ .eof_marker = {} });

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    var out_writer = out.writer();
    _ = &out_writer;
    try renderPage(OutputClient.init(allocator, false), &out_writer, page, plain_diff_decorations);

    try std.testing.expectEqualStrings(
        "diff -- sample\n same\n ... [-4-];{+9+}\n ---[eof]---\n\n",
        out.items,
    );
}

test "render page leaves prompt-safe ansi state after truncated insert line" {
    const allocator = std.testing.allocator;
    var page = zdelta_context.Page.init(allocator);
    defer page.deinit();

    try page.lines.append(.{ .header = try allocator.dupe(u8, "diff -- sample") });
    try page.lines.append(.{
        .diff = .{
            .operation = .insert,
            .text = try allocator.dupe(u8, "green\n"),
        },
    });
    try page.lines.append(.{ .truncated = {} });

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    var out_writer = out.writer();
    _ = &out_writer;
    try renderPage(OutputClient.init(allocator, false), &out_writer, page, .xterm_classic);

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "\x1b[m... [truncated]\n"));
}
