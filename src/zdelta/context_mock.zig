//! Trivial nonfunctional stand-in for interactive zdelta projection state.
//!
//! delta-tool only needs the types to compile while the legacy session stack
//! stays disconnected from normal test coverage.

const std = @import("std");
const session_mod = @import("session_mock.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub const ContextSettings = struct {
    whole_delta_context_lines: usize,
    edit_context_lines: usize,

    pub const default: ContextSettings = .{
        .whole_delta_context_lines = 2,
        .edit_context_lines = 2,
    };
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
    state: session_mod.OpState,
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
        for (state.sections.items) |*section| section.deinit(allocator);
        state.sections.deinit();
        state.session.deinit(allocator);
        state.* = undefined;
    }

    pub fn build(
        allocator: Allocator,
        snapshot: session_mod.SessionSnapshot,
        settings: ContextSettings,
    ) !InteractionState {
        _ = settings;
        return .{
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
    }
};
