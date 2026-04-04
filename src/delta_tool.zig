//! Specialized interactive zdelta corpus tool.

const plain_diff_decorations: dmp.DiffDecorations = .{
    .delete_start = "[-",
    .delete_end = "-]",
    .insert_start = "{+",
    .insert_end = "+}",
};

const ViewMark = enum {
    target_delete,
    target_insert,
    skipped_delete,
    skipped_insert,
    focus,
    blocked,
    rewritten,
};

const xterm_marks = MarkedDocument.MarkupColorArray.init(.{
    .target_delete = colors.fgBasic(.red),
    .target_insert = colors.fgBasic(.green),
    .skipped_delete = colors.fgBasic(.yellow),
    .skipped_insert = colors.fgBasic(.cyan),
    .focus = colors.inverse(),
    .blocked = colors.ulBasic(.curly, .red),
    .rewritten = colors.ulBasic(.single, .yellow),
});

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

    // Live input is intentionally terse and byte-oriented. The parser boundary
    // exists so the session core only sees canonical review intents, not
    // terminal bytes or replay-script quirks.
    fn readInput(
        self: *PromptSource,
        prompt_kind: zdelta_session.SessionPrompt,
        writer: anytype,
        output: OutputClient,
    ) !?PromptCommand {
        switch (self.input) {
            .live => {
                while (true) {
                    const byte = (try self.readLiveByte()) orelse return null;
                    switch (parsePromptByte(prompt_kind, byte)) {
                        .accepted => |accepted| {
                            try writer.writeByte(accepted.canonical);
                            try output.writeLineEnding(writer);
                            try writer.flush();
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
    const output = OutputClient.init(allocator, raw_guard.isActive());

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
    try writeDiagnostics(stderr_writer, opened.diagnostics);

    outer: while (session.status() == .in_progress) {
        var snapshot = try session.snapshot();
        defer snapshot.deinit(allocator);

        var interaction_state = try zdelta_context.InteractionState.build(allocator, snapshot, settings);
        defer interaction_state.deinit();
        try renderInteractionState(output, stdout_writer, interaction_state, stdout_supports_color);
        try stdout_writer.flush();

        while (true) {
            try output.writeText(stdout_writer, promptText(snapshot.prompt_kind));
            try stdout_writer.flush();
            const input = (try prompt.readInput(snapshot.prompt_kind, stdout_writer, output)) orelse {
                session.quitEarly();
                break :outer;
            };
            if (input.canonical) |command| {
                if (recorder) |*owned| try owned.recordCommand(command);
            }

            var outcome = try session.dispatch(input.intent);
            defer outcome.deinit(allocator);
            try writeDiagnostics(stderr_writer, outcome.diagnostics);
            if (outcome.help_prompt) |prompt_kind| {
                switch (prompt_kind) {
                    .delta => try writeDeltaHelp(output, stdout_writer),
                    .edit => try writeEditHelp(output, stdout_writer),
                }
                try stdout_writer.flush();
                continue;
            }
            break;
        }
    }

    const summary = session.summary();
    if (!summary.quit_early and session.status() == .complete) {
        try writeExitReview(
            allocator,
            stdout_writer,
            session.currentText(),
            session.expectedFinalText(),
            stdout_supports_color,
            options.use_pager,
        );
    }

    try writeSummary(
        output,
        stdout_writer,
        start_revision,
        end_revision,
        summary,
        session.currentText().len,
        session.skippedHistoryLen(),
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

fn writeDiagnostics(
    writer: *std.Io.Writer,
    diagnostics: []const zdelta_session.AttachDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        try writeLengthMismatchDiagnosis(
            writer,
            diagnostic.current_revision,
            diagnostic.target_revision,
            diagnostic.current_bytes,
            diagnostic.skipped_history_len,
            diagnostic.delta_before_len,
            diagnostic.target_bytes,
        );
    }
    if (diagnostics.len != 0) try writer.flush();
}

fn promptText(prompt_kind: zdelta_session.SessionPrompt) []const u8 {
    return switch (prompt_kind) {
        .delta => "[y] apply  [n] skip  [s] split  [q] quit  [?] help > ",
        .edit => "[y] apply  [n] skip  [a] apply rest  [d] skip rest  [q] quit  [?] help > ",
    };
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

fn renderInteractionState(
    output: OutputClient,
    writer: anytype,
    state: zdelta_context.InteractionState,
    use_color: bool,
) !void {
    const show_focus = state.prompt_kind == .edit;

    try output.print(writer, "\n=== revision {d} -> {d} ({s}) ===\n", .{
        state.session.current_revision,
        state.session.target_revision,
        state.session.relative_path,
    });
    try output.print(
        writer,
        "current bytes: {d}  target bytes: {d}  skipped history: {d}\n",
        .{
            state.facts.current_bytes,
            state.facts.target_bytes,
            state.facts.skipped_history_len,
        },
    );
    if (show_focus) {
        if (state.focus) |focus| {
            try output.print(
                writer,
                "focus: change {d} @ {d}\n",
                .{
                    focus.change_number,
                    focus.text_index,
                },
            );
        }
    }

    for (state.sections.items) |section| {
        if (!show_focus and section.kind == .focused_edit) continue;
        try output.writeLineEnding(writer);
        try output.print(writer, "--- {s} ---\n", .{section.label});
        if (use_color) {
            try renderDocumentAnsi(output, writer, section.document);
        } else {
            try renderDocumentPlain(output, writer, section.document);
        }
    }
}

fn renderDocumentAnsi(
    output: OutputClient,
    writer: anytype,
    document: zdelta_context.DocumentModel,
) !void {
    var marker = MarkedDocument.init(output.allocator, document.text);
    defer marker.deinit();

    for (document.annotations) |annotation| {
        if (annotation.len == 0) continue;
        const mark_kind = annotationToMark(annotation) orelse continue;
        try marker.markFrom(mark_kind, annotation.start, annotation.len);
    }

    var xprint = MarkedDocument.XtermLineWriter(@TypeOf(writer)).init(&marker, xterm_marks, writer);
    defer xprint.deinit();

    var boundary_index: usize = 0;
    var line_index: u32 = 0;
    while (try xprint.next()) |_| {
        try writeBoundaries(output, writer, document.boundaries, &boundary_index, line_index);
        try output.writeLineEnding(writer);
        line_index += 1;
    }
    try writeBoundaries(output, writer, document.boundaries, &boundary_index, line_index);
}

fn renderDocumentPlain(
    output: OutputClient,
    writer: anytype,
    document: zdelta_context.DocumentModel,
) !void {
    var boundary_index: usize = 0;
    for (document.line_starts, 0..) |line_start, line_index| {
        try writeBoundaries(output, writer, document.boundaries, &boundary_index, @intCast(line_index));
        const line = lineSlice(document, @intCast(line_index), line_start);
        try writer.writeByte(' ');
        try writePlainAnnotatedLine(output, writer, document, @intCast(line_index), line);
        try output.writeLineEnding(writer);
    }
    try writeBoundaries(output, writer, document.boundaries, &boundary_index, @intCast(document.lineCount()));
}

fn writeBoundaries(
    output: OutputClient,
    writer: anytype,
    boundaries: []const zdelta_context.BoundaryMarker,
    boundary_index: *usize,
    line_index: u32,
) !void {
    while (boundary_index.* < boundaries.len and boundaries[boundary_index.*].line_index == line_index) {
        const boundary = boundaries[boundary_index.*];
        switch (boundary.kind) {
            .elision => {
                try output.print(writer, " ... {d};{d}\n", .{
                    boundary.before_line,
                    boundary.after_line,
                });
            },
            .eof => try output.writeText(writer, " ---[eof]---\n"),
        }
        boundary_index.* += 1;
    }
}

fn lineSlice(
    document: zdelta_context.DocumentModel,
    line_index: u32,
    line_start: u32,
) []const u8 {
    const start: usize = @intCast(line_start);
    const next_index: usize = @intCast(line_index + 1);
    const end: usize = if (next_index < document.line_starts.len)
        document.line_starts[next_index]
    else
        document.text.len;
    return document.text[start..end];
}

fn writePlainAnnotatedLine(
    output: OutputClient,
    writer: anytype,
    document: zdelta_context.DocumentModel,
    line_index: u32,
    line: []const u8,
) !void {
    const start = document.line_starts[line_index];
    const end = start + line.len;
    const display_line = std.mem.trimRight(u8, line, "\n");
    var primary: ?zdelta_context.Annotation = null;
    for (document.annotations) |annotation| {
        if (annotation.start == start and annotation.start + annotation.len == end) {
            switch (annotation.kind) {
                .insert, .delete => {
                    if (primary == null) primary = annotation;
                },
                .focus, .blocked, .rewritten => {},
            }
        }
    }

    if (primary) |annotation| {
        switch (annotation.kind) {
            .insert => try output.print(writer, "{{+{s}+}}", .{display_line}),
            .delete => try output.print(writer, "[-{s}-]", .{display_line}),
            .focus, .blocked, .rewritten => unreachable,
        }
    } else {
        try output.writeText(writer, display_line);
    }
}

fn annotationToMark(annotation: zdelta_context.Annotation) ?ViewMark {
    return switch (annotation.kind) {
        .insert => switch (annotation.provenance) {
            .target_revision => .target_insert,
            .skipped_history => .skipped_insert,
        },
        .delete => switch (annotation.provenance) {
            .target_revision => .target_delete,
            .skipped_history => .skipped_delete,
        },
        .focus => .focus,
        .blocked => .blocked,
        .rewritten => .rewritten,
    };
}

fn writeDeltaHelp(output: OutputClient, writer: *std.Io.Writer) !void {
    try output.writeText(
        writer,
        "y: apply the whole delta\n" ++
            "n: skip the whole delta\n" ++
            "s: review one mutation at a time\n" ++
            "q: stop the session\n",
    );
}

fn writeEditHelp(output: OutputClient, writer: *std.Io.Writer) !void {
    try output.writeText(
        writer,
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
    summary: zdelta_session.SessionSummary,
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

    if (use_pager and tryWriteExitReviewPager(allocator, &diff, use_color)) return;

    _ = if (use_color)
        try diff.writePrettyFormat(allocator, stdout_writer, .xterm_classic)
    else
        try diff.writePrettyFormat(allocator, stdout_writer, plain_diff_decorations);
}

fn tryWriteExitReviewPager(
    allocator: Allocator,
    diff: *const dmp.Diff,
    use_color: bool,
) bool {
    var stdout = std.fs.File.stdout();
    stdout.lock(.exclusive) catch return false;
    defer stdout.unlock();

    var pager = std.process.Child.init(
        if (use_color) &.{ "less", "-R" } else &.{"less"},
        allocator,
    );
    pager.stdin_behavior = .Pipe;
    pager.stdout_behavior = .Inherit;
    pager.stderr_behavior = .Inherit;
    pager.spawn() catch return false;
    errdefer {
        if (pager.stdin) |stdin| stdin.close();
        _ = pager.wait() catch {};
    }

    const pager_stdin = pager.stdin orelse return false;
    {
        var pager_buf: [4096]u8 = undefined;
        var pager_writer = pager_stdin.writer(&pager_buf);
        const written = if (use_color)
            diff.writePrettyFormat(allocator, &pager_writer.interface, .xterm_classic)
        else
            diff.writePrettyFormat(allocator, &pager_writer.interface, plain_diff_decorations);
        _ = written catch return false;
        pager_writer.interface.flush() catch return false;
    }

    pager_stdin.close();
    pager.stdin = null;
    _ = pager.wait() catch return false;
    return true;
}

fn writeLengthMismatchDiagnosis(
    writer: *std.Io.Writer,
    current_revision: usize,
    target_revision: usize,
    current_len: usize,
    skipped_history_len: usize,
    delta_before_len: u32,
    target_len: usize,
) !void {
    try writer.print(
        "delta-tool diagnosis: length mismatch while attaching revision {d} -> {d}\n" ++
            "current bytes: {d}\n" ++
            "skipped history: {d}\n" ++
            "incoming delta expects before-length: {d}\n" ++
            "target revision bytes: {d}\n" ++
            "This usually means delta-application bookkeeping drifted from the corpus baseline.\n",
        .{
            current_revision,
            target_revision,
            current_len,
            skipped_history_len,
            delta_before_len,
            target_len,
        },
    );
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

test "render interaction state writes plain review sections" {
    const allocator = std.testing.allocator;
    var document = zdelta_context.DocumentModel{
        .text = try allocator.dupe(u8, "same\n"),
        .line_starts = try allocator.dupe(u32, &.{0}),
        .annotations = try allocator.dupe(zdelta_context.Annotation, &.{}),
        .boundaries = try allocator.dupe(zdelta_context.BoundaryMarker, &.{
            .{
                .line_index = 1,
                .kind = .elision,
                .before_line = 4,
                .after_line = 9,
            },
            .{
                .line_index = 1,
                .kind = .eof,
            },
        }),
    };
    defer document.deinit(allocator);
    var sections = ArrayList(zdelta_context.Section).init(allocator);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit();
    }
    try sections.append(.{
        .kind = .overview,
        .label = try allocator.dupe(u8, "target revision"),
        .provenance = .target_revision,
        .document = .{
            .text = try allocator.dupe(u8, document.text),
            .line_starts = try allocator.dupe(u32, document.line_starts),
            .annotations = try allocator.dupe(zdelta_context.Annotation, document.annotations),
            .boundaries = try allocator.dupe(zdelta_context.BoundaryMarker, document.boundaries),
        },
    });

    var state = zdelta_context.InteractionState{
        .prompt_kind = .delta,
        .session = .{
            .current_revision = 1,
            .target_revision = 2,
            .relative_path = try allocator.dupe(u8, "corpus/diff/sample.wiki"),
        },
        .facts = .{
            .current_bytes = 5,
            .target_bytes = 7,
            .skipped_history_len = 0,
        },
        .focus = null,
        .sections = sections,
    };
    defer {
        state.sections = .init(allocator);
        state.session.deinit(allocator);
    }

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    var out_writer = out.writer();
    _ = &out_writer;
    try renderInteractionState(OutputClient.init(allocator, false), &out_writer, state, false);

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "--- target revision ---"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " same\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " ... 4;9\n"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " ---[eof]---\n"));
}

test "render interaction state hides focused data at delta prompt" {
    const allocator = std.testing.allocator;
    var document = zdelta_context.DocumentModel{
        .text = try allocator.dupe(u8, "line\n"),
        .line_starts = try allocator.dupe(u32, &.{0}),
        .annotations = try allocator.dupe(zdelta_context.Annotation, &.{}),
        .boundaries = try allocator.dupe(zdelta_context.BoundaryMarker, &.{}),
    };
    defer document.deinit(allocator);

    var sections = ArrayList(zdelta_context.Section).init(allocator);
    defer {
        for (sections.items) |*section| section.deinit(allocator);
        sections.deinit();
    }
    try sections.append(.{
        .kind = .overview,
        .label = try allocator.dupe(u8, "target revision"),
        .provenance = .target_revision,
        .document = .{
            .text = try allocator.dupe(u8, document.text),
            .line_starts = try allocator.dupe(u32, document.line_starts),
            .annotations = try allocator.dupe(zdelta_context.Annotation, document.annotations),
            .boundaries = try allocator.dupe(zdelta_context.BoundaryMarker, document.boundaries),
        },
    });
    try sections.append(.{
        .kind = .focused_edit,
        .label = try allocator.dupe(u8, "next change"),
        .provenance = .target_revision,
        .document = .{
            .text = try allocator.dupe(u8, document.text),
            .line_starts = try allocator.dupe(u32, document.line_starts),
            .annotations = try allocator.dupe(zdelta_context.Annotation, document.annotations),
            .boundaries = try allocator.dupe(zdelta_context.BoundaryMarker, document.boundaries),
        },
    });

    var state = zdelta_context.InteractionState{
        .prompt_kind = .delta,
        .session = .{
            .current_revision = 1,
            .target_revision = 2,
            .relative_path = try allocator.dupe(u8, "corpus/diff/sample.wiki"),
        },
        .facts = .{
            .current_bytes = 5,
            .target_bytes = 5,
            .skipped_history_len = 0,
        },
        .focus = .{
            .text_index = 0,
            .change_number = 1,
            .effect = .{ .insert = "x" },
            .state = .unchanged,
        },
        .sections = sections,
    };
    defer {
        state.sections = .init(allocator);
        state.session.deinit(allocator);
    }

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    var out_writer = out.writer();
    _ = &out_writer;
    try renderInteractionState(OutputClient.init(allocator, false), &out_writer, state, false);

    try std.testing.expect(!std.mem.containsAtLeast(u8, out.items, 1, "focus: edit"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, out.items, 1, "--- next change ---"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "--- target revision ---"));
}

test "render document ansi uses obelizmo for annotated lines" {
    const allocator = std.testing.allocator;
    var document = zdelta_context.DocumentModel{
        .text = try allocator.dupe(u8, "green\n"),
        .line_starts = try allocator.dupe(u32, &.{0}),
        .annotations = try allocator.dupe(zdelta_context.Annotation, &.{
            .{
                .start = 0,
                .len = 6,
                .kind = .insert,
                .provenance = .target_revision,
            },
            .{
                .start = 0,
                .len = 6,
                .kind = .focus,
                .provenance = .target_revision,
            },
        }),
        .boundaries = try allocator.dupe(zdelta_context.BoundaryMarker, &.{}),
    };
    defer document.deinit(allocator);

    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    var out_writer = out.writer();
    _ = &out_writer;
    try renderDocumentAnsi(OutputClient.init(allocator, false), &out_writer, document);

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "\x1b["));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "green"));
}

const std = @import("std");
const dmp = @import("dmp.zig");
const obelizmo = @import("obelizmo");
const corpus_contract = @import("corpus_contract");
const zdelta_context = @import("zdelta/context.zig");
const zdelta_session = @import("zdelta/session.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const MarkedDocument = obelizmo.MarkedString(ViewMark);
const colors = obelizmo.colors;
