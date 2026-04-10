//! Trivial nonfunctional stand-in for the legacy review session.
//!
//! This keeps delta-tool buildable while the guidance-backed replacement is
//! not yet wired through the interactive stack.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SessionIntent = enum {
    apply,
    skip,
    split,
    quit,
    help,
    apply_rest,
    skip_rest,
};

pub const SessionPrompt = enum {
    delta,
    edit,
};

pub const SessionRevision = struct {
    ordinal: usize,
    relative_path: []const u8,
    body: []const u8,
};

pub const SessionStep = struct {
    ordinal: usize,
    relative_path: []const u8,
    target_body: []const u8,
    zdelta_text: []const u8,
};

pub const SessionSeed = struct {
    baseline: SessionRevision,
    steps: []const SessionStep,
};

pub const SessionSummary = struct {
    applied_deltas: usize = 0,
    skipped_deltas: usize = 0,
    partial_deltas: usize = 0,
    applied_edits: usize = 0,
    skipped_edits: usize = 0,
    processed_revision: usize = 0,
    quit_early: bool = false,
};

pub const SessionFacts = struct {
    current_bytes: usize,
    target_bytes: usize,
    skipped_history_len: usize,
};

pub const FocusKind = enum {
    insert,
    delete,
    equal,
};

pub const FocusEffect = union(FocusKind) {
    insert: []const u8,
    delete: usize,
    equal: usize,

    pub fn kind(effect: FocusEffect) FocusKind {
        return switch (effect) {
            .insert => .insert,
            .delete => .delete,
            .equal => .equal,
        };
    }
};

pub const OpState = enum {
    unchanged,
    rewritten,
    blocked,
};

pub const FocusChange = struct {
    change_number: usize,
    text_index: u32,
    effect: FocusEffect,
    state: OpState,
};

pub const SkippedKind = enum {
    insert,
    delete,
};

pub const SkippedChange = struct {
    number: usize,
    at: u32,
    kind: SkippedKind,
    text: []const u8,
};

pub const SessionSnapshot = struct {
    prompt_kind: SessionPrompt,
    allowed_intents: []const SessionIntent,
    current_revision: usize,
    target_revision: usize,
    relative_path: []const u8,
    current_text: []const u8,
    target_text: []const u8,
    facts: SessionFacts,
    focus: ?FocusChange,
    skipped: []SkippedChange,

    pub fn deinit(snapshot: *SessionSnapshot, allocator: Allocator) void {
        if (snapshot.skipped.len != 0) allocator.free(snapshot.skipped);
        snapshot.* = undefined;
    }
};

pub const AttachDiagnostic = struct {
    current_revision: usize,
    target_revision: usize,
    current_bytes: usize,
    skipped_history_len: usize,
    delta_before_len: u32,
    target_bytes: usize,
};

pub const DispatchStatus = enum {
    in_progress,
    quit_early,
    complete,
};

pub const OpenOutcome = struct {
    diagnostics: []AttachDiagnostic = &.{},
    status: DispatchStatus,

    pub fn deinit(outcome: *OpenOutcome, allocator: Allocator) void {
        if (outcome.diagnostics.len != 0) allocator.free(outcome.diagnostics);
        outcome.* = undefined;
    }
};

pub const DispatchOutcome = struct {
    accepted_intent: SessionIntent,
    help_prompt: ?SessionPrompt = null,
    diagnostics: []AttachDiagnostic = &.{},
    status: DispatchStatus,

    pub fn deinit(outcome: *DispatchOutcome, allocator: Allocator) void {
        if (outcome.diagnostics.len != 0) allocator.free(outcome.diagnostics);
        outcome.* = undefined;
    }
};

const Lifecycle = enum {
    loading,
    quit_early,
};

pub const ReviewSession = struct {
    allocator: Allocator,
    seed: SessionSeed,
    lifecycle: Lifecycle = .loading,
    summary_state: SessionSummary,

    pub fn init(allocator: Allocator, seed: SessionSeed) !ReviewSession {
        return .{
            .allocator = allocator,
            .seed = seed,
            .summary_state = .{
                .processed_revision = seed.baseline.ordinal,
            },
        };
    }

    pub fn deinit(session: *ReviewSession) void {
        session.* = undefined;
    }

    pub fn open(session: *ReviewSession) !OpenOutcome {
        _ = session;
        return error.MockSessionUnavailable;
    }

    pub fn dispatch(session: *ReviewSession, intent: SessionIntent) !DispatchOutcome {
        _ = .{ session, intent };
        return error.MockSessionUnavailable;
    }

    pub fn snapshot(session: *ReviewSession) !SessionSnapshot {
        _ = session;
        return error.MockSessionUnavailable;
    }

    pub fn quitEarly(session: *ReviewSession) void {
        session.lifecycle = .quit_early;
        session.summary_state.quit_early = true;
    }

    pub fn status(session: *const ReviewSession) DispatchStatus {
        return switch (session.lifecycle) {
            .loading => .in_progress,
            .quit_early => .quit_early,
        };
    }

    pub fn summary(session: *const ReviewSession) SessionSummary {
        return session.summary_state;
    }

    pub fn skippedHistoryLen(session: *const ReviewSession) usize {
        _ = session;
        return 0;
    }

    pub fn currentText(session: *const ReviewSession) []const u8 {
        return session.seed.baseline.body;
    }

    pub fn expectedFinalText(session: *const ReviewSession) []const u8 {
        return if (session.seed.steps.len == 0)
            session.seed.baseline.body
        else
            session.seed.steps[session.seed.steps.len - 1].target_body;
    }
};
