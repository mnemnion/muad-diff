//! zDelta Context
//!
//! This is the controller for interactive zdelta application.
//! It synthesizes promptable interaction state from the underlying model:
//! current text, attached delta, skipped-history state, and target revision.
//!
//! This file knows about lines and excerpts. It does not know about colors,
//! terminal escape sequences, or screen painting.

const std = @import("std");
const dmp = @import("../dmp.zig");
const zdelta = @import("../zdelta.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Edit = dmp.Edit;
const DiffContext = dmp.DiffContext;
const DeltaManager = dmp.DeltaManager;
const PreviewDeltaOp = dmp.PreviewDeltaOp;

pub const ContextSettings = struct {
    whole_delta_context_lines: usize = 2,
    edit_context_lines: usize = 2,
};

pub const RevisionInfo = struct {
    current_revision: usize,
    target_revision: usize,
    relative_path: []const u8,
};

pub const PromptKind = enum {
    delta,
    edit,
};

pub const Action = enum {
    apply,
    skip,
    split,
    quit,
    help,
    apply_rest,
    skip_rest,
};

pub const Provenance = enum {
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
    provenance: Provenance,
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
    provenance: ?Provenance,
    document: DocumentModel,

    pub fn deinit(section: *Section, allocator: Allocator) void {
        allocator.free(section.label);
        section.document.deinit(allocator);
        section.* = undefined;
    }
};

pub const Focus = struct {
    text_index: u32,
    delta_index: u32,
    effective: dmp.DeltaOp,
    state: dmp.HarmonizedOpState,
};

pub const StatusFacts = struct {
    current_bytes: usize,
    target_bytes: usize,
    skipped_history_len: usize,
    focused_delta_index: ?u32 = null,
    focused_state: ?dmp.HarmonizedOpState = null,
};

pub const SessionInfo = struct {
    current_revision: usize,
    target_revision: usize,
    relative_path: []u8,
    document_name: []u8,

    pub fn deinit(session: *SessionInfo, allocator: Allocator) void {
        allocator.free(session.relative_path);
        allocator.free(session.document_name);
        session.* = undefined;
    }
};

pub const InteractionState = struct {
    prompt_kind: PromptKind,
    actions: []const Action,
    session: SessionInfo,
    facts: StatusFacts,
    focus: ?Focus,
    sections: ArrayList(Section),

    pub fn init(
        allocator: Allocator,
        prompt_kind: PromptKind,
        revision: RevisionInfo,
        target_bytes: usize,
        tm: *const DeltaManager,
        focus: ?PreviewDeltaOp,
    ) !InteractionState {
        return .{
            .prompt_kind = prompt_kind,
            .actions = switch (prompt_kind) {
                .delta => &delta_actions,
                .edit => &edit_actions,
            },
            .session = .{
                .current_revision = revision.current_revision,
                .target_revision = revision.target_revision,
                .relative_path = try allocator.dupe(u8, revision.relative_path),
                .document_name = try allocator.dupe(u8, std.fs.path.basename(revision.relative_path)),
            },
            .facts = .{
                .current_bytes = tm.view().len,
                .target_bytes = target_bytes,
                .skipped_history_len = tm.skippedItems().len,
                .focused_delta_index = if (focus) |preview| preview.delta_index else null,
                .focused_state = if (focus) |preview| preview.op.state else null,
            },
            .focus = if (focus) |preview|
                .{
                    .text_index = preview.text_index,
                    .delta_index = preview.delta_index,
                    .effective = preview.op.effective,
                    .state = preview.op.state,
                }
            else
                null,
            .sections = ArrayList(Section).init(allocator),
        };
    }

    pub fn deinit(state: *InteractionState) void {
        const allocator = state.sections.allocator;
        for (state.sections.items) |*section| section.deinit(state.sections.allocator);
        state.sections.deinit();
        state.session.deinit(allocator);
        state.* = undefined;
    }
 
    pub fn buildDelta(
        allocator: Allocator,
        tm: *const DeltaManager,
        target_body: []const u8,
        revision: RevisionInfo,
        settings: ContextSettings,
    ) !InteractionState {
        const focus = try tm.previewNext();
        var state = try InteractionState.init(
            allocator,
            .delta,
            revision,
            target_body.len,
            tm,
            focus,
        );
        errdefer state.deinit();

        try state.appendOverviewSection(tm.view(), target_body, settings);
        if (focus) |preview| {
            try state.appendFocusedSection(tm.view(), tm.zdelta.?.insert_text, preview, settings, "next mutation");
        }
        try state.appendSkippedHistorySections(tm.skippedItems());
        return state;
    }

    pub fn buildEdit(
        allocator: Allocator,
        tm: *const DeltaManager,
        target_body: []const u8,
        revision: RevisionInfo,
        preview: PreviewDeltaOp,
        settings: ContextSettings,
    ) !InteractionState {
        var state = try InteractionState.init(
            allocator,
            .edit,
            revision,
            target_body.len,
            tm,
            preview,
        );
        errdefer state.deinit();

        try state.appendOverviewSection(tm.view(), target_body, settings);
        const label = try std.fmt.allocPrint(
            allocator,
            "edit {d} [{s}]",
            .{ preview.delta_index + 1, @tagName(preview.op.state) },
        );
        defer allocator.free(label);
        try state.appendFocusedSection(tm.view(), tm.zdelta.?.insert_text, preview, settings, label);
        try state.appendSkippedHistorySections(tm.skippedItems());
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
        insert_source: []const u8,
        preview: PreviewDeltaOp,
        settings: ContextSettings,
        label: []const u8,
    ) !void {
        const offset: usize = @intCast(preview.text_index);
        const delete_len: usize = switch (preview.op.effective) {
            .delete => |len| len,
            .insert, .equal => 0,
        };
        const suffix_origin = offset + delete_len;
        const snippet_start = lineStartForContext(before, offset, settings.edit_context_lines);
        const snippet_end = lineEndForContext(before, suffix_origin, settings.edit_context_lines);
        const prefix = before[snippet_start..offset];
        const deleted = before[offset..suffix_origin];
        const suffix = before[suffix_origin..snippet_end];
        const inserted = switch (preview.op.effective) {
            .insert => |span| insert_source[span.offset..][0..span.len],
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
                    .delta_index = preview.delta_index,
                    .focused = true,
                    .op_state = preview.op.state,
                },
            ),
        });
    }

    fn appendSkippedHistorySections(
        state: *InteractionState,
        skipped_items: anytype,
    ) !void {
        for (skipped_items, 0..) |skipped, index| {
            var document = try buildSkippedDocument(state.sections.allocator, skipped, @intCast(index));
            errdefer document.deinit(state.sections.allocator);

            try state.sections.append(.{
                .kind = .skipped_history,
                .label = try std.fmt.allocPrint(
                    state.sections.allocator,
                    "skipped {d} [{s}]",
                    .{ index + 1, deltaOpTagName(skipped.op) },
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
    provenance: Provenance,
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
    skipped: anytype,
    skip_index: u32,
) !DocumentModel {
    var builder = DocumentBuilder.init(allocator);
    errdefer builder.deinit();

    var cursor: usize = 0;
    const kind = switch (skipped.op) {
        .insert => AnnotationKind.insert,
        .delete => AnnotationKind.delete,
        .equal => null,
    };
    while (nextDisplayLine(skipped.text, cursor)) |part| {
        try builder.appendLine(part.line, .{
            .provenance = .skipped_history,
            .kind = kind,
            .skip_index = skip_index,
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

fn deltaOpTagName(op: dmp.DeltaOp) []const u8 {
    return switch (op) {
        .insert => "insert",
        .delete => "delete",
        .equal => "equal",
    };
}

const delta_actions = [_]Action{
    .apply,
    .skip,
    .split,
    .quit,
    .help,
};

const edit_actions = [_]Action{
    .apply,
    .skip,
    .apply_rest,
    .skip_rest,
    .quit,
    .help,
};

test "delta interaction state exposes prompt facts and multiple sections" {
    const allocator = std.testing.allocator;
    const before = "alpha\nbeta\ngamma\ndelta\n";
    const after = "alpha\nbeta\ngamma changed\ndelta\nepsilon\n";

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);

    const encoded = try zdelta.encode(allocator, diff.edits, .b);
    defer allocator.free(encoded);

    const owned_delta = try allocator.create(dmp.ZDelta);
    owned_delta.* = try dmp.decode(allocator, encoded);
    var tm = try DeltaManager.initText(allocator, before);
    defer tm.deinit();
    try tm.addDelta(owned_delta);
    _ = try tm.skipNext();

    var state = try InteractionState.buildDelta(
        allocator,
        &tm,
        after,
        .{
            .current_revision = 8,
            .target_revision = 9,
            .relative_path = "corpus/diff/sample.wiki",
        },
        .{},
    );
    defer state.deinit();

    try std.testing.expectEqual(.delta, state.prompt_kind);
    try std.testing.expect(state.sections.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), state.facts.skipped_history_len);
    try std.testing.expectEqual(@as(?u32, 1), state.facts.focused_delta_index);
}

test "edit interaction state exposes focused provenance" {
    const allocator = std.testing.allocator;
    const before = "alpha\nbeta\ngamma\ndelta\n";
    const after = "alpha\nbeta\ngamma changed\ndelta\nepsilon\n";

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);

    const encoded = try zdelta.encode(allocator, diff.edits, .b);
    defer allocator.free(encoded);

    const owned_delta = try allocator.create(dmp.ZDelta);
    owned_delta.* = try dmp.decode(allocator, encoded);
    var tm = try DeltaManager.initText(allocator, before);
    defer tm.deinit();
    try tm.addDelta(owned_delta);

    const preview = (try tm.previewNext()).?;
    var state = try InteractionState.buildEdit(
        allocator,
        &tm,
        after,
        .{
            .current_revision = 8,
            .target_revision = 9,
            .relative_path = "corpus/diff/sample.wiki",
        },
        preview,
        .{},
    );
    defer state.deinit();

    try std.testing.expectEqual(.edit, state.prompt_kind);
    try std.testing.expectEqual(preview.delta_index, state.focus.?.delta_index);
    try std.testing.expectEqual(preview.op.state, state.facts.focused_state.?);

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

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);

    const encoded = try zdelta.encode(allocator, diff.edits, .b);
    defer allocator.free(encoded);

    const owned_delta = try allocator.create(dmp.ZDelta);
    owned_delta.* = try dmp.decode(allocator, encoded);
    var tm = try DeltaManager.initText(allocator, before);
    defer tm.deinit();
    try tm.addDelta(owned_delta);

    var state = try InteractionState.buildDelta(
        allocator,
        &tm,
        after,
        .{
            .current_revision = 1,
            .target_revision = 2,
            .relative_path = "corpus/diff/sample.wiki",
        },
        .{},
    );
    defer state.deinit();

    var found_boundary = false;
    for (state.sections.items) |section| {
        if (section.kind != .overview) continue;
        found_boundary = section.document.boundaries.len != 0;
        try std.testing.expect(!std.mem.containsAtLeast(u8, section.document.text, 1, "..."));
    }
    try std.testing.expect(found_boundary);
}
