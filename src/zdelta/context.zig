//! zDelta Context
//!
//! This is the projection layer for interactive zdelta review.
//!
//! It knows about lines, excerpts, annotations, and semantic review sections.
//! It does not know how snapshots were produced, how input will be collected,
//! or how documents will be painted to a terminal.

const std = @import("std");
const dmp = @import("../dmp.zig");
const session_mod = @import("session.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Edit = dmp.Edit;
const DiffContext = dmp.DiffContext;
pub const ContextSettings = struct {
    whole_delta_context_lines: usize,
    edit_context_lines: usize,
};

pub const ContentProvenance = enum {
    target_revision,
    skipped_history,
};

pub const AnnotationKind = enum {
    insert,
    delete,
    focus,
    blocked,
    rewritten,
};

pub const Annotation = struct {
    start: u32,
    len: u32,
    kind: AnnotationKind,
    provenance: ContentProvenance,
    delta_index: ?u32 = null,
    skip_index: ?u32 = null,
};

pub const BoundaryMarker = struct {
    pub const Kind = enum {
        elision,
        eof,
    };

    line_index: u32,
    kind: Kind,
    before_line: u32 = 0,
    after_line: u32 = 0,
};

pub const DocumentModel = struct {
    text: []u8,
    line_starts: []u32,
    annotations: []Annotation,
    boundaries: []BoundaryMarker,

    pub fn deinit(document: *DocumentModel, allocator: Allocator) void {
        allocator.free(document.text);
        allocator.free(document.line_starts);
        allocator.free(document.annotations);
        allocator.free(document.boundaries);
        document.* = undefined;
    }

    pub fn lineCount(document: DocumentModel) usize {
        return document.line_starts.len;
    }
};

pub const SectionKind = enum {
    overview,
    focused_edit,
    skipped_history,
};

pub const Section = struct {
    kind: SectionKind,
    label: []u8,
    provenance: ?ContentProvenance,
    document: DocumentModel,

    pub fn deinit(section: *Section, allocator: Allocator) void {
        allocator.free(section.label);
        section.document.deinit(allocator);
        section.* = undefined;
    }
};

pub const Focus = struct {
    text_index: u32,
    change_number: usize,
    effect: session_mod.FocusEffect,
    state: dmp.HarmonizedOpState,
};

pub const StatusFacts = struct {
    current_bytes: usize,
    target_bytes: usize,
    skipped_history_len: usize,
};

pub const SessionInfo = struct {
    current_revision: usize,
    target_revision: usize,
    relative_path: []u8,

    pub fn deinit(session: *SessionInfo, allocator: Allocator) void {
        allocator.free(session.relative_path);
        session.* = undefined;
    }
};

pub const InteractionState = struct {
    prompt_kind: session_mod.SessionPrompt,
    session: SessionInfo,
    facts: StatusFacts,
    focus: ?Focus,
    sections: ArrayList(Section),

    pub fn deinit(state: *InteractionState) void {
        const allocator = state.sections.allocator;
        for (state.sections.items) |*section| section.deinit(state.sections.allocator);
        state.sections.deinit();
        state.session.deinit(allocator);
        state.* = undefined;
    }

    pub fn build(
        allocator: Allocator,
        snapshot: session_mod.SessionSnapshot,
        settings: ContextSettings,
    ) !InteractionState {
        var state = InteractionState{
            .prompt_kind = snapshot.prompt_kind,
            .session = .{
                .current_revision = snapshot.current_revision,
                .target_revision = snapshot.target_revision,
                .relative_path = try allocator.dupe(u8, snapshot.relative_path),
            },
            .facts = .{
                .current_bytes = snapshot.facts.current_bytes,
                .target_bytes = snapshot.facts.target_bytes,
                .skipped_history_len = snapshot.facts.skipped_history_len,
            },
            .focus = if (snapshot.focus) |focus|
                .{
                    .text_index = focus.text_index,
                    .change_number = focus.change_number,
                    .effect = focus.effect,
                    .state = focus.state,
                }
            else
                null,
            .sections = ArrayList(Section).init(allocator),
        };
        errdefer state.deinit();

        try state.appendOverviewSection(snapshot.current_text, snapshot.target_text, settings);
        if (state.focus) |focus| {
            const label = switch (snapshot.prompt_kind) {
                .delta => "next change",
                .edit => try std.fmt.allocPrint(allocator, "change {d}", .{focus.change_number}),
            };
            defer if (snapshot.prompt_kind == .edit) allocator.free(label);
            try state.appendFocusedSection(snapshot.current_text, focus, settings, label);
        }
        try state.appendSkippedHistorySections(snapshot.skipped);
        return state;
    }

    fn appendOverviewSection(
        state: *InteractionState,
        before: []const u8,
        after: []const u8,
        settings: ContextSettings,
    ) !void {
        var diff: dmp.Diff = .default;
        defer diff.deinit(state.sections.allocator);
        _ = try diff.diff(state.sections.allocator, before, after);

        var ctx = try dmp.DiffContext.fromDiff(state.sections.allocator, diff);
        defer ctx.deinit(state.sections.allocator);

        try state.sections.append(.{
            .kind = .overview,
            .label = try state.sections.allocator.dupe(u8, "target revision"),
            .provenance = .target_revision,
            .document = try buildContextDocument(
                state.sections.allocator,
                ctx,
                settings.whole_delta_context_lines,
                .{
                    .provenance = .target_revision,
                },
            ),
        });
    }

    fn appendFocusedSection(
        state: *InteractionState,
        before: []const u8,
        focus: Focus,
        settings: ContextSettings,
        label: []const u8,
    ) !void {
        const offset: usize = @intCast(focus.text_index);
        const delete_len: usize = switch (focus.effect) {
            .delete => |len| len,
            .insert, .equal => 0,
        };
        const suffix_origin = offset + delete_len;
        const snippet_start = lineStartForContext(before, offset, settings.edit_context_lines);
        const snippet_end = lineEndForContext(before, suffix_origin, settings.edit_context_lines);
        const prefix = before[snippet_start..offset];
        const deleted = before[offset..suffix_origin];
        const suffix = before[suffix_origin..snippet_end];
        const inserted = switch (focus.effect) {
            .insert => |text| text,
            .delete, .equal => "",
        };

        const excerpt_before = try join3(state.sections.allocator, prefix, deleted, suffix);
        defer state.sections.allocator.free(excerpt_before);
        const excerpt_after = try join3(state.sections.allocator, prefix, inserted, suffix);
        defer state.sections.allocator.free(excerpt_after);

        var diff: dmp.Diff = .default;
        defer diff.deinit(state.sections.allocator);
        _ = try diff.diff(state.sections.allocator, excerpt_before, excerpt_after);

        var ctx = try dmp.DiffContext.fromDiff(state.sections.allocator, diff);
        defer ctx.deinit(state.sections.allocator);

        try state.sections.append(.{
            .kind = .focused_edit,
            .label = try state.sections.allocator.dupe(u8, label),
            .provenance = .target_revision,
            .document = try buildContextDocument(
                state.sections.allocator,
                ctx,
                settings.edit_context_lines,
                .{
                    .provenance = .target_revision,
                    .delta_index = @intCast(focus.change_number - 1),
                    .focused = true,
                    .op_state = focus.state,
                },
            ),
        });
    }

    fn appendSkippedHistorySections(
        state: *InteractionState,
        skipped_items: []const session_mod.SkippedChange,
    ) !void {
        for (skipped_items) |skipped| {
            var document = try buildSkippedDocument(state.sections.allocator, skipped);
            errdefer document.deinit(state.sections.allocator);

            try state.sections.append(.{
                .kind = .skipped_history,
                .label = try std.fmt.allocPrint(
                    state.sections.allocator,
                    "skipped {d} [{s}]",
                    .{ skipped.number, skippedKindName(skipped.kind) },
                ),
                .provenance = .skipped_history,
                .document = document,
            });
        }
    }
};

const DocumentBuilder = struct {
    allocator: Allocator,
    text: ArrayList(u8),
    line_starts: ArrayList(u32),
    annotations: ArrayList(Annotation),
    boundaries: ArrayList(BoundaryMarker),

    fn init(allocator: Allocator) DocumentBuilder {
        return .{
            .allocator = allocator,
            .text = ArrayList(u8).init(allocator),
            .line_starts = ArrayList(u32).init(allocator),
            .annotations = ArrayList(Annotation).init(allocator),
            .boundaries = ArrayList(BoundaryMarker).init(allocator),
        };
    }

    fn deinit(builder: *DocumentBuilder) void {
        builder.text.deinit();
        builder.line_starts.deinit();
        builder.annotations.deinit();
        builder.boundaries.deinit();
        builder.* = undefined;
    }

    fn appendBoundary(builder: *DocumentBuilder, boundary: BoundaryMarker) !void {
        try builder.boundaries.append(boundary);
    }

    fn appendLine(
        builder: *DocumentBuilder,
        line: []const u8,
        meta: ?AppendMeta,
    ) !void {
        const start: u32 = @intCast(builder.text.items.len);
        try builder.line_starts.append(start);
        try builder.text.appendSlice(line);

        if (meta) |owned| {
            if (owned.kind) |kind| {
                try builder.annotations.append(.{
                    .start = start,
                    .len = @intCast(line.len),
                    .kind = kind,
                    .provenance = owned.provenance,
                    .delta_index = owned.delta_index,
                    .skip_index = owned.skip_index,
                });
            }
            if (owned.focused and line.len != 0) {
                try builder.annotations.append(.{
                    .start = start,
                    .len = @intCast(line.len),
                    .kind = .focus,
                    .provenance = owned.provenance,
                    .delta_index = owned.delta_index,
                    .skip_index = owned.skip_index,
                });
            }
            if (owned.op_state) |state| switch (state) {
                .blocked => try builder.annotations.append(.{
                    .start = start,
                    .len = @intCast(line.len),
                    .kind = .blocked,
                    .provenance = owned.provenance,
                    .delta_index = owned.delta_index,
                    .skip_index = owned.skip_index,
                }),
                .rewritten => try builder.annotations.append(.{
                    .start = start,
                    .len = @intCast(line.len),
                    .kind = .rewritten,
                    .provenance = owned.provenance,
                    .delta_index = owned.delta_index,
                    .skip_index = owned.skip_index,
                }),
                .unchanged => {},
            };
        }
    }

    fn finish(builder: *DocumentBuilder) !DocumentModel {
        return .{
            .text = try builder.text.toOwnedSlice(),
            .line_starts = try builder.line_starts.toOwnedSlice(),
            .annotations = try builder.annotations.toOwnedSlice(),
            .boundaries = try builder.boundaries.toOwnedSlice(),
        };
    }
};

const AppendMeta = struct {
    provenance: ContentProvenance,
    kind: ?AnnotationKind = null,
    delta_index: ?u32 = null,
    skip_index: ?u32 = null,
    focused: bool = false,
    op_state: ?dmp.HarmonizedOpState = null,
};

fn buildContextDocument(
    allocator: Allocator,
    ctx: DiffContext,
    show_lines: usize,
    meta: AppendMeta,
) !DocumentModel {
    var builder = DocumentBuilder.init(allocator);
    errdefer builder.deinit();

    for (ctx.items.items, 0..) |item, index| {
        if (item.edit.operation != .equal) {
            try appendEditLines(&builder, item.edit, null, null, metaForEdit(meta, item.edit.operation));
            continue;
        }

        const line_count = countDisplayLines(item.edit.text);
        if (line_count == 0 or line_count <= show_lines) {
            try appendEditLines(&builder, item.edit, null, null, null);
            continue;
        }

        const is_first = index == 0;
        const is_last = index + 1 == ctx.items.items.len;
        const keep_head = if (is_last) show_lines else if (is_first) 0 else show_lines;
        const keep_tail = if (is_first) show_lines else if (is_last) 0 else show_lines;

        if (line_count <= keep_head + keep_tail) {
            try appendEditLines(&builder, item.edit, null, null, null);
            continue;
        }

        if (keep_head != 0) {
            const head_end = byteOffsetAfterLines(item.edit.text, keep_head);
            try appendEditLines(&builder, item.edit, 0, head_end, null);
        }

        const elision_line_offset = if (keep_head != 0 and keep_tail == 0)
            keep_head
        else
            line_count - keep_tail;
        if (is_last and keep_tail == 0) {
            try builder.appendBoundary(.{
                .line_index = @intCast(builder.line_starts.items.len),
                .kind = .eof,
            });
        } else {
            const numbers = lineNumbersAtOffset(item, elision_line_offset);
            try builder.appendBoundary(.{
                .line_index = @intCast(builder.line_starts.items.len),
                .kind = .elision,
                .before_line = numbers.before,
                .after_line = numbers.after,
            });
        }

        if (keep_tail != 0) {
            const tail_start = byteOffsetAfterLines(item.edit.text, line_count - keep_tail);
            try appendEditLines(&builder, item.edit, tail_start, null, null);
        }
    }

    return builder.finish();
}

fn buildSkippedDocument(
    allocator: Allocator,
    skipped: session_mod.SkippedChange,
) !DocumentModel {
    var builder = DocumentBuilder.init(allocator);
    errdefer builder.deinit();

    var cursor: usize = 0;
    const kind = switch (skipped.kind) {
        .insert => AnnotationKind.insert,
        .delete => AnnotationKind.delete,
    };
    while (nextDisplayLine(skipped.text, cursor)) |part| {
        try builder.appendLine(part.line, .{
            .provenance = .skipped_history,
            .kind = kind,
            .skip_index = @intCast(skipped.number - 1),
        });
        cursor = part.next;
    }

    return builder.finish();
}

fn metaForEdit(base: AppendMeta, operation: Edit.Operation) ?AppendMeta {
    const kind = switch (operation) {
        .insert => AnnotationKind.insert,
        .delete => AnnotationKind.delete,
        .equal => return null,
    };
    var meta = base;
    meta.kind = kind;
    return meta;
}

fn appendEditLines(
    builder: *DocumentBuilder,
    edit: Edit,
    start_offset_opt: ?usize,
    end_offset_opt: ?usize,
    meta: ?AppendMeta,
) !void {
    const text_start = start_offset_opt orelse 0;
    const text_end = end_offset_opt orelse edit.text.len;
    const text = edit.text[text_start..text_end];

    var cursor: usize = 0;
    while (nextDisplayLine(text, cursor)) |part| {
        try builder.appendLine(part.line, meta);
        cursor = part.next;
    }
}

fn join3(allocator: Allocator, a: []const u8, b: []const u8, c: []const u8) ![]u8 {
    var joined = try allocator.alloc(u8, a.len + b.len + c.len);
    @memcpy(joined[0..a.len], a);
    @memcpy(joined[a.len..][0..b.len], b);
    @memcpy(joined[a.len + b.len ..][0..c.len], c);
    return joined;
}

fn lineStartForContext(text: []const u8, at: usize, extra_lines: usize) usize {
    var idx = @min(at, text.len);
    while (idx > 0 and text[idx - 1] != '\n') idx -= 1;
    var remaining = extra_lines;
    while (idx > 0 and remaining != 0) : (remaining -= 1) {
        idx -= 1;
        while (idx > 0 and text[idx - 1] != '\n') idx -= 1;
    }
    return idx;
}

fn lineEndForContext(text: []const u8, at: usize, extra_lines: usize) usize {
    var idx = @min(at, text.len);
    var remaining = extra_lines + 1;
    while (idx < text.len and remaining != 0) {
        if (text[idx] == '\n') remaining -= 1;
        idx += 1;
    }
    return idx;
}

fn countDisplayLines(text: []const u8) usize {
    if (text.len == 0) return 0;

    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

fn nextDisplayLine(text: []const u8, cursor: usize) ?struct { line: []const u8, next: usize } {
    if (cursor >= text.len) return null;

    const suffix = text[cursor..];
    if (std.mem.indexOfScalar(u8, suffix, '\n')) |nl| {
        const end = cursor + nl + 1;
        return .{ .line = text[cursor..end], .next = end };
    }

    return .{ .line = text[cursor..], .next = text.len };
}

fn byteOffsetAfterLines(text: []const u8, lines: usize) usize {
    if (lines == 0) return 0;
    if (text.len == 0) return 0;

    var cursor: usize = 0;
    var remaining = lines;
    while (remaining > 0) {
        const part = nextDisplayLine(text, cursor) orelse return text.len;
        cursor = part.next;
        remaining -= 1;
    }
    return cursor;
}

fn lineNumbersAtOffset(item: DiffContext.EditContext, line_offset: usize) struct { before: u32, after: u32 } {
    const offset: u32 = @intCast(line_offset);
    return .{
        .before = item.pre_start + offset,
        .after = item.post_start + offset,
    };
}

fn skippedKindName(kind: session_mod.SkippedKind) []const u8 {
    return switch (kind) {
        .insert => "insert",
        .delete => "delete",
    };
}

test "interaction state projects snapshot facts and skipped history" {
    const allocator = std.testing.allocator;
    const before = "alpha\nbeta\ngamma\ndelta\n";
    const after = "alpha\nbeta\ngamma changed\ndelta\nepsilon\n";
    const encoded = try encodeDelta(allocator, before, after);
    defer allocator.free(encoded);

    var session = try session_mod.ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 8,
            .relative_path = "corpus/diff/sample_8.wiki",
            .body = before,
        },
        .steps = &.{
            .{
                .ordinal = 9,
                .relative_path = "corpus/diff/sample_9.wiki",
                .target_body = after,
                .zdelta_text = encoded,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);
    var split = try session.dispatch(.split);
    defer split.deinit(allocator);
    var skip = try session.dispatch(.skip);
    defer skip.deinit(allocator);

    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);
    var state = try InteractionState.build(allocator, snapshot, .{
        .whole_delta_context_lines = 2,
        .edit_context_lines = 2,
    });
    defer state.deinit();

    try std.testing.expectEqual(session_mod.SessionPrompt.edit, state.prompt_kind);
    try std.testing.expect(state.sections.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), state.facts.skipped_history_len);
}

test "edit interaction state exposes focused provenance" {
    const allocator = std.testing.allocator;
    const before = "alpha\nbeta\ngamma\ndelta\n";
    const after = "alpha\nbeta\ngamma changed\ndelta\nepsilon\n";
    const encoded = try encodeDelta(allocator, before, after);
    defer allocator.free(encoded);

    var session = try session_mod.ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 8,
            .relative_path = "corpus/diff/sample_8.wiki",
            .body = before,
        },
        .steps = &.{
            .{
                .ordinal = 9,
                .relative_path = "corpus/diff/sample_9.wiki",
                .target_body = after,
                .zdelta_text = encoded,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);
    var split = try session.dispatch(.split);
    defer split.deinit(allocator);
    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);

    var state = try InteractionState.build(allocator, snapshot, .{
        .whole_delta_context_lines = 2,
        .edit_context_lines = 2,
    });
    defer state.deinit();

    try std.testing.expectEqual(session_mod.SessionPrompt.edit, state.prompt_kind);
    try std.testing.expectEqual(snapshot.focus.?.change_number, state.focus.?.change_number);

    var found_focus = false;
    for (state.sections.items) |section| {
        if (section.kind != .focused_edit) continue;
        for (section.document.annotations) |annotation| {
            if (annotation.kind == .focus and annotation.provenance == .target_revision) {
                found_focus = true;
            }
        }
    }
    try std.testing.expect(found_focus);
}

test "controller boundaries are semantic markers, not embedded strings" {
    const allocator = std.testing.allocator;
    const before = "before\none\ntwo\nthree\nfour\n";
    const after = "one\ntwo\nthree\nfour\n";
    const encoded = try encodeDelta(allocator, before, after);
    defer allocator.free(encoded);

    var session = try session_mod.ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 1,
            .relative_path = "corpus/diff/sample_1.wiki",
            .body = before,
        },
        .steps = &.{
            .{
                .ordinal = 2,
                .relative_path = "corpus/diff/sample_2.wiki",
                .target_body = after,
                .zdelta_text = encoded,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);
    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);
    var state = try InteractionState.build(allocator, snapshot, .{
        .whole_delta_context_lines = 2,
        .edit_context_lines = 2,
    });
    defer state.deinit();

    var found_boundary = false;
    for (state.sections.items) |section| {
        if (section.kind != .overview) continue;
        found_boundary = section.document.boundaries.len != 0;
        try std.testing.expect(!std.mem.containsAtLeast(u8, section.document.text, 1, "..."));
    }
    try std.testing.expect(found_boundary);
}

fn encodeDelta(allocator: Allocator, before: []const u8, after: []const u8) ![]const u8 {
    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);
    return try diff.toZDelta(allocator, .b);
}
