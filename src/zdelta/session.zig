//! Transport-independent review session for partial zdelta application.
//!
//! This subsystem owns the semantics of a review run: which revision is under
//! examination, which canonical actions are legal, how summary counters evolve,
//! and when a run is considered complete or quit early. It intentionally does
//! not know how input arrived or how output will be rendered.

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

pub const FocusChange = struct {
    // This is the review-facing change number, not the raw delta index. The
    // shell may surface it to operators, so it stays stable even if the driver
    // has to change its internal bookkeeping later.
    change_number: usize,
    text_index: u32,
    effect: FocusEffect,
    state: dmp.HarmonizedOpState,
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

pub const ReviewSession = struct {
    allocator: Allocator,
    driver: ReviewDriver,
    seed: SessionSeed,
    next_step_index: usize = 0,
    current_step_index: ?usize = null,
    lifecycle: Lifecycle = .loading,
    summary_state: SessionSummary,

    pub fn init(allocator: Allocator, seed: SessionSeed) !ReviewSession {
        return .{
            .allocator = allocator,
            .driver = try ReviewDriver.init(allocator, seed.baseline.body),
            .seed = seed,
            .summary_state = .{
                .processed_revision = seed.baseline.ordinal,
            },
        };
    }

    pub fn deinit(session: *ReviewSession) void {
        session.driver.deinit();
        session.* = undefined;
    }

    pub fn open(session: *ReviewSession) !OpenOutcome {
        switch (session.lifecycle) {
            .loading => {},
            .delta_prompt, .edit_prompt => return .{ .status = .in_progress },
            .quit_early => return .{ .status = .quit_early },
            .complete => return .{ .status = .complete },
        }

        return .{
            .diagnostics = try session.advanceToPrompt(),
            .status = session.status(),
        };
    }

    pub fn dispatch(session: *ReviewSession, intent: SessionIntent) !DispatchOutcome {
        const diagnostics = switch (session.lifecycle) {
            .delta_prompt => try session.dispatchDelta(intent),
            .edit_prompt => try session.dispatchEdit(intent),
            .loading, .quit_early, .complete => return error.InvalidSessionState,
        };

        return .{
            .accepted_intent = intent,
            .help_prompt = switch (intent) {
                .help => switch (session.lifecycle) {
                    .delta_prompt => .delta,
                    .edit_prompt => .edit,
                    .loading, .quit_early, .complete => null,
                },
                else => null,
            },
            .diagnostics = diagnostics,
            .status = session.status(),
        };
    }

    pub fn snapshot(session: *ReviewSession) !SessionSnapshot {
        const prompt_kind = switch (session.lifecycle) {
            .delta_prompt => SessionPrompt.delta,
            .edit_prompt => SessionPrompt.edit,
            .loading, .quit_early, .complete => return error.InvalidSessionState,
        };
        const step = session.currentStep();
        const focus = try session.driver.peekChange();
        const active_skipped = session.driver.activeSkippedItems();
        var skipped: []SkippedChange = &.{};
        if (active_skipped.len != 0) {
            skipped = try session.allocator.alloc(SkippedChange, active_skipped.len);
            for (active_skipped, 0..) |item, idx| {
                skipped[idx] = .{
                    .number = idx + 1,
                    .at = item.at,
                    .kind = switch (item.op) {
                        .insert => .insert,
                        .delete => .delete,
                    },
                    .text = item.text,
                };
            }
        }

        return .{
            .prompt_kind = prompt_kind,
            .allowed_intents = switch (prompt_kind) {
                .delta => &delta_intents,
                .edit => &edit_intents,
            },
            .current_revision = session.summary_state.processed_revision,
            .target_revision = step.ordinal,
            .relative_path = step.relative_path,
            .current_text = session.driver.view(),
            .target_text = step.target_body,
            .facts = .{
                .current_bytes = session.driver.view().len,
                .target_bytes = step.target_body.len,
                .skipped_history_len = session.driver.skippedItems().len,
            },
            .focus = focus,
            .skipped = skipped,
        };
    }

    pub fn quitEarly(session: *ReviewSession) void {
        session.summary_state.quit_early = true;
        session.lifecycle = .quit_early;
    }

    pub fn status(session: *const ReviewSession) DispatchStatus {
        return switch (session.lifecycle) {
            .loading, .delta_prompt, .edit_prompt => .in_progress,
            .quit_early => .quit_early,
            .complete => .complete,
        };
    }

    pub fn summary(session: *const ReviewSession) SessionSummary {
        return session.summary_state;
    }

    pub fn skippedHistoryLen(session: *const ReviewSession) usize {
        return session.driver.skippedItems().len;
    }

    pub fn currentText(session: *const ReviewSession) []const u8 {
        return session.driver.view();
    }

    pub fn expectedFinalText(session: *const ReviewSession) []const u8 {
        return if (session.seed.steps.len == 0)
            session.seed.baseline.body
        else
            session.seed.steps[session.seed.steps.len - 1].target_body;
    }

    fn dispatchDelta(session: *ReviewSession, intent: SessionIntent) ![]AttachDiagnostic {
        switch (intent) {
            .apply => {
                session.summary_state.applied_edits += try session.driver.applyRest();
                session.summary_state.applied_deltas += 1;
                return session.finishCurrentStep();
            },
            .skip => {
                session.summary_state.skipped_edits += try session.driver.skipRest();
                session.summary_state.skipped_deltas += 1;
                return session.finishCurrentStep();
            },
            .split => {
                session.summary_state.partial_deltas += 1;
                if (try session.driver.peekChange()) |_| {
                    session.lifecycle = .edit_prompt;
                    return &.{};
                }
                return session.finishCurrentStep();
            },
            .quit => {
                session.quitEarly();
                return &.{};
            },
            .help => return &.{},
            .apply_rest, .skip_rest => return error.InvalidIntentForPrompt,
        }
    }

    fn dispatchEdit(session: *ReviewSession, intent: SessionIntent) ![]AttachDiagnostic {
        switch (intent) {
            .apply => {
                if (!try session.driver.applyNext()) return error.InvalidSessionState;
                session.summary_state.applied_edits += 1;
                if (try session.driver.peekChange()) |_| return &.{};
                return session.finishCurrentStep();
            },
            .skip => {
                if (!try session.driver.skipNext()) return error.InvalidSessionState;
                session.summary_state.skipped_edits += 1;
                if (try session.driver.peekChange()) |_| return &.{};
                return session.finishCurrentStep();
            },
            .apply_rest => {
                session.summary_state.applied_edits += try session.driver.applyRest();
                return session.finishCurrentStep();
            },
            .skip_rest => {
                session.summary_state.skipped_edits += try session.driver.skipRest();
                return session.finishCurrentStep();
            },
            .quit => {
                session.quitEarly();
                return &.{};
            },
            .help => return &.{},
            .split => return error.InvalidIntentForPrompt,
        }
    }

    fn finishCurrentStep(session: *ReviewSession) ![]AttachDiagnostic {
        const step = session.currentStep();
        session.summary_state.processed_revision = step.ordinal;
        session.current_step_index = null;
        return session.advanceToPrompt();
    }

    fn advanceToPrompt(session: *ReviewSession) ![]AttachDiagnostic {
        var diagnostics = ArrayList(AttachDiagnostic).init(session.allocator);
        errdefer diagnostics.deinit();

        while (session.next_step_index < session.seed.steps.len) {
            const step = session.seed.steps[session.next_step_index];
            const before_len = session.driver.attachDelta(step.zdelta_text) catch |err| switch (err) {
                error.ZDeltaTextLengthMismatch => {
                    try diagnostics.append(.{
                        .current_revision = session.summary_state.processed_revision,
                        .target_revision = step.ordinal,
                        .current_bytes = session.driver.view().len,
                        .skipped_history_len = session.driver.skippedItems().len,
                        .delta_before_len = session.driver.last_before_len.?,
                        .target_bytes = step.target_body.len,
                    });
                    session.next_step_index += 1;
                    continue;
                },
                else => return err,
            };
            _ = before_len;
            session.current_step_index = session.next_step_index;
            session.next_step_index += 1;
            session.lifecycle = .delta_prompt;
            return diagnostics.toOwnedSlice();
        }

        session.lifecycle = .complete;
        return diagnostics.toOwnedSlice();
    }

    fn currentStep(session: *const ReviewSession) SessionStep {
        return session.seed.steps[session.current_step_index.?];
    }
};

// The driver exists so the reducer can talk in review verbs instead of in the
// field layout of `DeltaManager`. Today it forwards to the current partial
// applicator; later it is the seam that lets the underlying machinery move.
const ReviewDriver = struct {
    tm: DeltaManager,
    last_before_len: ?u32 = null,

    fn init(allocator: Allocator, baseline_text: []const u8) !ReviewDriver {
        return .{
            .tm = try DeltaManager.initText(allocator, baseline_text),
        };
    }

    fn deinit(driver: *ReviewDriver) void {
        driver.tm.deinit();
        driver.* = undefined;
    }

    fn attachDelta(driver: *ReviewDriver, zdelta_text: []const u8) !u32 {
        const owned_delta = try driver.tm.allocator.create(dmp.ZDelta);
        owned_delta.* = dmp.decode(driver.tm.allocator, zdelta_text) catch |err| {
            driver.tm.allocator.destroy(owned_delta);
            return err;
        };
        const raw_before_len = owned_delta.beforeLength();
        driver.last_before_len = raw_before_len;
        try driver.tm.addDelta(owned_delta);
        return raw_before_len;
    }

    fn view(driver: *const ReviewDriver) []const u8 {
        return driver.tm.view();
    }

    fn skippedItems(driver: *const ReviewDriver) []const zdelta_mod.SkippedDeltaOp {
        return driver.tm.skippedItems();
    }

    fn activeSkippedItems(driver: *const ReviewDriver) []const zdelta_mod.SkippedDeltaOp {
        const skipped = driver.tm.skippedItems();
        var start: usize = skipped.len;
        while (start > 0) {
            const item = skipped[start - 1];
            if (item.accounted_for_current_delta) break;
            start -= 1;
        }
        return skipped[start..];
    }

    fn peekChange(driver: *const ReviewDriver) !?FocusChange {
        const preview = (try driver.tm.previewNext()) orelse return null;
        return .{
            .change_number = preview.delta_index + 1,
            .text_index = preview.text_index,
            .effect = switch (preview.op.current) {
                .insert => |insert| .{ .insert = driver.tm.effective.?.text(insert.text) },
                .delete => |span| .{ .delete = span.len() },
                .equal => |span| .{ .equal = span.len() },
            },
            .state = preview.op.state,
        };
    }

    fn applyNext(driver: *ReviewDriver) !bool {
        return (try driver.tm.applyNext()) != null;
    }

    fn skipNext(driver: *ReviewDriver) !bool {
        return (try driver.tm.skipNext()) != null;
    }

    fn applyRest(driver: *ReviewDriver) !usize {
        var count: usize = 0;
        while (try driver.tm.applyNext()) |_| count += 1;
        return count;
    }

    fn skipRest(driver: *ReviewDriver) !usize {
        var count: usize = 0;
        while (try driver.tm.skipNext()) |_| count += 1;
        return count;
    }
};

const Lifecycle = enum {
    loading,
    delta_prompt,
    edit_prompt,
    quit_early,
    complete,
};

const delta_intents = [_]SessionIntent{
    .apply,
    .skip,
    .split,
    .quit,
    .help,
};

const edit_intents = [_]SessionIntent{
    .apply,
    .skip,
    .apply_rest,
    .skip_rest,
    .quit,
    .help,
};

//| Tests

const testing = std.testing;

test "review session applies a whole delta" {
    const allocator = testing.allocator;
    const delta = try encodeDelta(allocator, "alpha\n", "alpha\nbeta\n");
    defer allocator.free(delta);

    var session = try ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 1,
            .relative_path = "corpus/diff/sample_1.wiki",
            .body = "alpha\n",
        },
        .steps = &.{
            .{
                .ordinal = 2,
                .relative_path = "corpus/diff/sample_2.wiki",
                .target_body = "alpha\nbeta\n",
                .zdelta_text = delta,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);
    try testing.expectEqual(DispatchStatus.in_progress, opened.status);

    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);
    try testing.expectEqual(SessionPrompt.delta, snapshot.prompt_kind);

    var outcome = try session.dispatch(.apply);
    defer outcome.deinit(allocator);
    try testing.expectEqual(DispatchStatus.complete, outcome.status);

    const summary = session.summary();
    try testing.expectEqual(@as(usize, 1), summary.applied_deltas);
    try testing.expectEqual(@as(usize, 1), summary.applied_edits);
    try testing.expectEqualStrings("alpha\nbeta\n", session.currentText());
    try testing.expectEqualStrings("alpha\nbeta\n", session.expectedFinalText());
}

test "review session split path advances one change at a time" {
    const allocator = testing.allocator;
    const before = "alpha\nbeta\ngamma\n";
    const after = "alpha\nbeta changed\ngamma\ndelta\n";
    const delta = try encodeDelta(allocator, before, after);
    defer allocator.free(delta);

    var session = try ReviewSession.init(allocator, .{
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
                .zdelta_text = delta,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);

    var split = try session.dispatch(.split);
    defer split.deinit(allocator);
    try testing.expectEqual(DispatchStatus.in_progress, split.status);

    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);
    try testing.expectEqual(SessionPrompt.edit, snapshot.prompt_kind);
    try testing.expect(snapshot.focus != null);

    var apply = try session.dispatch(.apply);
    defer apply.deinit(allocator);
    try testing.expectEqual(DispatchStatus.in_progress, apply.status);

    var rest = try session.dispatch(.apply_rest);
    defer rest.deinit(allocator);
    try testing.expectEqual(DispatchStatus.complete, rest.status);

    const summary = session.summary();
    try testing.expectEqual(@as(usize, 1), summary.partial_deltas);
    try testing.expect(summary.applied_edits >= 2);
}

test "review session reports help without mutating state" {
    const allocator = testing.allocator;
    const delta = try encodeDelta(allocator, "one\n", "one\ntwo\n");
    defer allocator.free(delta);

    var session = try ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 1,
            .relative_path = "corpus/diff/sample_1.wiki",
            .body = "one\n",
        },
        .steps = &.{
            .{
                .ordinal = 2,
                .relative_path = "corpus/diff/sample_2.wiki",
                .target_body = "one\ntwo\n",
                .zdelta_text = delta,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);

    var delta_help = try session.dispatch(.help);
    defer delta_help.deinit(allocator);
    try testing.expectEqual(@as(?SessionPrompt, .delta), delta_help.help_prompt);

    var split = try session.dispatch(.split);
    defer split.deinit(allocator);

    var edit_help = try session.dispatch(.help);
    defer edit_help.deinit(allocator);
    try testing.expectEqual(@as(?SessionPrompt, .edit), edit_help.help_prompt);
}

test "review session quit marks quit early without processing later revisions" {
    const allocator = testing.allocator;
    const delta = try encodeDelta(allocator, "base\n", "base\nnext\n");
    defer allocator.free(delta);

    var session = try ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 3,
            .relative_path = "corpus/diff/sample_3.wiki",
            .body = "base\n",
        },
        .steps = &.{
            .{
                .ordinal = 4,
                .relative_path = "corpus/diff/sample_4.wiki",
                .target_body = "base\nnext\n",
                .zdelta_text = delta,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);

    var outcome = try session.dispatch(.quit);
    defer outcome.deinit(allocator);
    try testing.expectEqual(DispatchStatus.quit_early, outcome.status);
    try testing.expect(session.summary().quit_early);
    try testing.expectEqual(@as(usize, 3), session.summary().processed_revision);
}

test "review session advances across multiple revisions" {
    const allocator = testing.allocator;
    const delta_1 = try encodeDelta(allocator, "one\n", "one\ntwo\n");
    defer allocator.free(delta_1);
    const delta_2 = try encodeDelta(allocator, "one\ntwo\n", "one\ntwo\nthree\n");
    defer allocator.free(delta_2);

    var session = try ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 1,
            .relative_path = "corpus/diff/sample_1.wiki",
            .body = "one\n",
        },
        .steps = &.{
            .{
                .ordinal = 2,
                .relative_path = "corpus/diff/sample_2.wiki",
                .target_body = "one\ntwo\n",
                .zdelta_text = delta_1,
            },
            .{
                .ordinal = 3,
                .relative_path = "corpus/diff/sample_3.wiki",
                .target_body = "one\ntwo\nthree\n",
                .zdelta_text = delta_2,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);

    var first = try session.dispatch(.apply);
    defer first.deinit(allocator);
    try testing.expectEqual(DispatchStatus.in_progress, first.status);

    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), snapshot.current_revision);
    try testing.expectEqual(@as(usize, 3), snapshot.target_revision);

    var second = try session.dispatch(.apply);
    defer second.deinit(allocator);
    try testing.expectEqual(DispatchStatus.complete, second.status);
    try testing.expectEqual(@as(usize, 3), session.summary().processed_revision);
}

test "review session emits attach diagnostics and continues to a later revision" {
    const allocator = testing.allocator;
    const bad_delta = try encodeDelta(allocator, "wrong\n", "still wrong\n");
    defer allocator.free(bad_delta);
    const good_delta = try encodeDelta(allocator, "base\n", "base\nnext\n");
    defer allocator.free(good_delta);

    var session = try ReviewSession.init(allocator, .{
        .baseline = .{
            .ordinal = 1,
            .relative_path = "corpus/diff/sample_1.wiki",
            .body = "base\n",
        },
        .steps = &.{
            .{
                .ordinal = 2,
                .relative_path = "corpus/diff/sample_2.wiki",
                .target_body = "still wrong\n",
                .zdelta_text = bad_delta,
            },
            .{
                .ordinal = 3,
                .relative_path = "corpus/diff/sample_3.wiki",
                .target_body = "base\nnext\n",
                .zdelta_text = good_delta,
            },
        },
    });
    defer session.deinit();

    var opened = try session.open();
    defer opened.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), opened.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), opened.diagnostics[0].current_revision);
    try testing.expectEqual(@as(usize, 2), opened.diagnostics[0].target_revision);

    var snapshot = try session.snapshot();
    defer snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), snapshot.target_revision);
}

fn encodeDelta(allocator: Allocator, before: []const u8, after: []const u8) ![]const u8 {
    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);
    return try diff.toZDelta(allocator, .b);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const dmp = @import("../dmp.zig");
const DeltaManager = dmp.DeltaManager;
const zdelta_mod = @import("../zdelta.zig");
