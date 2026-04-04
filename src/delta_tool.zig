//! Specialized interactive zdelta corpus tool.

const ESC = "\x1b";
const CSI = ESC ++ "[";
const CURSOR_POSITION_REQUEST = CSI ++ "6n";
const TERMINAL_SIZE_REQUEST = CSI ++ "18t";

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
    runs_path: ?[]const u8 = corpus_contract.default_runs_path,
    timestamp_secs: ?u64 = null,
};

const ParsedArgs = struct {
    replay_script: ?[]const u8 = null,
    start_revision_arg: []const u8,
    end_revision_arg: []const u8,
};

const PromptCommand = struct {
    intent: zdelta_session.SessionIntent,
    canonical: ?u8,
};

const ParsedPrompt = struct {
    intent: zdelta_session.SessionIntent,
    canonical: u8,
};

const PromptParseResult = union(enum) {
    accepted: ParsedPrompt,
    invalid,
    interrupt,
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

    fn readCursorAnchor(self: *PromptSource, writer: *std.Io.Writer) !paint_mod.CursorAnchor {
        switch (self.input) {
            .live => {},
            .replay => return error.CursorAnchorUnavailable,
        }

        try writer.writeAll(CURSOR_POSITION_REQUEST);
        try writer.flush();

        var buf: [32]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const byte = (try self.readLiveByte()) orelse return error.CursorAnchorUnavailable;
            buf[len] = byte;
            len += 1;
            if (byte == 'R') break;
        }
        if (len < 6) return error.InvalidCursorAnchorResponse;
        if (buf[0] != 0x1b or buf[1] != '[' or buf[len - 1] != 'R') {
            return error.InvalidCursorAnchorResponse;
        }

        const body = buf[2 .. len - 1];
        const sep = std.mem.indexOfScalar(u8, body, ';') orelse return error.InvalidCursorAnchorResponse;
        const row = try std.fmt.parseUnsigned(u16, body[0..sep], 10);
        const col = try std.fmt.parseUnsigned(u16, body[sep + 1 ..], 10);
        return .{ .row = row, .col = col };
    }

    fn readTerminalSize(self: *PromptSource, writer: *std.Io.Writer) !paint_mod.TerminalSize {
        switch (self.input) {
            .live => {},
            .replay => return error.TerminalSizeUnavailable,
        }

        try writer.writeAll(TERMINAL_SIZE_REQUEST);
        try writer.flush();

        var buf: [32]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const byte = (try self.readLiveByte()) orelse return error.TerminalSizeUnavailable;
            buf[len] = byte;
            len += 1;
            if (byte == 't') break;
        }
        if (len < 8) return error.InvalidTerminalSizeResponse;
        if (buf[0] != 0x1b or buf[1] != '[' or buf[len - 1] != 't') {
            return error.InvalidTerminalSizeResponse;
        }

        const body = buf[2 .. len - 1];
        var parts = std.mem.splitScalar(u8, body, ';');
        const kind = parts.next() orelse return error.InvalidTerminalSizeResponse;
        if (!std.mem.eql(u8, kind, "8")) return error.InvalidTerminalSizeResponse;
        const rows_text = parts.next() orelse return error.InvalidTerminalSizeResponse;
        const cols_text = parts.next() orelse return error.InvalidTerminalSizeResponse;
        if (parts.next() != null) return error.InvalidTerminalSizeResponse;

        return .{
            .rows = try std.fmt.parseUnsigned(u16, rows_text, 10),
            .cols = try std.fmt.parseUnsigned(u16, cols_text, 10),
        };
    }

    // Live input is intentionally terse and byte-oriented. The parser boundary
    // exists so the session core only sees canonical review intents, not
    // terminal bytes or replay-script quirks.
    fn readInput(
        self: *PromptSource,
        prompt_kind: zdelta_session.SessionPrompt,
        writer: anytype,
        echo_live: bool,
    ) !?PromptCommand {
        switch (self.input) {
            .live => {
                while (true) {
                    const byte = (try self.readLiveByte()) orelse return null;
                    switch (parsePromptByte(prompt_kind, byte)) {
                        .accepted => |accepted| {
                            if (echo_live) {
                                try writer.writeByte(accepted.canonical);
                                try writer.writeAll("\n");
                                try writer.flush();
                            }
                            return .{
                                .intent = accepted.intent,
                                .canonical = accepted.canonical,
                            };
                        },
                        .invalid => {
                            try writer.writeByte(7);
                            try writer.flush();
                        },
                        .interrupt => return error.Interrupted,
                    }
                }
            },
            .replay => {
                const command = try self.readReplayCommand();
                const parsed = parseReplayPrompt(prompt_kind, command) orelse switch (prompt_kind) {
                    .delta => return error.InvalidReplayDeltaCommand,
                    .edit => return error.InvalidReplayEditCommand,
                };
                return .{
                    .intent = parsed.intent,
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

fn makeTerminalProbe(prompt: *PromptSource) paint_mod.TerminalProbe {
    return .{
        .context = @ptrCast(prompt),
        .read_cursor_anchor = promptReadCursorAnchor,
        .read_terminal_size = promptReadTerminalSize,
    };
}

fn promptReadCursorAnchor(
    context: *anyopaque,
    writer: *std.Io.Writer,
) anyerror!paint_mod.CursorAnchor {
    const prompt: *PromptSource = @ptrCast(@alignCast(context));
    return prompt.readCursorAnchor(writer);
}

fn promptReadTerminalSize(
    context: *anyopaque,
    writer: *std.Io.Writer,
) anyerror!paint_mod.TerminalSize {
    const prompt: *PromptSource = @ptrCast(@alignCast(context));
    return prompt.readTerminalSize(writer);
}

const OwnedSessionSeed = struct {
    steps: []zdelta_session.SessionStep,

    fn deinit(seed: *OwnedSessionSeed, allocator: Allocator) void {
        allocator.free(seed.steps);
        seed.* = undefined;
    }
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
            .exit_code = if (err == error.Interrupted) 130 else 1,
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
    var painter = paint_mod.Painter.init(allocator, stdout_writer, stderr_writer, .{
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
                runs_path,
                options.timestamp_secs orelse @as(u64, @intCast(std.time.timestamp())),
                start_revision,
                end_revision,
            );
        }
    }
    defer if (recorder) |*owned| owned.deinit();

    var selection = try corpus_contract.loadCheckedInSelection(allocator, start_revision, end_revision);
    defer selection.deinit(allocator);
    var owned_seed = try makeSessionSeed(allocator, selection);
    defer owned_seed.deinit(allocator);

    const settings: zdelta_context.ContextSettings = .{
        .whole_delta_context_lines = 2,
        .edit_context_lines = 2,
    };
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
    painter.setRawMode(raw_guard.isActive());
    const terminal_probe: ?paint_mod.TerminalProbe = if (painter.supportsInPlaceRepaint())
        makeTerminalProbe(&prompt)
    else
        null;

    var session = try zdelta_session.ReviewSession.init(allocator, .{
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

        var interaction_state = try zdelta_context.InteractionState.build(allocator, snapshot, settings);
        defer interaction_state.deinit();
        try painter.renderPromptFrame(terminal_probe, interaction_state);

        while (true) {
            const input = (try prompt.readInput(snapshot.prompt_kind, stdout_writer, painter.echoesAcceptedCommands())) orelse {
                session.quitEarly();
                break :outer;
            };
            if (painter.supportsInPlaceRepaint() and painter.previewIntent(&interaction_state, input.intent)) {
                try painter.renderPromptFrame(terminal_probe, interaction_state);
            }
            if (input.canonical) |byte| {
                if (recorder) |*owned| try owned.recordCommand(byte);
            }

            var outcome = try session.dispatch(input.intent);
            defer outcome.deinit(allocator);
            try painter.writeDiagnostics(outcome.diagnostics);
            if (outcome.help_prompt) |prompt_kind| {
                try painter.writePromptHelp(prompt_kind);
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

fn parseRevisionOrdinal(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10);
}

fn makeSessionSeed(
    allocator: Allocator,
    selection: corpus_contract.CorpusSelection,
) !OwnedSessionSeed {
    const step_count = selection.revisions.len - 1;
    var steps = try allocator.alloc(zdelta_session.SessionStep, step_count);
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

fn parsePromptByte(
    prompt_kind: zdelta_session.SessionPrompt,
    byte: u8,
) PromptParseResult {
    if (byte == 3) return .interrupt;
    return if (parseReplayPrompt(prompt_kind, byte)) |parsed|
        .{ .accepted = parsed }
    else
        .invalid;
}

fn parseReplayPrompt(
    prompt_kind: zdelta_session.SessionPrompt,
    command: u8,
) ?ParsedPrompt {
    return switch (prompt_kind) {
        .delta => switch (command) {
            'y' => .{ .intent = .apply, .canonical = 'y' },
            'n' => .{ .intent = .skip, .canonical = 'n' },
            's' => .{ .intent = .split, .canonical = 's' },
            'q' => .{ .intent = .quit, .canonical = 'q' },
            '?' => .{ .intent = .help, .canonical = '?' },
            else => null,
        },
        .edit => switch (command) {
            'y' => .{ .intent = .apply, .canonical = 'y' },
            'n' => .{ .intent = .skip, .canonical = 'n' },
            'a' => .{ .intent = .apply_rest, .canonical = 'a' },
            'd' => .{ .intent = .skip_rest, .canonical = 'd' },
            'q' => .{ .intent = .quit, .canonical = 'q' },
            '?' => .{ .intent = .help, .canonical = '?' },
            else => null,
        },
    };
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

test "ctrl c interrupts without synthesizing quit" {
    const allocator = std.testing.allocator;
    var result = try runForTesting(allocator, &.{ "delta-tool", "1", "2" }, "\x03", false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 130), result.exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Interrupted"));
    try std.testing.expectEqualStrings("\n1970-01-01T00:00:00Z: 1 2\n", result.runs.?);
}

test "delta prompt parser accepts lowercase canonical commands only" {
    try std.testing.expectEqualDeep(
        PromptParseResult{ .accepted = .{ .intent = .apply, .canonical = 'y' } },
        parsePromptByte(.delta, 'y'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult{ .accepted = .{ .intent = .help, .canonical = '?' } },
        parsePromptByte(.delta, '?'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult{ .invalid = {} },
        parsePromptByte(.delta, 'Y'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult{ .invalid = {} },
        parsePromptByte(.delta, '\n'),
    );
}

test "edit prompt parser accepts lowercase canonical commands only" {
    try std.testing.expectEqualDeep(
        PromptParseResult{ .accepted = .{ .intent = .apply_rest, .canonical = 'a' } },
        parsePromptByte(.edit, 'a'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult{ .accepted = .{ .intent = .help, .canonical = '?' } },
        parsePromptByte(.edit, '?'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult{ .invalid = {} },
        parsePromptByte(.edit, 'A'),
    );
    try std.testing.expectEqualDeep(
        PromptParseResult{ .invalid = {} },
        parsePromptByte(.edit, '\n'),
    );
}

const std = @import("std");
const dmp = @import("dmp.zig");
const corpus_contract = @import("corpus_contract");
const paint_mod = @import("dtool/paint.zig");
const zdelta_context = @import("zdelta/context.zig");
const zdelta_session = @import("zdelta/session.zig");

const Allocator = std.mem.Allocator;
