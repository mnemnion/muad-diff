//! User-facing paint subsystem for delta-tool.
//!
//! The session/replay logic decides what the tool is doing; `Painter` decides
//! how that state is surfaced to the operator. That includes prompt frames,
//! live repaint policy, help and summary text, diagnostics on stderr, and the
//! mismatch-review diff shown at clean exit.

pub const CursorAnchor = struct {
    row: u16,
    col: u16,
};

pub const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

pub const TerminalProbe = struct {
    context: *anyopaque,
    read_cursor_anchor: *const fn (*anyopaque, *std.Io.Writer) anyerror!CursorAnchor,
    read_terminal_size: *const fn (*anyopaque, *std.Io.Writer) anyerror!TerminalSize,

    pub fn readCursorAnchor(probe: TerminalProbe, writer: *std.Io.Writer) !CursorAnchor {
        return probe.read_cursor_anchor(probe.context, writer);
    }

    pub fn readTerminalSize(probe: TerminalProbe, writer: *std.Io.Writer) !TerminalSize {
        return probe.read_terminal_size(probe.context, writer);
    }
};

pub const Settings = struct {
    raw_mode: bool,
    stdout_supports_color: bool,
    use_pager: bool,
};

pub const Painter = struct {
    allocator: Allocator,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    settings: Settings,
    output: OutputClient,
    render_controller: LiveRenderController = .{},

    pub fn init(
        allocator: Allocator,
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
        settings: Settings,
    ) Painter {
        return .{
            .allocator = allocator,
            .stdout_writer = stdout_writer,
            .stderr_writer = stderr_writer,
            .settings = settings,
            .output = OutputClient.init(allocator, settings.raw_mode),
        };
    }

    pub fn setRawMode(painter: *Painter, raw_mode: bool) void {
        painter.settings.raw_mode = raw_mode;
        painter.output = OutputClient.init(painter.allocator, raw_mode);
    }

    pub fn supportsInPlaceRepaint(painter: *const Painter) bool {
        return painter.output.supportsInPlaceRepaint();
    }

    pub fn echoesAcceptedCommands(painter: *const Painter) bool {
        return !painter.supportsInPlaceRepaint();
    }

    pub fn writeUsage(painter: *Painter, exe_name: []const u8) !void {
        try painter.stderr_writer.print(
            "Usage: {s} [--replay <script>] <first-revision> <last-revision>\n",
            .{exe_name},
        );
        try painter.stderr_writer.writeAll("Try --help for more information.\n");
        try painter.stderr_writer.flush();
    }

    pub fn writeHelp(painter: *Painter, exe_name: []const u8) !void {
        try painter.stdout_writer.print(
            "Usage: {s} [--replay <script>] <first-revision> <last-revision>\n\n",
            .{exe_name},
        );
        try painter.stdout_writer.writeAll(
            "Interactive zdelta inspector for the checked-in corpus.\n\n" ++
                "Arguments:\n" ++
                "  --replay <script>  Replay a one-line command script of single-character actions.\n" ++
                "  <first-revision>  1-based starting revision ordinal.\n" ++
                "  <last-revision>   1-based ending revision ordinal, greater than the first.\n\n" ++
                "Revision 0 is the implicit pre-history baseline and is not passed on the command line.\n",
        );
        try painter.stdout_writer.flush();
    }

    pub fn writeDiagnostics(
        painter: *Painter,
        diagnostics: []const zdelta_session.AttachDiagnostic,
    ) !void {
        for (diagnostics) |diagnostic| {
            try writeLengthMismatchDiagnosis(
                painter.stderr_writer,
                diagnostic.current_revision,
                diagnostic.target_revision,
                diagnostic.current_bytes,
                diagnostic.skipped_history_len,
                diagnostic.delta_before_len,
                diagnostic.target_bytes,
            );
        }
        if (diagnostics.len != 0) try painter.stderr_writer.flush();
    }

    pub fn renderPromptFrame(
        painter: *Painter,
        probe: ?TerminalProbe,
        state: zdelta_context.InteractionState,
    ) !void {
        try painter.render_controller.renderPromptFrame(
            painter.output,
            painter.stdout_writer,
            probe,
            state,
            painter.settings.stdout_supports_color,
        );
        try painter.stdout_writer.flush();
    }

    pub fn previewIntent(
        painter: *Painter,
        state: *zdelta_context.InteractionState,
        intent: zdelta_session.SessionIntent,
    ) bool {
        _ = painter;
        return previewSkipProvenanceChange(state, intent);
    }

    pub fn writePromptHelp(
        painter: *Painter,
        prompt_kind: zdelta_session.SessionPrompt,
    ) !void {
        switch (prompt_kind) {
            .delta => try writeDeltaHelp(painter.output, painter.stdout_writer),
            .edit => try writeEditHelp(painter.output, painter.stdout_writer),
        }
        try painter.output.writeText(painter.stdout_writer, promptText(prompt_kind));
        try painter.stdout_writer.flush();
    }

    pub fn writeExitReview(
        painter: *Painter,
        final_text: []const u8,
        expected_text: []const u8,
    ) !void {
        if (!painter.settings.use_pager or std.mem.eql(u8, final_text, expected_text)) return;

        var diff: dmp.Diff = .default;
        defer diff.deinit(painter.allocator);
        _ = try diff.diff(painter.allocator, final_text, expected_text);
        _ = try diff.cleanupSemantic(painter.allocator);

        if (painter.settings.use_pager and tryWriteExitReviewPager(
            painter.allocator,
            &diff,
            painter.settings.stdout_supports_color,
        )) return;

        _ = if (painter.settings.stdout_supports_color)
            try diff.writePrettyFormat(painter.allocator, painter.stdout_writer, .xterm_classic)
        else
            try diff.writePrettyFormat(painter.allocator, painter.stdout_writer, plain_diff_decorations);
        try painter.stdout_writer.flush();
    }

    pub fn writeSummary(
        painter: *Painter,
        start_revision: usize,
        end_revision: usize,
        summary: zdelta_session.SessionSummary,
        current_len: usize,
        skipped_history_len: usize,
    ) !void {
        try painter.output.print(
            painter.stdout_writer,
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
        try painter.stdout_writer.flush();
    }
};

const plain_diff_decorations: dmp.DiffDecorations = .{
    .delete_start = "[-",
    .delete_end = "-]",
    .insert_start = "{+",
    .insert_end = "+}",
};

const ESC = "\x1b";
const CSI = ESC ++ "[";
const ERASE_TO_SCREEN_END = CSI ++ "0J";
const SYNC_ON = CSI ++ "?2026h";
const SYNC_SEND = CSI ++ "?2026l";

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
    raw_mode: bool,

    fn init(allocator: Allocator, raw_mode: bool) OutputClient {
        return .{
            .allocator = allocator,
            .line_ending = if (raw_mode) "\r\n" else "\n",
            .raw_mode = raw_mode,
        };
    }

    fn writeLineEnding(output: OutputClient, writer: anytype) !void {
        try writer.writeAll(output.line_ending);
    }

    fn writeText(output: OutputClient, writer: anytype, text: []const u8) !void {
        if (output.line_ending.len == 1) {
            try writer.writeAll(text);
            return;
        }

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |idx| {
            try writer.writeAll(text[start..idx]);
            try writer.writeAll(output.line_ending);
            start = idx + 1;
        }
        try writer.writeAll(text[start..]);
    }

    fn print(output: OutputClient, writer: anytype, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(output.allocator, fmt, args);
        defer output.allocator.free(text);
        try output.writeText(writer, text);
    }

    fn writeControl(output: OutputClient, writer: anytype, sequence: []const u8) !void {
        if (!output.raw_mode) return;
        try writer.writeAll(sequence);
    }

    fn supportsInPlaceRepaint(output: OutputClient) bool {
        return output.raw_mode;
    }
};

const LiveRenderController = struct {
    anchor: ?CursorAnchor = null,

    // Raw interactive output is redrawn as one synchronized frame because the
    // terminal transport owns repaint policy, while replay/plain output keeps
    // its append-only transcript shape for tests and captured logs.
    fn renderPromptFrame(
        controller: *LiveRenderController,
        output: OutputClient,
        writer: *std.Io.Writer,
        probe: ?TerminalProbe,
        state: zdelta_context.InteractionState,
        use_color: bool,
    ) !void {
        if (!output.supportsInPlaceRepaint()) {
            try renderPromptContents(output, writer, state, use_color);
            return;
        }

        const owned_probe = probe orelse return error.LiveRenderProbeMissing;
        if (controller.anchor == null) {
            const start = try owned_probe.readCursorAnchor(writer);
            const size = try owned_probe.readTerminalSize(writer);

            var frame_buffer: std.Io.Writer.Allocating = .init(output.allocator);
            defer frame_buffer.deinit();
            try renderPromptContents(output, &frame_buffer.writer, state, use_color);
            const frame = frame_buffer.written();
            const frame_rows = countRenderedRows(frame, size.cols);
            const final_row = @as(u32, start.row) + frame_rows - 1;
            const scroll_rows = final_row -| size.rows;
            controller.anchor = .{
                .row = @intCast(@max(1, @as(i32, start.row) - @as(i32, @intCast(scroll_rows)))),
                .col = 1,
            };
            try writer.writeAll(frame);
            return;
        }

        const anchor = controller.anchor orelse return error.LiveRenderAnchorMissing;
        try output.writeControl(writer, SYNC_ON);
        defer output.writeControl(writer, SYNC_SEND) catch {};
        try writeCursorMove(writer, anchor);
        try output.writeControl(writer, ERASE_TO_SCREEN_END);
        try renderPromptContents(output, writer, state, use_color);
    }
};

fn promptText(prompt_kind: zdelta_session.SessionPrompt) []const u8 {
    return switch (prompt_kind) {
        .delta => "[y] apply  [n] skip  [s] split  [q] quit  [?] help > ",
        .edit => "[y] apply  [n] skip  [a] apply rest  [d] skip rest  [q] quit  [?] help > ",
    };
}

// The live repaint path stays dumb: skip commands preview their effect by
// flipping annotation provenance in the already-projected interaction state,
// then the terminal layer just redraws the frame in place.
fn previewSkipProvenanceChange(
    state: *zdelta_context.InteractionState,
    intent: zdelta_session.SessionIntent,
) bool {
    return switch (intent) {
        .skip => switch (state.prompt_kind) {
            .delta => recolorVisibleTargetEdits(state, .all),
            .edit => recolorVisibleTargetEdits(state, .first),
        },
        .skip_rest => recolorVisibleTargetEdits(state, .all),
        .apply, .split, .quit, .help, .apply_rest => false,
    };
}

const RecolorMode = enum {
    first,
    all,
};

fn recolorVisibleTargetEdits(
    state: *zdelta_context.InteractionState,
    mode: RecolorMode,
) bool {
    const show_focus = state.prompt_kind == .edit;
    var changed = false;
    for (state.sections.items) |*section| {
        if (!show_focus and section.kind == .focused_edit) continue;
        for (section.document.annotations) |*annotation| {
            if (annotation.provenance != .target_revision) continue;
            switch (annotation.kind) {
                .insert, .delete => {
                    annotation.provenance = .skipped_history;
                    changed = true;
                    if (mode == .first) return true;
                },
                .focus, .blocked, .rewritten => {},
            }
        }
    }
    return changed;
}

fn writeCursorMove(writer: *std.Io.Writer, anchor: CursorAnchor) !void {
    var buf: [32]u8 = undefined;
    const sequence = try std.fmt.bufPrint(&buf, "{s}{d};{d}H", .{
        CSI,
        anchor.row,
        anchor.col,
    });
    try writer.writeAll(sequence);
}

fn countRenderedRows(text: []const u8, terminal_cols: u16) u32 {
    if (terminal_cols == 0) return 1;

    var rows: u32 = 1;
    var line_width: u16 = 0;
    var idx: usize = 0;
    while (idx < text.len) {
        const byte = text[idx];
        if (byte == 0x1b and idx + 1 < text.len and text[idx + 1] == '[') {
            idx += 2;
            while (idx < text.len) : (idx += 1) {
                const tail = text[idx];
                if (tail >= 0x40 and tail <= 0x7e) {
                    idx += 1;
                    break;
                }
            }
            continue;
        }
        if (byte == '\r') {
            idx += 1;
            continue;
        }
        if (byte == '\n') {
            rows += 1;
            line_width = 0;
            idx += 1;
            continue;
        }
        if (line_width == terminal_cols) {
            rows += 1;
            line_width = 0;
        }
        line_width += 1;
        idx += 1;
    }
    return rows;
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

fn renderPromptContents(
    output: OutputClient,
    writer: anytype,
    state: zdelta_context.InteractionState,
    use_color: bool,
) !void {
    try renderInteractionState(output, writer, state, use_color);
    try output.writeText(writer, promptText(state.prompt_kind));
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

    try std.testing.expect(!std.mem.containsAtLeast(u8, out.items, 1, "focus: change"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, out.items, 1, "--- next change ---"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "--- target revision ---"));
}

test "raw repaint frame uses synchronized updates" {
    const allocator = std.testing.allocator;
    var stdout_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_buffer.deinit();

    var document = zdelta_context.DocumentModel{
        .text = try allocator.dupe(u8, "line\n"),
        .line_starts = try allocator.dupe(u32, &.{0}),
        .annotations = try allocator.dupe(zdelta_context.Annotation, &.{
            .{
                .start = 0,
                .len = 5,
                .kind = .insert,
                .provenance = .skipped_history,
                .skip_index = 0,
            },
        }),
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

    var state = zdelta_context.InteractionState{
        .prompt_kind = .delta,
        .session = .{
            .current_revision = 1,
            .target_revision = 2,
            .relative_path = try allocator.dupe(u8, "corpus/diff/sample.wiki"),
        },
        .facts = .{
            .current_bytes = 4,
            .target_bytes = 5,
            .skipped_history_len = 1,
        },
        .focus = null,
        .sections = sections,
    };
    defer {
        state.sections = .init(allocator);
        state.session.deinit(allocator);
    }

    var painter = Painter.init(allocator, &stdout_buffer.writer, &stderr_buffer.writer, .{
        .raw_mode = true,
        .stdout_supports_color = false,
        .use_pager = false,
    });
    const probe = TerminalProbe{
        .context = undefined,
        .read_cursor_anchor = testReadCursorAnchor,
        .read_terminal_size = testReadTerminalSize,
    };

    try painter.renderPromptFrame(probe, state);
    const first = try allocator.dupe(u8, stdout_buffer.written());
    defer allocator.free(first);

    stdout_buffer.clearRetainingCapacity();
    try painter.renderPromptFrame(probe, state);
    const second = stdout_buffer.written();

    try std.testing.expect(!std.mem.containsAtLeast(u8, first, 1, SYNC_ON));
    try std.testing.expect(std.mem.startsWith(u8, second, SYNC_ON));
    try std.testing.expect(std.mem.containsAtLeast(u8, second, 1, CSI ++ "1;1H"));
    try std.testing.expect(std.mem.containsAtLeast(u8, second, 1, ERASE_TO_SCREEN_END));
    try std.testing.expect(std.mem.containsAtLeast(u8, second, 1, "--- target revision ---"));
}

fn testReadCursorAnchor(_: *anyopaque, _: *std.Io.Writer) anyerror!CursorAnchor {
    return .{ .row = 1, .col = 1 };
}

fn testReadTerminalSize(_: *anyopaque, _: *std.Io.Writer) anyerror!TerminalSize {
    return .{ .rows = 40, .cols = 120 };
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

test "writer helpers split stdout and stderr policy" {
    const allocator = std.testing.allocator;
    var stdout_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_buffer.deinit();

    var painter = Painter.init(allocator, &stdout_buffer.writer, &stderr_buffer.writer, .{
        .raw_mode = false,
        .stdout_supports_color = false,
        .use_pager = false,
    });
    try painter.writeHelp("delta-tool");
    try painter.writeUsage("delta-tool");

    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buffer.written(), 1, "Interactive zdelta inspector"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buffer.written(), 1, "Try --help for more information."));
}

const std = @import("std");
const dmp = @import("../dmp.zig");
const obelizmo = @import("obelizmo");
const zdelta_context = @import("../zdelta/context.zig");
const zdelta_session = @import("../zdelta/session.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const MarkedDocument = obelizmo.MarkedString(ViewMark);
const colors = obelizmo.colors;
