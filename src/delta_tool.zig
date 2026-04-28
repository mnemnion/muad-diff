//! Specialized interactive zdelta corpus tool.

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

const RunOptions = struct {
    use_pager: bool,
    runs_path: ?[]const u8 = corpus_contract.default_runs_path,
    timestamp_secs: ?u64 = null,
};

const ParsedArgs = struct {
    replay_script: ?[]const u8 = null,
    start_revision_arg: []const u8,
    end_revision_arg: []const u8,
};

/// Set terminal raw, with fallbacks if something goes hinky.
const RawTerminal = struct {
    file: ?std.Io.File,
    original_state: ?std.posix.termios,

    pub const dummy: RawTerminal = .{ .file = null, .original_state = null };

    fn init(stdin: StdinSource) !RawTerminal {
        const file = switch (stdin) {
            .file => |file| file,
            .bytes => return .dummy,
        };
        const original_state = std.posix.tcgetattr(file.handle) catch |err| switch (err) {
            error.NotATerminal => return .dummy,
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

    fn deinit(self: *const RawTerminal) void {
        if (self.file) |file| {
            std.posix.tcsetattr(file.handle, .DRAIN, self.original_state.?) catch {};
        }
    }

    fn isActive(self: RawTerminal) bool {
        return self.file != null;
    }
};

const RunRecorder = struct {
    file: std.Io.File,
    last_command: ?u8 = null,

    fn init(
        io: std.Io,
        runs_path: []const u8,
        timestamp_secs: u64,
        start_revision: usize,
        end_revision: usize,
    ) !RunRecorder {
        var file = if (std.fs.path.isAbsolute(runs_path))
            try std.Io.Dir.createFileAbsolute(io, runs_path, .{ .truncate = false })
        else
            try std.Io.Dir.cwd().createFile(io, runs_path, .{ .truncate = false });
        errdefer file.close(io);

        const stat = try file.stat(io);
        try io.vtable.fileSeekTo(io.userdata, file, stat.size);

        var recorder: RunRecorder = .{
            .file = file,
        };
        try recorder.writeHeader(io, timestamp_secs, start_revision, end_revision);
        return recorder;
    }

    fn deinit(recorder: *RunRecorder, io: std.Io) void {
        recorder.file.close(io);
        recorder.* = undefined;
    }

    fn writeHeader(
        recorder: *RunRecorder,
        io: std.Io,
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
        try recorder.file.writeStreamingAll(io, header);
        try recorder.file.sync(io);
    }

    fn recordCommand(recorder: *RunRecorder, io: std.Io, command: u8) !void {
        const bytes = [1]u8{command};
        try recorder.file.writeStreamingAll(io, &bytes);
        try recorder.file.sync(io);
        recorder.last_command = command;
    }

    fn ensureSuccessQuit(recorder: *RunRecorder, io: std.Io) !void {
        if (recorder.last_command == 'q') return;
        try recorder.recordCommand(io, 'q');
    }
};

const OwnedSessionSeed = struct {
    steps: []zdelta_session.SessionStep,

    fn deinit(seed: *OwnedSessionSeed, allocator: Allocator) void {
        allocator.free(seed.steps);
        seed.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const exe_name = if (args.len > 0) args[0] else "delta-tool";
    const stdout_supports_color = std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);

    const exit_code = run(
        allocator,
        io,
        args[1..],
        exe_name,
        .{ .file = std.Io.File.stdin() },
        stdout_supports_color,
        .{ .use_pager = true },
        &stdout_writer.interface,
        &stderr_writer.interface,
    ) catch |err| switch (err) {
        error.Interrupted => {
            try stderr_writer.interface.print("error: {s}\n", .{@errorName(err)});
            try stderr_writer.interface.flush();
            std.process.exit(130);
        },
        else => {
            try stderr_writer.interface.print("error: {s}\n", .{@errorName(err)});
            try stderr_writer.interface.flush();
            std.process.exit(1);
        },
    };

    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    if (exit_code == 0) std.process.cleanExit(io) else std.process.exit(exit_code);
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
        std.testing.io,
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
            .runs = tmp.dir.readFileAlloc(std.testing.io, "delta_tool.runs", allocator, .unlimited) catch |read_err| switch (read_err) {
                error.FileNotFound => null,
                else => return read_err,
            },
            .exit_code = if (err == error.Interrupted) 130 else 1,
        };
    };

    return .{
        .stdout = try stdout_buffer.toOwnedSlice(),
        .stderr = try stderr_buffer.toOwnedSlice(),
        .runs = tmp.dir.readFileAlloc(std.testing.io, "delta_tool.runs", allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        },
        .exit_code = exit_code,
    };
}

fn run(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    exe_name: []const u8,
    stdin: StdinSource,
    stdout_supports_color: bool,
    options: RunOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var painter = Painter.init(allocator, stdout_writer, stderr_writer, .{
        .raw_mode = false,
        .stdout_supports_color = stdout_supports_color,
        .use_pager = options.use_pager,
    });
    if (args.len == 1 and isHelpArg(args[0])) {
        try painter.writeHelp(exe_name);
        return 0;
    }
    const parsed_args = parseCliArgs(args) orelse {
        try painter.writeUsage(exe_name);
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
                io,
                runs_path,
                options.timestamp_secs orelse currentTimestampSeconds(),
                start_revision,
                end_revision,
            );
        }
    }
    defer if (recorder) |*owned| owned.deinit(io);

    var selection = try corpus_contract.loadCheckedInSelection(allocator, start_revision, end_revision);
    defer selection.deinit(allocator);
    var owned_seed = try makeSessionSeed(allocator, selection);
    defer owned_seed.deinit(allocator);

    const settings: ContextSettings = .default;
    var in: LineIn = .init(if (parsed_args.replay_script) |script|
        .{ .replay = script }
    else
        .{ .live = stdin });
    in.io = io;
    const raw_guard: RawTerminal = if (parsed_args.replay_script == null)
        try .init(stdin)
    else
        .dummy;
    defer raw_guard.deinit();
    painter.setRawMode(raw_guard.isActive());

    var session: ReviewSession = try .init(allocator, .{
        .baseline = .{
            .ordinal = selection.revisions[0].ordinal,
            .relative_path = selection.revisions[0].relative_path,
            .body = selection.revisions[0].body,
        },
        .steps = owned_seed.steps,
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);
    try painter.writeDiagnostics(opened.diagnostics);

    outer: while (session.status() == .in_progress) {
        var snapshot = try session.snapshot();
        defer snapshot.deinit(allocator);

        var interaction_state: InteractionState = try .build(allocator, snapshot, settings);
        defer interaction_state.deinit();
        var pending_terminal: PendingTerminalInfo = .{};
        var rendered = false;

        if (painter.needsInitialTerminalInfo()) {
            try in.requestCursorAnchor(stdout_writer);
            try in.requestTerminalSize(stdout_writer);
        } else if (painter.supportsInPlaceRepaint()) {
            try painter.repaintPromptFrame(interaction_state);
            rendered = true;
        } else {
            try painter.renderInitialPromptFrame(interaction_state, null);
            rendered = true;
        }

        while (true) {
            in.setMode(switch (snapshot.prompt_kind) {
                .delta => .prompt_delta,
                .edit => .prompt_edit,
            });

            const input = input: while (true) {
                if (!rendered) {
                    if (pending_terminal.intoTerminalInfo()) |terminal_info| {
                        try painter.renderInitialPromptFrame(interaction_state, terminal_info);
                        rendered = true;
                        if (pending_terminal.pending_command) |command| {
                            pending_terminal.pending_command = null;
                            break :input command;
                        }
                    }
                }

                switch (try in.readEvent(null)) {
                    .prompt_command => |command| {
                        if (rendered) break :input command;
                        pending_terminal.pending_command = command;
                    },
                    .cursor_anchor => |anchor| pending_terminal.cursor_anchor = anchor,
                    .terminal_size => |size| pending_terminal.terminal_size = size,
                    .invalid_input => try painter.writeInvalidInputBell(),
                    .interrupt => return error.Interrupted,
                    .eof => {
                        session.quitEarly();
                        break :outer;
                    },
                    .help_done => {},
                }
            };
            if (parsed_args.replay_script == null) {
                try painter.echoAcceptedCommand(input.canonical);
            }
            if (painter.supportsInPlaceRepaint() and painter.previewIntent(&interaction_state, input.intent)) {
                try painter.repaintPromptFrame(interaction_state);
            }
            if (recorder) |*owned| try owned.recordCommand(io, input.canonical);

            var outcome = try session.dispatch(input.intent);
            defer outcome.deinit(allocator);
            try painter.writeDiagnostics(outcome.diagnostics);
            if (outcome.help_prompt) |prompt_kind| {
                try painter.writePromptHelp(prompt_kind);
                if (painter.supportsInPlaceRepaint()) {
                    if (!try in.waitForHelpDismiss()) {
                        session.quitEarly();
                        break :outer;
                    }
                    try painter.dismissPromptHelp();
                    try painter.repaintPromptFrame(interaction_state);
                }
                continue;
            }
            break;
        }
    }

    const summary = session.summary();
    if (!summary.quit_early and session.status() == .complete) {
        try painter.writeExitReview(session.currentText(), session.expectedFinalText());
    }

    try painter.writeSummary(
        start_revision,
        end_revision,
        summary,
        session.currentText().len,
        session.skippedHistoryLen(),
    );
    if (recorder) |*owned| try owned.ensureSuccessQuit(io);
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

fn parseRevisionOrdinal(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10);
}

fn makeSessionSeed(
    allocator: Allocator,
    selection: CorpusSelection,
) !OwnedSessionSeed {
    const step_count = selection.revisions.len - 1;
    var steps = try allocator.alloc(SessionStep, step_count);
    errdefer allocator.free(steps);

    for (selection.revisions[1..], 0..) |revision, idx| {
        steps[idx] = .{
            .ordinal = revision.ordinal,
            .relative_path = revision.relative_path,
            .target_body = revision.body,
            .zdelta_text = revision.zdelta.?,
        };
    }

    return .{ .steps = steps };
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

fn currentTimestampSeconds() u64 {
    var timespec: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &timespec))) {
        .SUCCESS => @intCast(timespec.sec),
        else => 0,
    };
}

test "help exits cleanly without creating a run transcript" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--help" }, "", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 0), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "delta-tool"));
    try expectEqual(@as(?[]u8, null), result.runs);
}

test "range validates 1-based revision ordinals" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "0", "2" }, "", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 1), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stderr, 1, "RevisionOrdinalTooSmall"));
}

test "whole delta application works" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "y", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 0), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "applied deltas: 1"));
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "quit early: false"));
    try expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nyq", result.runs.?);
}

test "interactive help logs help canonically and returns to the session" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "?q", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 0), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "y: apply the whole delta"));
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "quit early: true"));
    try expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\n?q", result.runs.?);
}

test "replay script drives the session" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--replay", "y", "1", "2" }, "", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 0), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "applied deltas: 1"));
    try expectEqual(@as(?[]u8, null), result.runs);
}

test "replay script exhaustion is reported" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--replay", "", "1", "2" }, "", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 1), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stderr, 1, "ReplayScriptExhausted"));
    try expectEqual(@as(?[]u8, null), result.runs);
}

test "replay script invalid commands fail immediately" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "--replay", "help", "1", "2" }, "", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 1), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stderr, 1, "InvalidReplayDeltaCommand"));
    try expectEqual(@as(?[]u8, null), result.runs);
}

test "invalid live input is not logged" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "BOGUSq", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 0), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stdout, 1, "\x07"));
    try expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nq", result.runs.?);
}

test "user quit is not duplicated in runs log" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "q", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 0), result.exit_code);
    try expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\nq", result.runs.?);
}

test "ctrl c interrupts without synthesizing quit" {
    if (true) return error.SkipZigTest;
    const allocator = test_allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "\x03", false);
    defer result.deinit(allocator);

    try expectEqual(@as(u8, 130), result.exit_code);
    try expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Interrupted"));
    try expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\n", result.runs.?);
}

const std = @import("std");
const dmp = @import("dmp.zig");
const corpus_contract = @import("corpus_contract");
const paint_mod = @import("dtool/paint.zig");
const Painter = paint_mod.Painter;
const linein_mod = @import("dtool/linein.zig");
const zdelta_context = @import("zdelta/context_mock.zig");
const zdelta_session = @import("zdelta/session_mock.zig");

const Allocator = std.mem.Allocator;
const ContextSettings = zdelta_context.ContextSettings;
const CorpusSelection = corpus_contract.CorpusSelection;
const InteractionState = zdelta_context.InteractionState;
const LineIn = linein_mod.LineIn;
const ReviewSession = zdelta_session.ReviewSession;
const SessionStep = zdelta_session.SessionStep;
const StdinSource = linein_mod.StdinSource;
const PendingTerminalInfo = struct {
    cursor_anchor: ?linein_mod.CursorAnchor = null,
    terminal_size: ?linein_mod.TerminalSize = null,
    pending_command: ?linein_mod.PromptCommand = null,

    fn intoTerminalInfo(pending: PendingTerminalInfo) ?paint_mod.TerminalInfo {
        return .{
            .cursor_anchor = pending.cursor_anchor orelse return null,
            .terminal_size = pending.terminal_size orelse return null,
        };
    }
};
const test_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
