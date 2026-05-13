//! Delta guidance system.
//!
//! This module is the first implementation of the new correction-surface model
//! described in `design/change-manager.md`.
//!
//! The direct control surface deliberately looks a lot like `whole_apply.zig`:
//! attach a raw `ZDelta`, preview the next actionable edit, decide what to do,
//! and keep the active text in a single slack buffer.  The difference is that
//! guidance preserves an immutable chain of review decisions and a correction
//! surface describing how the current expected text maps into effective text.
//!
//! A few implementation choices in this first pass are intentionally plain:
//!
//! - The text buffer logic is copied from `whole_apply` in spirit and reused
//!   from `apply_base` directly.
//! - The correction surface is authoritative as a tree. Some update paths still
//!   flatten it into a temporary in-order region list before rebuilding the next
//!   version, but persistent step state lives in `CorrectionNode`s.
//! - The code is heavily commented on purpose.  This file is the puzzle board
//!   for the new model, and comments carry part of the design load.

/// A contiguous amount of text measured on a single axis.
pub const Span = struct {
    start: u32,
    end: u32,

    /// Returns the width of the span on its owning axis.
    pub fn len(span: Span) u32 {
        return span.end - span.start;
    }
};

/// Classifies how a raw edit interacts with the current correction surface.
pub const TargetClass = enum {
    pure,
    overlaid,
    clipped,
    composite,
    stranded,
    complex,
};

/// Describes the raw delta's requested target on the expected axis.
pub const ExpectedTarget = union(enum) {
    insert_at: u32,
    delete: Span,
};

/// Describes the in-flight target after mapping onto effective space.
///
/// `TargetClass` carries the semantic classification, while `EffectiveTarget`
/// carries the usable effective-axis geometry when one exists.
pub const EffectiveTarget = union(enum) {
    insert_at: u32,
    delete: Span,
    complex,
};

/// Names the currently supported apply choices for ambiguous deletes.
pub const ApplyResolution = enum {
    delete_whole,
    delete_corpus_only,
};

/// Stable append-only id for a decision record.
pub const DecisionIndex = enum(u32) { _ };
/// Stable append-only id for an anomaly record.
pub const AnomalyIndex = enum(u32) { _ };

/// References a contiguous slice inside a provenance or residue side table.
pub const ProvenanceRef = struct {
    off: u32,
    len: u32,
};

/// Names the concrete decision variants recorded in history.
pub const DecisionKind = enum {
    insert,
    delete,
    decline,
    rescue,
};

/// Records one reviewed action taken against an attached raw delta op.
pub const DecisionRecord = union(enum) {
    insert: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        /// Raw-op ordinal within the attached delta.
        raw_op_index: u32,
        /// Expected-axis insertion point requested by the raw op.
        expected_at: u32,
        /// Effective-axis insertion point before the decision is applied.
        effective_at_before: u32,
        /// Effective-axis insertion point immediately after the decision is applied.
        effective_at_after: u32,
        /// Offset into shared residue for redo bytes.
        residue_off: u32,
        /// Byte length of the redo payload stored in shared residue.
        residue_len: u32,
    },
    delete: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        /// Raw-op ordinal within the attached delta.
        raw_op_index: u32,
        /// Expected-axis span requested by the raw delete.
        expected: Span,
        /// Effective span removed by this decision before mutation.
        effective_before: Span,
        /// Effective cursor state immediately after the delete is applied.
        effective_after: Span,
        /// Offset into shared residue for deleted bytes kept for undo.
        residue_off: u32,
        /// Byte length of the deleted payload stored in shared residue.
        residue_len: u32,
        /// Apply choice used when the delete crossed imposed text.
        resolution: ?ApplyResolution,
    },
    decline: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        /// Raw-op ordinal within the attached delta.
        raw_op_index: u32,
        /// Expected-axis insertion point of the declined raw insert.
        expected_at: u32,
        /// Evacuation anomaly created by declining the insert.
        anomaly: AnomalyIndex,
    },
    rescue: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        /// Raw-op ordinal within the attached delta.
        raw_op_index: u32,
        /// Expected-axis span of the rescued raw delete.
        expected: Span,
        /// Imposition anomaly created by rescuing the delete.
        anomaly: AnomalyIndex,
        /// Apply choice used if the rescue came from an ambiguous delete.
        resolution: ?ApplyResolution,
    },

    /// Returns the tag of this decision record as a named enum.
    pub fn kind(record: DecisionRecord) DecisionKind {
        return switch (record) {
            .insert => .insert,
            .delete => .delete,
            .decline => .decline,
            .rescue => .rescue,
        };
    }
};

/// Records a persisted anomaly left behind by a declined or rescued edit.
pub const AnomalyRecord = union(enum) {
    evacuation: struct {
        id: AnomalyIndex,
        created_by: DecisionIndex,
        expected: Span,
        residue_off: u32,
        residue_len: u32,
    },
    imposition: struct {
        id: AnomalyIndex,
        created_by: DecisionIndex,
        expected_at: u32,
        ef_wid: u32,
    },
};

pub const Error = OOM || error{
    BadZDeltaNumber,
    GuidanceTextTooLarge,
    MissingZDelta,
    StepAlreadyOpen,
    UnfinishedZDelta,
    UnresolvedZDeltaOp,
    ZDeltaTextLengthMismatch,
};

/// Preview result for the next actionable raw op in an attached step.
pub const EffectiveEdit = struct {
    raw_op_index: u32,
    expected_target: ExpectedTarget,
    effective_target: EffectiveTarget,
    class: TargetClass,
    touched_anomalies: ProvenanceRef,
    available_resolutions: []const ApplyResolution,
};

/// Terminal qualitative region of the correction surface.
///
/// Region coordinates are local to the subtree root that owns them. Traversal
/// code derives absolute expected/effective positions from the running expected
/// base plus authoritative deviation; the stored coordinates act as local
/// shape descriptors and debug-time checks.
pub const CorrectionRegion = union(enum) {
    pristine: struct {
        expected: Span,
        effective: Span,
        wid: u32,
        decisions: ProvenanceRef,
    },
    evacuation: struct {
        expected: Span,
        effective_at: u32,
        ex_wid: u32,
        decisions: ProvenanceRef,
        anomalies: ?ProvenanceRef,
    },
    imposition: struct {
        expected_at: u32,
        effective: Span,
        ef_wid: u32,
        decisions: ProvenanceRef,
        anomalies: ?ProvenanceRef,
    },

    /// Returns the region's width on the expected axis.
    fn exWid(region: CorrectionRegion) u32 {
        return switch (region) {
            .pristine => |r| r.wid,
            .evacuation => |r| r.ex_wid,
            .imposition => 0,
        };
    }

    /// Returns the region's width on the effective axis.
    fn efWid(region: CorrectionRegion) u32 {
        return switch (region) {
            .pristine => |r| r.wid,
            .evacuation => 0,
            .imposition => |r| r.ef_wid,
        };
    }

    /// Returns the decision provenance attached to the region.
    fn decisionRef(region: CorrectionRegion) ProvenanceRef {
        return switch (region) {
            .pristine => |r| r.decisions,
            .evacuation => |r| r.decisions,
            .imposition => |r| r.decisions,
        };
    }

    /// Returns anomaly provenance when the region is anomalous.
    fn anomalyRef(region: CorrectionRegion) ?ProvenanceRef {
        return switch (region) {
            .pristine => null,
            .evacuation => |r| r.anomalies,
            .imposition => |r| r.anomalies,
        };
    }

    /// Reports whether the region carries anomaly provenance.
    fn isAnomalous(region: CorrectionRegion) bool {
        return region.anomalyRef() != null;
    }
};

/// Interval-tree node covering a contiguous portion of the correction surface.
pub const CorrectionNode = union(enum) {
    span: struct {
        ex_wid: u32,
        ef_wid: u32,
        deviation: i32,
        /// Effective-axis width of the left subtree, used as the descent pivot.
        pivot: u32,
        left: *CorrectionNode,
        right: *CorrectionNode,
    },
    region: CorrectionRegion,
};

/// Metadata for the raw delta currently attached as an open review step.
pub const AttachedStepState = struct {
    raw_delta: *ZDelta,
    target_revision: usize,
    raw_index_next: u32,
    expected_cursor_next: u32,
};

/// Immutable history node describing one decided correction state.
pub const Step = struct {
    prior: ?*Step,
    next: ?*Step,
    correction_root: *CorrectionNode,

    ef_len: u32,
    ex_len: u32,

    // DecisionIndex(0) is the synthetic genesis insert of the initial text.
    decision: DecisionIndex,
    anomaly: ?AnomalyIndex,
    anomaly_count: u32,
    decision_count: u32,

    // These snapshot the live attachment cursor so undo/redo during an open
    // step can restore preview exactly.
    raw_index_next: u32,
    expected_cursor_next: u32,
};

/// Result of splitting one correction subtree at an expected-axis boundary.
const TreeSplit = struct {
    left: ?*CorrectionNode,
    right: ?*CorrectionNode,
};

/// Review-capable delta engine owning text, history, anomalies, and provenance.
pub const DeltaGuidanceSystem = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    buffer: []u8,
    start: u32,
    end: u32,
    pivot: u32,
    budget: u32,

    current_step: *Step,
    attached_step: ?AttachedStepState,

    decisions: std.ArrayListUnmanaged(DecisionRecord),
    anomalies: std.ArrayListUnmanaged(AnomalyRecord),
    residue: std.ArrayListUnmanaged(u8),

    // Provenance tables are append-only.  Regions store offsets into these
    // tables instead of baking slices or pointers into each step.
    decision_provenance: std.ArrayListUnmanaged(DecisionIndex),
    anomaly_provenance: std.ArrayListUnmanaged(AnomalyIndex),

    // Preview uses a scratch anomaly list so querying does not mutate the
    // durable provenance tables.
    preview_anomalies: std.ArrayListUnmanaged(AnomalyIndex),

    /// If our precalculated buffer is insufficient, we allocate just a bit
    /// more, for luck.
    const growth_fudge: comptime_int = 16;

    /// Allocates a guidance system on the heap and seeds it from initial text.
    pub fn createWithText(allocator: Allocator, text: []const u8) Error!*DeltaGuidanceSystem {
        const gs = try allocator.create(DeltaGuidanceSystem);
        errdefer allocator.destroy(gs);
        gs.* = try initText(allocator, text);
        return gs;
    }

    /// Deinitializes a heap-allocated guidance system and destroys its allocation.
    pub fn destroy(gs: *DeltaGuidanceSystem) void {
        const allocator = gs.allocator;
        gs.deinit();
        allocator.destroy(gs);
    }

    /// Creates a guidance system from initial text and seeds the synthetic genesis step.
    pub fn initText(allocator: Allocator, text: []const u8) Error!DeltaGuidanceSystem {
        const text_len = try checkedGuidanceTextLen(text.len);
        const extra_slack = try initialGuidanceSlack(text.len);
        const head_room = extra_slack / 2;
        const total_len = try totalGuidanceBufferLen(text.len, extra_slack);
        var buffer = try allocator.alloc(u8, total_len);
        errdefer allocator.free(buffer);
        @memcpy(buffer[head_room..][0..text.len], text);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var gs = DeltaGuidanceSystem{
            .allocator = allocator,
            .arena = arena,
            .buffer = buffer,
            .start = try checkedU32(head_room),
            .end = try addU32(try checkedU32(head_room), text_len),
            .pivot = text_len / 2,
            .budget = try checkedU32(extra_slack),
            .current_step = undefined,
            .attached_step = null,
            .decisions = .empty,
            .anomalies = .empty,
            .residue = .empty,
            .decision_provenance = .empty,
            .anomaly_provenance = .empty,
            .preview_anomalies = .empty,
        };
        errdefer {
            gs.preview_anomalies.deinit(gs.allocator);
            gs.decision_provenance.deinit(gs.allocator);
            gs.anomaly_provenance.deinit(gs.allocator);
            gs.residue.deinit(gs.allocator);
            gs.anomalies.deinit(gs.allocator);
            gs.decisions.deinit(gs.allocator);
            gs.arena.deinit();
        }

        const genesis_decision = try gs.appendDecision(.{ .insert = .{
            .id = decisionIndex(0),
            .revision_ordinal = 0,
            .raw_op_index = 0,
            .expected_at = 0,
            .effective_at_before = 0,
            .effective_at_after = 0,
            .residue_off = 0,
            .residue_len = 0,
        } });
        dbgassert(decisionToInt(genesis_decision) == 0);

        const decision_ref = try gs.appendDecisionProvenance(&.{genesis_decision});
        const root = try gs.createPristineNode(text_len, decision_ref);

        const step = try gs.arena.allocator().create(Step);
        step.* = .{
            .prior = null,
            .next = null,
            .correction_root = root,
            .ef_len = text_len,
            .ex_len = text_len,
            .decision = genesis_decision,
            .anomaly = null,
            .anomaly_count = 0,
            .decision_count = 1,
            .raw_index_next = 0,
            .expected_cursor_next = 0,
        };
        gs.current_step = step;
        return gs;
    }

    /// Releases the active attachment, history, provenance tables, and text buffer.
    pub fn deinit(gs: *DeltaGuidanceSystem) void {
        if (gs.attached_step) |attached| attached.raw_delta.destroy(gs.allocator);
        gs.preview_anomalies.deinit(gs.allocator);
        gs.decision_provenance.deinit(gs.allocator);
        gs.anomaly_provenance.deinit(gs.allocator);
        gs.residue.deinit(gs.allocator);
        gs.anomalies.deinit(gs.allocator);
        gs.decisions.deinit(gs.allocator);
        gs.arena.deinit();
        if (gs.buffer.len != 0) gs.allocator.free(gs.buffer);
        gs.* = undefined;
    }

    /// Returns the current effective text slice from the slack buffer.
    pub fn currentText(gs: *const DeltaGuidanceSystem) []const u8 {
        return gs.buffer[gs.start..gs.end];
    }

    /// Attaches a raw delta as the next review step against the current expected text.
    pub fn openStep(gs: *DeltaGuidanceSystem, raw_delta: *ZDelta, target_revision: usize) Error!void {
        errdefer raw_delta.destroy(gs.allocator);
        if (gs.attached_step != null) return error.StepAlreadyOpen;

        const before_len, const head_room, const tail_room = raw_delta.textNumbers();
        if (gs.current_step.ex_len != before_len) return error.ZDeltaTextLengthMismatch;
        const total_change = raw_delta.totalChange();
        if (total_change > 0) {
            const growth_need: u32 = @intCast(total_change);
            try gs.growForNeed(growth_need);
        }
        try gs.ensureHeadRoom(head_room);
        try gs.ensureTailRoom(tail_room);

        gs.pivot = gs.current_step.ef_len / 2;
        gs.current_step.raw_index_next = 0;
        gs.current_step.expected_cursor_next = 0;
        gs.attached_step = .{
            .raw_delta = raw_delta,
            .target_revision = target_revision,
            .raw_index_next = 0,
            .expected_cursor_next = 0,
        };
    }

    /// Returns the next actionable edit, skipping raw equal operations on the way.
    pub fn previewNext(gs: *DeltaGuidanceSystem) Error!?EffectiveEdit {
        const scanned = try gs.scanNextEdit() orelse return null;
        return scanned.edit;
    }

    /// Accepts the next actionable edit and advances the open step by one decision.
    pub fn applyNext(gs: *DeltaGuidanceSystem, resolution: ?ApplyResolution) Error!bool {
        const scanned = try gs.scanNextEdit() orelse return false;
        if (scanned.edit.class == .complex) return error.UnresolvedZDeltaOp;

        const chosen = try gs.resolveApply(&scanned.edit, resolution);
        switch (scanned.op) {
            .insert => |span| {
                if (scanned.edit.class != .pure) return error.UnresolvedZDeltaOp;
                try gs.applyInsert(scanned, span, chosen);
            },
            .delete => |len| try gs.applyDelete(scanned, len, chosen),
            .equal => unreachable,
        }
        return true;
    }

    /// Declines or rescues the next actionable edit and advances the open step.
    pub fn skipNext(gs: *DeltaGuidanceSystem) Error!bool {
        const scanned = try gs.scanNextEdit() orelse return false;
        if (scanned.edit.class == .complex) return error.UnresolvedZDeltaOp;

        switch (scanned.op) {
            .insert => |span| {
                if (scanned.edit.class != .pure) return error.UnresolvedZDeltaOp;
                try gs.skipInsert(scanned, span);
            },
            .delete => |len| try gs.skipDelete(scanned, len),
            .equal => unreachable,
        }
        return true;
    }

    /// Applies every remaining actionable edit in the attached delta.
    pub fn applyRest(gs: *DeltaGuidanceSystem, default_resolution: ?ApplyResolution) Error!usize {
        var count: usize = 0;
        while (try gs.applyNext(default_resolution)) count += 1;
        return count;
    }

    /// Skips every remaining actionable edit in the attached delta.
    pub fn skipRest(gs: *DeltaGuidanceSystem) Error!usize {
        var count: usize = 0;
        while (try gs.skipNext()) count += 1;
        return count;
    }

    /// Promotes the completed correction surface onto the next revision's expected axis.
    pub fn finishStep(gs: *DeltaGuidanceSystem) Error!void {
        const attached = gs.attached_step orelse return error.MissingZDelta;
        if (try gs.scanNextEdit()) |_| return error.UnfinishedZDelta;

        // Finish is not a reviewed decision, so the current step is mutated in
        // place.  The undo/redo path remains decision-based; finish only changes
        // which axis that last decided correction surface is keyed against.
        const new_root = (try gs.promoteSubtree(gs.current_step.correction_root)) orelse blk: {
            const empty_decisions = try gs.appendDecisionProvenance(&.{});
            break :blk try gs.createPristineNode(0, empty_decisions);
        };
        gs.current_step.correction_root = new_root;
        gs.current_step.ex_len = treeExWid(new_root);
        gs.current_step.ef_len = treeEfWid(new_root);
        gs.current_step.raw_index_next = 0;
        gs.current_step.expected_cursor_next = 0;

        attached.raw_delta.destroy(gs.allocator);
        gs.attached_step = null;
        gs.pivot = gs.current_step.ef_len / 2;
    }

    /// Moves back one decided step and restores buffer contents plus preview cursor state.
    pub fn undo(gs: *DeltaGuidanceSystem) Error!bool {
        const current = gs.current_step;
        const prior = current.prior orelse return false;

        try gs.undoDecision(current.decision);
        gs.current_step = prior;
        if (gs.attached_step) |*attached| {
            attached.raw_index_next = prior.raw_index_next;
            attached.expected_cursor_next = prior.expected_cursor_next;
        }
        return true;
    }

    /// Replays the next step on the active history path and restores preview cursor state.
    pub fn redo(gs: *DeltaGuidanceSystem) Error!bool {
        const next = gs.current_step.next orelse return false;
        try gs.redoDecision(next.decision);
        gs.current_step = next;
        if (gs.attached_step) |*attached| {
            attached.raw_index_next = next.raw_index_next;
            attached.expected_cursor_next = next.expected_cursor_next;
        }
        return true;
    }

    /// Recenters the slack buffer around a new start offset.
    fn rebase(gs: *DeltaGuidanceSystem, new_start: u32) void {
        apply_base.rebase(gs, new_start);
    }

    /// Enlarges the buffer when upcoming edits exceed the current slack budget.
    fn growForNeed(gs: *DeltaGuidanceSystem, need: u32) Error!void {
        try apply_base.growForNeed(gs, growth_fudge, need);
    }

    /// Ensures there is enough slack before the text for a front-biased edit.
    fn ensureHeadRoom(gs: *DeltaGuidanceSystem, need: u32) Error!void {
        try apply_base.ensureHeadRoom(gs, growth_fudge, need);
    }

    /// Ensures there is enough slack after the text for a tail-biased edit.
    fn ensureTailRoom(gs: *DeltaGuidanceSystem, need: u32) Error!void {
        try apply_base.ensureTailRoom(gs, growth_fudge, need);
    }

    /// Inserts bytes into the effective buffer at the requested effective offset.
    fn insert(gs: *DeltaGuidanceSystem, at: u32, new_text: []const u8) Error!void {
        dbgassert(new_text.len <= std.math.maxInt(u32));
        const new_len: u32 = @intCast(new_text.len);
        dbgassert(at <= gs.textLen());

        if (at < gs.pivot) {
            try gs.ensureHeadRoom(new_len);
            const new_start = gs.start - new_len;
            @memmove(gs.buffer[new_start..][0..at], gs.buffer[gs.start..][0..at]);
            gs.start = new_start;
        } else {
            try gs.ensureTailRoom(new_len);
            const abs_start = gs.start + at;
            @memmove(
                gs.buffer[abs_start + new_len ..][0 .. gs.end - abs_start],
                gs.buffer[abs_start..][0 .. gs.end - abs_start],
            );
            gs.end += new_len;
        }

        @memcpy(gs.buffer[gs.start + at ..][0..new_len], new_text);
        gs.budget -|= new_len;
    }

    /// Deletes a contiguous effective-text range from the slack buffer.
    fn delete(gs: *DeltaGuidanceSystem, start: u32, len: u32) void {
        const abs_start = gs.start + start;
        const abs_end = abs_start + len;
        dbgassert(start <= gs.textLen());
        dbgassert(len <= gs.textLen() - start);

        if (start < gs.pivot) {
            @memmove(gs.buffer[gs.start + len ..][0..start], gs.buffer[gs.start..][0..start]);
            gs.start += len;
        } else {
            @memmove(
                gs.buffer[abs_start..][0 .. gs.end - abs_end],
                gs.buffer[abs_end..][0 .. gs.end - abs_end],
            );
            gs.end -= len;
        }

        gs.budget +|= len;
    }

    /// Returns the current effective-text length tracked by the buffer.
    fn textLen(gs: *const DeltaGuidanceSystem) u32 {
        return gs.end - gs.start;
    }

    /// Walks forward from the attachment cursor until the next actionable raw op.
    fn scanNextEdit(gs: *DeltaGuidanceSystem) Error!?ScannedEdit {
        const attached = gs.attached_step orelse return error.MissingZDelta;
        var raw_index = attached.raw_index_next;
        var expected_cursor = attached.expected_cursor_next;

        while (raw_index < attached.raw_delta.ops.len) {
            const op = attached.raw_delta.ops[raw_index];
            switch (op) {
                .equal => |len| {
                    expected_cursor += len;
                    raw_index += 1;
                },
                .insert => |span| {
                    const edit = try gs.previewInsert(raw_index, expected_cursor, span.len);
                    return .{
                        .raw_index = raw_index,
                        .expected_cursor = expected_cursor,
                        .op = op,
                        .edit = edit,
                    };
                },
                .delete => |len| {
                    const edit = try gs.previewDelete(raw_index, expected_cursor, len);
                    return .{
                        .raw_index = raw_index,
                        .expected_cursor = expected_cursor,
                        .op = op,
                        .edit = edit,
                    };
                },
            }
        }
        return null;
    }

    /// Classifies an insertion against the current correction surface.
    fn previewInsert(gs: *DeltaGuidanceSystem, raw_index: u32, expected_at: u32, insert_len: u32) Error!EffectiveEdit {
        _ = insert_len;
        gs.preview_anomalies.clearRetainingCapacity();
        var info = InsertPointInfo{};
        try gs.inspectInsertPoint(gs.current_step.correction_root, 0, 0, expected_at, &info);
        const effective_at = info.after_impositions orelse info.exact orelse info.fallback orelse gs.current_step.ef_len;

        if (info.state.inside_anomalous_evacuation) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .insert_at = expected_at },
                .effective_target = .{ .insert_at = effective_at },
                .class = .stranded,
                .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
                .available_resolutions = no_resolutions[0..],
            };
        }
        if (info.state.has_imposition_here or info.state.has_anomalous_neighbor) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .insert_at = expected_at },
                .effective_target = .complex,
                .class = .complex,
                .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
                .available_resolutions = no_resolutions[0..],
            };
        }

        return .{
            .raw_op_index = raw_index,
            .expected_target = .{ .insert_at = expected_at },
            .effective_target = .{ .insert_at = effective_at },
            .class = .pure,
            .touched_anomalies = .{ .off = 0, .len = 0 },
            .available_resolutions = no_resolutions[0..],
        };
    }

    /// Classifies a deletion against the current correction surface.
    fn previewDelete(gs: *DeltaGuidanceSystem, raw_index: u32, expected_start: u32, len: u32) Error!EffectiveEdit {
        gs.preview_anomalies.clearRetainingCapacity();
        const expected = Span{ .start = expected_start, .end = expected_start + len };
        var touching = try gs.collectTouchedRegions(gs.current_step.correction_root, expected);
        defer touching.deinit(gs.allocator);

        if (touching.items.len == 0) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .delete = expected },
                .effective_target = .complex,
                .class = .complex,
                .touched_anomalies = .{ .off = 0, .len = 0 },
                .available_resolutions = no_resolutions[0..],
            };
        }

        const start_inside_anomaly = gs.insideAnomalousEvacuation(expected.start);
        const end_inside_anomaly = gs.insideAnomalousEvacuation(expected.end);

        var anomaly_count: usize = 0;
        var pristine_count: usize = 0;
        var has_imposition = false;

        for (touching.items) |region| {
            switch (region) {
                .pristine => pristine_count += 1,
                .evacuation => |r| {
                    if (r.anomalies) |ref| {
                        anomaly_count += 1;
                        try gs.appendPreviewAnomalies(ref);
                    }
                },
                .imposition => |r| {
                    if (r.anomalies) |ref| {
                        anomaly_count += 1;
                        has_imposition = true;
                        try gs.appendPreviewAnomalies(ref);
                    }
                },
            }
        }

        if ((start_inside_anomaly or end_inside_anomaly) and
            !(start_inside_anomaly and
                end_inside_anomaly and
                anomaly_count == 1 and
                pristine_count == 0))
        {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .delete = expected },
                .effective_target = .complex,
                .class = .complex,
                .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
                .available_resolutions = no_resolutions[0..],
            };
        }

        const effective = Span{
            .start = try gs.effectiveDeleteBoundary(expected.start),
            .end = try gs.effectiveDeleteBoundary(expected.end),
        };

        if (anomaly_count == 0) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .delete = expected },
                .effective_target = .{ .delete = effective },
                .class = .pure,
                .touched_anomalies = .{ .off = 0, .len = 0 },
                .available_resolutions = no_resolutions[0..],
            };
        }
        if (anomaly_count == 1 and pristine_count > 0 and has_imposition) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .delete = expected },
                .effective_target = .{ .delete = effective },
                .class = .overlaid,
                .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
                .available_resolutions = delete_whole_only[0..],
            };
        }
        if (anomaly_count == 1 and pristine_count == 0) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .delete = expected },
                .effective_target = .{ .delete = effective },
                .class = .stranded,
                .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
                .available_resolutions = no_resolutions[0..],
            };
        }
        if (anomaly_count == 1 and pristine_count > 0) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .delete = expected },
                .effective_target = .{ .delete = effective },
                .class = .overlaid,
                .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
                .available_resolutions = no_resolutions[0..],
            };
        }
        return .{
            .raw_op_index = raw_index,
            .expected_target = .{ .delete = expected },
            .effective_target = .complex,
            .class = .complex,
            .touched_anomalies = .{ .off = 0, .len = try checkedU32(gs.preview_anomalies.items.len) },
            .available_resolutions = no_resolutions[0..],
        };
    }

    /// Chooses the concrete apply resolution for a previewed edit.
    fn resolveApply(gs: *DeltaGuidanceSystem, edit: *const EffectiveEdit, resolution: ?ApplyResolution) Error!?ApplyResolution {
        _ = gs;
        if (edit.available_resolutions.len == 0) return null;
        if (resolution) |chosen| {
            for (edit.available_resolutions) |candidate| {
                if (candidate == chosen) return chosen;
            }
        }
        if (edit.available_resolutions.len == 1) return edit.available_resolutions[0];
        return error.UnresolvedZDeltaOp;
    }

    /// Accepts a raw insert, mutating the buffer and adding an imposition region.
    fn applyInsert(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, span: DeltaSpan, resolution: ?ApplyResolution) Error!void {
        _ = resolution;
        dbgassert(scanned.edit.class == .pure);

        const attached = &gs.attached_step.?;
        const insert_at = scanned.edit.effective_target.insert_at;
        const text = try gs.deltaInsertText(span);
        const residue = try gs.appendResidue(text);

        try gs.insert(insert_at, text);
        const decision = try gs.appendDecision(.{ .insert = .{
            .id = nextDecisionIndex(gs),
            .revision_ordinal = attached.target_revision,
            .raw_op_index = scanned.raw_index,
            .expected_at = scanned.expected_cursor,
            .effective_at_before = insert_at,
            .effective_at_after = insert_at + span.len,
            .residue_off = residue.off,
            .residue_len = residue.len,
        } });

        const decision_ref = try gs.appendDecisionProvenance(&.{decision});
        const split = try gs.splitAtExpected(gs.current_step.correction_root, scanned.expected_cursor);
        const root = (try gs.concatThree(
            split.left,
            try gs.createImpositionNode(span.len, decision_ref, null),
            split.right,
        )).?;

        try gs.commitNewStepRoot(
            root,
            decision,
            null,
            scanned.raw_index + 1,
            scanned.expected_cursor,
        );
    }

    /// Declines a raw insert, recording an evacuation anomaly without changing text.
    fn skipInsert(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, span: DeltaSpan) Error!void {
        dbgassert(scanned.edit.class == .pure);

        const attached = &gs.attached_step.?;
        const text = try gs.deltaInsertText(span);
        const residue = try gs.appendResidue(text);
        const decision = try gs.appendDecision(.{ .decline = .{
            .id = nextDecisionIndex(gs),
            .revision_ordinal = attached.target_revision,
            .raw_op_index = scanned.raw_index,
            .expected_at = scanned.expected_cursor,
            .anomaly = undefined,
        } });
        const anomaly = try gs.appendAnomaly(.{ .evacuation = .{
            .id = nextAnomalyIndex(gs),
            .created_by = decision,
            .expected = .{ .start = scanned.expected_cursor, .end = scanned.expected_cursor + span.len },
            .residue_off = residue.off,
            .residue_len = residue.len,
        } });
        gs.decisions.items[decisionToInt(decision)].decline.anomaly = anomaly;

        const decision_ref = try gs.appendDecisionProvenance(&.{decision});
        const anomaly_ref = try gs.appendAnomalyProvenance(&.{anomaly});
        const split = try gs.splitAtExpected(gs.current_step.correction_root, scanned.expected_cursor);
        const root = (try gs.concatThree(
            split.left,
            try gs.createEvacuationNode(span.len, decision_ref, anomaly_ref),
            split.right,
        )).?;

        try gs.commitNewStepRoot(root, decision, anomaly, scanned.raw_index + 1, scanned.expected_cursor + span.len);
    }

    /// Accepts a raw delete, storing removed bytes in residue for undo.
    fn applyDelete(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, len: u32, resolution: ?ApplyResolution) Error!void {
        const expected = scanned.edit.expected_target.delete;
        const effective = scanned.edit.effective_target.delete;
        const attached = &gs.attached_step.?;

        const deleted_text = try gs.allocator.dupe(u8, gs.currentText()[effective.start..effective.end]);
        defer gs.allocator.free(deleted_text);
        const residue = try gs.appendResidue(deleted_text);

        gs.delete(effective.start, effective.len());
        const decision = try gs.appendDecision(.{ .delete = .{
            .id = nextDecisionIndex(gs),
            .revision_ordinal = attached.target_revision,
            .raw_op_index = scanned.raw_index,
            .expected = expected,
            .effective_before = effective,
            .effective_after = .{ .start = effective.start, .end = effective.start },
            .residue_off = residue.off,
            .residue_len = residue.len,
            .resolution = resolution,
        } });

        const split_before = try gs.splitAtExpected(gs.current_step.correction_root, expected.start);
        const split_after = if (split_before.right) |right|
            try gs.splitAtExpected(right, len)
        else
            TreeSplit{ .left = null, .right = null };
        const root = (try gs.concatThree(
            split_before.left,
            try gs.applyDeleteToSubtree(split_after.left, decision, resolution),
            split_after.right,
        )).?;

        try gs.commitNewStepRoot(root, decision, null, scanned.raw_index + 1, scanned.expected_cursor + len);
    }

    /// Rescues a raw delete, preserving the effective text as an imposition anomaly.
    fn skipDelete(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, len: u32) Error!void {
        if (scanned.edit.class != .pure) return error.UnresolvedZDeltaOp;
        const expected = scanned.edit.expected_target.delete;
        const effective = scanned.edit.effective_target.delete;
        const attached = &gs.attached_step.?;
        const decision = try gs.appendDecision(.{ .rescue = .{
            .id = nextDecisionIndex(gs),
            .revision_ordinal = attached.target_revision,
            .raw_op_index = scanned.raw_index,
            .expected = expected,
            .anomaly = undefined,
            .resolution = null,
        } });
        const anomaly = try gs.appendAnomaly(.{ .imposition = .{
            .id = nextAnomalyIndex(gs),
            .created_by = decision,
            .expected_at = expected.start,
            .ef_wid = effective.len(),
        } });
        gs.decisions.items[decisionToInt(decision)].rescue.anomaly = anomaly;

        const decision_ref = try gs.appendDecisionProvenance(&.{decision});
        const anomaly_ref = try gs.appendAnomalyProvenance(&.{anomaly});
        const split_before = try gs.splitAtExpected(gs.current_step.correction_root, expected.start);
        const split_after = if (split_before.right) |right|
            try gs.splitAtExpected(right, len)
        else
            TreeSplit{ .left = null, .right = null };
        if (split_after.left) |middle| {
            if (!subtreeIsAllPristine(middle)) return error.UnresolvedZDeltaOp;
        }
        const root = (try gs.concatThree(
            split_before.left,
            try gs.createImpositionNode(len, decision_ref, anomaly_ref),
            split_after.right,
        )).?;

        try gs.commitNewStepRoot(
            root,
            decision,
            anomaly,
            scanned.raw_index + 1,
            scanned.expected_cursor,
        );
    }

    /// Reverses the text effects of a single recorded decision.
    fn undoDecision(gs: *DeltaGuidanceSystem, decision: DecisionIndex) Error!void {
        switch (gs.decisions.items[decisionToInt(decision)]) {
            .insert => |r| gs.delete(r.effective_at_before, r.residue_len),
            .delete => |r| try gs.insert(r.effective_before.start, gs.residueSlice(.{
                .off = r.residue_off,
                .len = r.residue_len,
            })),
            .decline, .rescue => {},
        }
    }

    /// Reapplies the text effects of a single recorded decision.
    fn redoDecision(gs: *DeltaGuidanceSystem, decision: DecisionIndex) Error!void {
        switch (gs.decisions.items[decisionToInt(decision)]) {
            .insert => |r| try gs.insert(r.effective_at_before, gs.residueSlice(.{
                .off = r.residue_off,
                .len = r.residue_len,
            })),
            .delete => |r| gs.delete(r.effective_before.start, r.effective_before.len()),
            .decline, .rescue => {},
        }
    }

    /// Slices the attached delta's insert-text payload for one raw insert op.
    fn deltaInsertText(gs: *const DeltaGuidanceSystem, span: DeltaSpan) Error![]const u8 {
        const attached = gs.attached_step orelse return error.MissingZDelta;
        return attached.raw_delta.text(span);
    }

    /// Appends a decision record and returns its stable global id.
    fn appendDecision(gs: *DeltaGuidanceSystem, record: DecisionRecord) Error!DecisionIndex {
        try gs.decisions.append(gs.allocator, record);
        return decisionIndex(gs.decisions.items.len - 1);
    }

    /// Appends an anomaly record and returns its stable global id.
    fn appendAnomaly(gs: *DeltaGuidanceSystem, record: AnomalyRecord) Error!AnomalyIndex {
        try gs.anomalies.append(gs.allocator, record);
        return anomalyIndex(gs.anomalies.items.len - 1);
    }

    /// Copies undo-relevant bytes into the shared residue store.
    fn appendResidue(gs: *DeltaGuidanceSystem, bytes: []const u8) Error!ProvenanceRef {
        const off = try checkedU32(gs.residue.items.len);
        try gs.residue.appendSlice(gs.allocator, bytes);
        return .{ .off = off, .len = try checkedU32(bytes.len) };
    }

    /// Resolves a residue provenance reference back to stored bytes.
    fn residueSlice(gs: *const DeltaGuidanceSystem, ref: ProvenanceRef) []const u8 {
        const start: usize = ref.off;
        const len: usize = ref.len;
        return gs.residue.items[start..][0..len];
    }

    /// Appends decision ids to the provenance side table and returns their range.
    fn appendDecisionProvenance(gs: *DeltaGuidanceSystem, values: []const DecisionIndex) Error!ProvenanceRef {
        const off = try checkedU32(gs.decision_provenance.items.len);
        try gs.decision_provenance.appendSlice(gs.allocator, values);
        return .{ .off = off, .len = try checkedU32(values.len) };
    }

    /// Appends anomaly ids to the provenance side table and returns their range.
    fn appendAnomalyProvenance(gs: *DeltaGuidanceSystem, values: []const AnomalyIndex) Error!ProvenanceRef {
        const off = try checkedU32(gs.anomaly_provenance.items.len);
        try gs.anomaly_provenance.appendSlice(gs.allocator, values);
        return .{ .off = off, .len = try checkedU32(values.len) };
    }

    /// Extends an existing decision provenance range with one additional decision id.
    fn combineDecisionRefs(gs: *DeltaGuidanceSystem, base: ProvenanceRef, extra: DecisionIndex) Error!ProvenanceRef {
        const start: usize = base.off;
        const len: usize = base.len;
        var scratch = std.ArrayListUnmanaged(DecisionIndex).empty;
        defer scratch.deinit(gs.allocator);
        try scratch.appendSlice(gs.allocator, gs.decision_provenance.items[start..][0..len]);
        try scratch.append(gs.allocator, extra);
        return gs.appendDecisionProvenance(scratch.items);
    }

    /// Copies anomaly ids into preview scratch space for the current classification result.
    fn appendPreviewAnomalies(gs: *DeltaGuidanceSystem, ref: ProvenanceRef) Error!void {
        const start: usize = ref.off;
        const len: usize = ref.len;
        try gs.preview_anomalies.appendSlice(gs.allocator, gs.anomaly_provenance.items[start..][0..len]);
    }

    /// Creates a new region node from already-local region geometry.
    fn createRegionNode(gs: *DeltaGuidanceSystem, region: CorrectionRegion) Error!*CorrectionNode {
        const node = try gs.arena.allocator().create(CorrectionNode);
        node.* = .{ .region = region };
        return node;
    }

    /// Creates a pristine region node local to its subtree root.
    fn createPristineNode(gs: *DeltaGuidanceSystem, wid: u32, decisions: ProvenanceRef) Error!*CorrectionNode {
        return gs.createRegionNode(.{ .pristine = .{
            .expected = .{ .start = 0, .end = wid },
            .effective = .{ .start = 0, .end = wid },
            .wid = wid,
            .decisions = decisions,
        } });
    }

    /// Creates an evacuation region node local to its subtree root.
    fn createEvacuationNode(
        gs: *DeltaGuidanceSystem,
        ex_wid: u32,
        decisions: ProvenanceRef,
        anomalies: ?ProvenanceRef,
    ) Error!*CorrectionNode {
        return gs.createRegionNode(.{ .evacuation = .{
            .expected = .{ .start = 0, .end = ex_wid },
            .effective_at = 0,
            .ex_wid = ex_wid,
            .decisions = decisions,
            .anomalies = anomalies,
        } });
    }

    /// Creates an imposition region node local to its subtree root.
    fn createImpositionNode(
        gs: *DeltaGuidanceSystem,
        ef_wid: u32,
        decisions: ProvenanceRef,
        anomalies: ?ProvenanceRef,
    ) Error!*CorrectionNode {
        return gs.createRegionNode(.{ .imposition = .{
            .expected_at = 0,
            .effective = .{ .start = 0, .end = ef_wid },
            .ef_wid = ef_wid,
            .decisions = decisions,
            .anomalies = anomalies,
        } });
    }

    /// Combines two subtrees under one checked span node.
    fn createSpanNode(gs: *DeltaGuidanceSystem, left: *CorrectionNode, right: *CorrectionNode) Error!*CorrectionNode {
        const left_ex_wid = treeExWid(left);
        const left_deviation = treeDeviation(left);
        const left_ef_wid = applyDeviationToWidth(left_ex_wid, left_deviation);
        dbgassert(left_ef_wid == treeEfWid(left));

        const node = try gs.arena.allocator().create(CorrectionNode);
        node.* = .{ .span = .{
            .ex_wid = left_ex_wid,
            .ef_wid = left_ef_wid,
            .deviation = left_deviation,
            .pivot = left_ef_wid,
            .left = left,
            .right = right,
        } };
        return node;
    }

    /// Concatenates two adjacent subtrees, reusing either side directly when possible.
    fn concatNodes(
        gs: *DeltaGuidanceSystem,
        left: ?*CorrectionNode,
        right: ?*CorrectionNode,
    ) Error!?*CorrectionNode {
        if (left == null) return right;
        if (right == null) return left;
        return gs.createSpanNode(left.?, right.?);
    }

    /// Concatenates three adjacent subtrees into one persistent subtree.
    fn concatThree(
        gs: *DeltaGuidanceSystem,
        left: ?*CorrectionNode,
        middle: ?*CorrectionNode,
        right: ?*CorrectionNode,
    ) Error!?*CorrectionNode {
        return gs.concatNodes(try gs.concatNodes(left, middle), right);
    }

    /// Splits a subtree at an expected boundary, keeping zero-width anchors on the right.
    fn splitAtExpected(gs: *DeltaGuidanceSystem, node: *CorrectionNode, point: u32) Error!TreeSplit {
        dbgassert(point <= treeExWid(node));
        return switch (node.*) {
            .region => |region| switch (region) {
                .pristine => |r| blk: {
                    if (point == 0) break :blk .{ .left = null, .right = node };
                    if (point == r.wid) break :blk .{ .left = node, .right = null };
                    break :blk .{
                        .left = try gs.createPristineNode(point, r.decisions),
                        .right = try gs.createPristineNode(r.wid - point, r.decisions),
                    };
                },
                .evacuation => |r| blk: {
                    if (point == 0) break :blk .{ .left = null, .right = node };
                    if (point == r.ex_wid) break :blk .{ .left = node, .right = null };
                    break :blk .{
                        .left = try gs.createEvacuationNode(point, r.decisions, r.anomalies),
                        .right = try gs.createEvacuationNode(r.ex_wid - point, r.decisions, r.anomalies),
                    };
                },
                .imposition => .{ .left = null, .right = node },
            },
            .span => |span| blk: {
                if (point < span.ex_wid) {
                    const split = try gs.splitAtExpected(span.left, point);
                    break :blk .{
                        .left = split.left,
                        .right = try gs.concatNodes(split.right, span.right),
                    };
                }
                if (point > span.ex_wid) {
                    const split = try gs.splitAtExpected(span.right, point - span.ex_wid);
                    break :blk .{
                        .left = try gs.concatNodes(span.left, split.left),
                        .right = split.right,
                    };
                }
                const split = try gs.splitAtExpected(span.left, point);
                break :blk .{
                    .left = split.left,
                    .right = try gs.concatNodes(split.right, span.right),
                };
            },
        };
    }

    /// Promotes one subtree onto the next expected axis while preserving anomalies.
    fn promoteSubtree(gs: *DeltaGuidanceSystem, node: *CorrectionNode) Error!?*CorrectionNode {
        return switch (node.*) {
            .region => |region| switch (region) {
                .pristine => node,
                .evacuation => |r| if (r.anomalies != null) node else null,
                .imposition => |r| if (r.anomalies != null) node else try gs.createPristineNode(r.ef_wid, r.decisions),
            },
            .span => |span| try gs.concatNodes(
                try gs.promoteSubtree(span.left),
                try gs.promoteSubtree(span.right),
            ),
        };
    }

    /// Applies an accepted delete to the isolated middle subtree of a split tree.
    fn applyDeleteToSubtree(
        gs: *DeltaGuidanceSystem,
        node: ?*CorrectionNode,
        decision: DecisionIndex,
        resolution: ?ApplyResolution,
    ) Error!?*CorrectionNode {
        const root = node orelse return null;
        return switch (root.*) {
            .region => |region| switch (region) {
                .pristine => |r| try gs.createEvacuationNode(
                    r.wid,
                    try gs.combineDecisionRefs(r.decisions, decision),
                    null,
                ),
                .evacuation => |r| try gs.createEvacuationNode(
                    r.ex_wid,
                    try gs.combineDecisionRefs(r.decisions, decision),
                    r.anomalies,
                ),
                .imposition => |r| if (resolution == .delete_whole and r.anomalies != null) null else root,
            },
            .span => |span| try gs.concatNodes(
                try gs.applyDeleteToSubtree(span.left, decision, resolution),
                try gs.applyDeleteToSubtree(span.right, decision, resolution),
            ),
        };
    }

    /// Commits a freshly built tree root as the next immutable step snapshot.
    fn commitNewStepRoot(
        gs: *DeltaGuidanceSystem,
        root: *CorrectionNode,
        decision: DecisionIndex,
        anomaly: ?AnomalyIndex,
        raw_index_next: u32,
        expected_cursor_next: u32,
    ) Error!void {
        gs.current_step.next = null;

        const step = try gs.arena.allocator().create(Step);
        step.* = .{
            .prior = gs.current_step,
            .next = null,
            .correction_root = root,
            .ef_len = treeEfWid(root),
            .ex_len = treeExWid(root),
            .decision = decision,
            .anomaly = anomaly,
            .anomaly_count = gs.current_step.anomaly_count + @as(u32, if (anomaly != null) 1 else 0),
            .decision_count = gs.current_step.decision_count + 1,
            .raw_index_next = raw_index_next,
            .expected_cursor_next = expected_cursor_next,
        };
        gs.current_step.next = step;
        gs.current_step = step;
        if (gs.attached_step) |*attached| {
            attached.raw_index_next = raw_index_next;
            attached.expected_cursor_next = expected_cursor_next;
        }
    }

    /// Collects only regions that may affect a delete over the given expected span.
    fn collectTouchedRegions(
        gs: *DeltaGuidanceSystem,
        root: *const CorrectionNode,
        expected: Span,
    ) Error!std.ArrayListUnmanaged(CorrectionRegion) {
        var out = std.ArrayListUnmanaged(CorrectionRegion).empty;
        errdefer out.deinit(gs.allocator);
        try gs.appendTouchedRegions(&out, root, 0, expected);
        return out;
    }

    /// Descends the tree and appends leaves overlapping or anchored inside the expected span.
    fn appendTouchedRegions(
        gs: *DeltaGuidanceSystem,
        out: *std.ArrayListUnmanaged(CorrectionRegion),
        node: *const CorrectionNode,
        ex_base: u32,
        expected: Span,
    ) Error!void {
        if (!subtreeMayTouchExpected(node, ex_base, expected)) return;
        switch (node.*) {
            .region => |region| {
                const ex_end = ex_base + region.exWid();
                const overlaps = region.exWid() != 0 and ex_base < expected.end and expected.start < ex_end;
                const anchored_inside = region.exWid() == 0 and ex_base >= expected.start and ex_base < expected.end;
                if (overlaps or anchored_inside) {
                    try out.append(gs.allocator, region);
                }
            },
            .span => |span| {
                try gs.appendTouchedRegions(out, span.left, ex_base, expected);
                try gs.appendTouchedRegions(out, span.right, ex_base + span.ex_wid, expected);
            },
        }
    }

    /// Reports whether an expected point lies strictly inside an anomalous evacuation.
    fn insideAnomalousEvacuation(gs: *const DeltaGuidanceSystem, point: u32) bool {
        return gs.pointInsideAnomalousEvacuation(gs.current_step.correction_root, 0, point);
    }

    /// Descends to determine whether a point falls inside missing-but-anomalous expected text.
    fn pointInsideAnomalousEvacuation(
        gs: *const DeltaGuidanceSystem,
        node: *const CorrectionNode,
        ex_base: u32,
        point: u32,
    ) bool {
        return switch (node.*) {
            .region => |region| switch (region) {
                .evacuation => |r| r.anomalies != null and point > ex_base and point < ex_base + r.ex_wid,
                else => false,
            },
            .span => |span| blk: {
                const split_ex = ex_base + span.ex_wid;
                if (point < split_ex) break :blk gs.pointInsideAnomalousEvacuation(span.left, ex_base, point);
                if (point > split_ex) break :blk gs.pointInsideAnomalousEvacuation(span.right, split_ex, point);
                break :blk gs.pointInsideAnomalousEvacuation(span.left, ex_base, point) or
                    gs.pointInsideAnomalousEvacuation(span.right, split_ex, point);
            },
        };
    }

    /// Maps an expected delete boundary onto the effective axis.
    fn effectiveDeleteBoundary(gs: *const DeltaGuidanceSystem, point: u32) Error!u32 {
        return gs.lookupDeleteBoundary(gs.current_step.correction_root, 0, 0, point) orelse gs.current_step.ef_len;
    }

    /// Descends to the insertion boundary and records local anomaly state plus effective placement.
    fn inspectInsertPoint(
        gs: *DeltaGuidanceSystem,
        node: *const CorrectionNode,
        ex_base: u32,
        deviation: i32,
        point: u32,
        info: *InsertPointInfo,
    ) Error!void {
        switch (node.*) {
            .region => |region| switch (region) {
                .pristine => |r| {
                    const end = ex_base + r.wid;
                    if (point >= ex_base and point <= end) info.exact = applyDeviation(point, deviation);
                    if (point < ex_base and info.fallback == null) info.fallback = applyDeviation(ex_base, deviation);
                },
                .evacuation => |r| {
                    const end = ex_base + r.ex_wid;
                    const effective_at = applyDeviation(ex_base, deviation);
                    if (r.anomalies) |ref| {
                        if (point > ex_base and point < end) {
                            info.state.inside_anomalous_evacuation = true;
                            try gs.appendPreviewAnomalies(ref);
                        }
                        if (point == ex_base or point == end) {
                            info.state.has_anomalous_neighbor = true;
                            try gs.appendPreviewAnomalies(ref);
                        }
                    }
                    if (point >= ex_base and point <= end and info.exact == null) info.exact = effective_at;
                    if (point < ex_base and info.fallback == null) info.fallback = effective_at;
                },
                .imposition => |r| {
                    const effective_at = applyDeviation(ex_base, deviation);
                    if (point == ex_base) {
                        info.state.has_imposition_here = true;
                        info.after_impositions = effective_at + r.ef_wid;
                        if (r.anomalies) |ref| {
                            info.state.has_anomalous_neighbor = true;
                            try gs.appendPreviewAnomalies(ref);
                        }
                    }
                    if (point < ex_base and info.fallback == null) info.fallback = effective_at;
                },
            },
            .span => |span| {
                const split_ex = ex_base + span.ex_wid;
                if (point <= split_ex) try gs.inspectInsertPoint(span.left, ex_base, deviation, point, info);
                if (point >= split_ex) try gs.inspectInsertPoint(
                    span.right,
                    split_ex,
                    addDeviation(deviation, span.deviation),
                    point,
                    info,
                );
            },
        }
    }

    /// Descends to the delete boundary and returns the effective cursor at that boundary.
    fn lookupDeleteBoundary(
        gs: *const DeltaGuidanceSystem,
        node: *const CorrectionNode,
        ex_base: u32,
        deviation: i32,
        point: u32,
    ) ?u32 {
        return switch (node.*) {
            .region => |region| switch (region) {
                .pristine => |r| blk: {
                    const end = ex_base + r.wid;
                    if (point >= ex_base and point <= end) break :blk applyDeviation(point, deviation);
                    if (point < ex_base) break :blk applyDeviation(ex_base, deviation);
                    break :blk null;
                },
                .evacuation => |r| blk: {
                    const end = ex_base + r.ex_wid;
                    const effective_at = applyDeviation(ex_base, deviation);
                    if (point >= ex_base and point <= end) break :blk effective_at;
                    if (point < ex_base) break :blk effective_at;
                    break :blk null;
                },
                .imposition => |r| blk: {
                    const effective_at = applyDeviation(ex_base, deviation);
                    if (point == ex_base) break :blk effective_at;
                    if (point < ex_base) break :blk effective_at;
                    _ = r;
                    break :blk null;
                },
            },
            .span => |span| blk: {
                const split_ex = ex_base + span.ex_wid;
                if (point < split_ex) break :blk gs.lookupDeleteBoundary(span.left, ex_base, deviation, point);
                if (point > split_ex) break :blk gs.lookupDeleteBoundary(
                    span.right,
                    split_ex,
                    addDeviation(deviation, span.deviation),
                    point,
                );
                break :blk gs.lookupDeleteBoundary(
                    span.right,
                    split_ex,
                    addDeviation(deviation, span.deviation),
                    point,
                ) orelse gs.lookupDeleteBoundary(span.left, ex_base, deviation, point);
            },
        };
    }
};

/// Internal bundle pairing a raw op location with its previewed effective edit.
const ScannedEdit = struct {
    raw_index: u32,
    expected_cursor: u32,
    op: DeltaOp,
    edit: EffectiveEdit,
};

/// Local summary of anomaly pressure around a candidate insertion boundary.
const BoundaryState = struct {
    inside_anomalous_evacuation: bool = false,
    has_imposition_here: bool = false,
    has_anomalous_neighbor: bool = false,
};

/// Accumulates everything needed to classify and place an insertion boundary.
const InsertPointInfo = struct {
    state: BoundaryState = .{},
    fallback: ?u32 = null,
    exact: ?u32 = null,
    after_impositions: ?u32 = null,
};

const no_resolutions = [_]ApplyResolution{};
const delete_whole_only = [_]ApplyResolution{.delete_whole};

/// Reports whether a subtree could contain any region relevant to the expected span.
fn subtreeMayTouchExpected(node: *const CorrectionNode, ex_base: u32, expected: Span) bool {
    const ex_wid = treeExWid(node);
    if (ex_wid == 0) return expected.start <= ex_base and ex_base < expected.end;
    return ex_base < expected.end and expected.start < ex_base + ex_wid;
}

/// Computes expected-axis width for a correction subtree.
fn treeExWid(node: *const CorrectionNode) u32 {
    return switch (node.*) {
        .span => |span| span.ex_wid + treeExWid(span.right),
        .region => |region| region.exWid(),
    };
}

/// Computes effective-axis width for a correction subtree.
fn treeEfWid(node: *const CorrectionNode) u32 {
    return switch (node.*) {
        .span => |span| blk: {
            const left_ef_wid = applyDeviationToWidth(span.ex_wid, span.deviation);
            dbgassert(left_ef_wid == span.ef_wid);
            break :blk left_ef_wid + treeEfWid(span.right);
        },
        .region => |region| region.efWid(),
    };
}

/// Computes the authoritative effective-minus-expected deviation for a subtree.
fn treeDeviation(node: *const CorrectionNode) i32 {
    return switch (node.*) {
        .region => |region| switch (region) {
            .pristine => 0,
            .evacuation => |r| -@as(i32, @intCast(r.ex_wid)),
            .imposition => |r| @as(i32, @intCast(r.ef_wid)),
        },
        .span => |span| addDeviation(span.deviation, treeDeviation(span.right)),
    };
}

/// Returns the next unused global decision id.
fn nextDecisionIndex(gs: *const DeltaGuidanceSystem) DecisionIndex {
    return decisionIndex(gs.decisions.items.len);
}

/// Returns the next unused global anomaly id.
fn nextAnomalyIndex(gs: *const DeltaGuidanceSystem) AnomalyIndex {
    return anomalyIndex(gs.anomalies.items.len);
}

/// Wraps a raw ordinal as a typed decision id.
fn decisionIndex(value: usize) DecisionIndex {
    return @enumFromInt(@as(u32, @intCast(value)));
}

/// Wraps a raw ordinal as a typed anomaly id.
fn anomalyIndex(value: usize) AnomalyIndex {
    return @enumFromInt(@as(u32, @intCast(value)));
}

/// Unwraps a typed decision id for array indexing.
fn decisionToInt(value: DecisionIndex) usize {
    return @intFromEnum(value);
}

/// Narrows a usize to u32 using the shared zdelta checked conversion.
fn checkedU32(value: usize) Error!u32 {
    return zdelta_mod.checkedU32(value);
}

/// Narrows initial text length to the supported in-memory guidance range.
fn checkedGuidanceTextLen(value: usize) Error!u32 {
    return checkedU32(value) catch error.GuidanceTextTooLarge;
}

/// Computes the initial slack budget for guidance startup.
fn initialGuidanceSlack(text_len: usize) Error!usize {
    return apply_base.initialSlack(text_len) catch error.GuidanceTextTooLarge;
}

/// Computes the backing buffer length for the initial text plus startup slack.
fn totalGuidanceBufferLen(text_len: usize, extra_slack: usize) Error!usize {
    return std.math.add(usize, text_len, extra_slack) catch error.GuidanceTextTooLarge;
}

/// Adds two u32 values using the shared zdelta checked addition helper.
fn addU32(a: u32, b: u32) Error!u32 {
    return zdelta_mod.addU32(a, b);
}

/// Adds one deviation to another, keeping the result within the checked i32 range.
fn addDeviation(lhs: i32, rhs: i32) i32 {
    const sum = @as(i64, lhs) + @as(i64, rhs);
    dbgassert(sum >= std.math.minInt(i32));
    dbgassert(sum <= std.math.maxInt(i32));
    return @intCast(sum);
}

/// Applies an authoritative deviation to one expected-axis boundary.
fn applyDeviation(expected_at: u32, deviation: i32) u32 {
    const shifted = @as(i64, expected_at) + @as(i64, deviation);
    dbgassert(shifted >= 0);
    dbgassert(shifted <= std.math.maxInt(u32));
    return @intCast(shifted);
}

/// Applies a subtree deviation to its expected width to recover effective width.
fn applyDeviationToWidth(ex_wid: u32, deviation: i32) u32 {
    return applyDeviation(ex_wid, deviation);
}

/// Reports whether every terminal region in a subtree is pristine.
fn subtreeIsAllPristine(node: *const CorrectionNode) bool {
    return switch (node.*) {
        .region => |region| region == .pristine,
        .span => |span| subtreeIsAllPristine(span.left) and subtreeIsAllPristine(span.right),
    };
}

/// Test helper asserting the current effective text.
fn expectText(expected: []const u8, gs: *const DeltaGuidanceSystem) TestError!void {
    try testing.expectEqualStrings(expected, gs.currentText());
}

/// Test helper that diffs two texts and decodes the result into an owned `ZDelta`.
fn makeOwnedZDelta(allocator: Allocator, before: []const u8, after: []const u8) TestError!*ZDelta {
    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);
    const encoded = try diff.toZDelta(allocator, .b);
    defer allocator.free(encoded);

    const zdelta = try allocator.create(ZDelta);
    errdefer allocator.destroy(zdelta);
    zdelta.* = try zdelta_mod.decode(allocator, encoded);
    return zdelta;
}

/// Declarative action to take for one actionable preview during a test case.
const DeclarativeDecision = union(enum) {
    accept,
    decline,
    rescue,
    accept_with: ApplyResolution,
};

/// Minimal declarative spec for one guidance test scenario.
const DeclarativeGuidanceCase = struct {
    before: []const u8,
    after: []const u8,
    decisions: []const DeclarativeDecision,
    effective_after: []const u8,
    finish_step: bool = false,
    target_revision: usize = 1,
    dump_diff: bool = false,
};

/// Runs one declarative guidance scenario and returns the live guidance system for inspection.
fn runDeclarativeGuidanceCase(
    allocator: Allocator,
    case: DeclarativeGuidanceCase,
) TestError!DeltaGuidanceSystem {
    var gs = try DeltaGuidanceSystem.initText(allocator, case.before);
    errdefer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, case.before, case.after);
    if (case.dump_diff) {
        dumpZDeltaDiff(case.before, zdelta);
        return error.SkipZigTest;
    }
    try gs.openStep(zdelta, case.target_revision);

    for (case.decisions) |decision| {
        switch (decision) {
            .accept => try testing.expect(try gs.applyNext(null)),
            .decline => try testing.expect(try gs.skipNext()),
            .rescue => try testing.expect(try gs.skipNext()),
            .accept_with => |resolution| try testing.expect(try gs.applyNext(resolution)),
        }
    }

    try testing.expectEqual(@as(?EffectiveEdit, null), try gs.previewNext());
    if (case.finish_step) try gs.finishStep();
    try expectText(case.effective_after, &gs);
    return gs;
}

/// Prints one decoded zdelta op per line using plain diff-style markers.
fn dumpZDeltaDiff(before: []const u8, zdelta: *const ZDelta) void {
    var before_cursor: usize = 0;

    std.debug.print("decoded zdelta for declarative case:\n", .{});
    for (zdelta.ops) |op| {
        switch (op) {
            .equal => |len| {
                const slice = before[before_cursor..][0..len];
                before_cursor += len;
                std.debug.print("  {s}\n", .{slice});
            },
            .delete => |len| {
                const slice = before[before_cursor..][0..len];
                before_cursor += len;
                std.debug.print("- {s}\n", .{slice});
            },
            .insert => |span| {
                const slice = zdelta.text(span);
                std.debug.print("+ {s}\n", .{slice});
            },
        }
    }
}

/// Collects the terminal regions of a correction tree for test assertions.
fn collectTestRegions(
    allocator: Allocator,
    root: *const CorrectionNode,
) TestError![]CorrectionRegion {
    var out = std.ArrayListUnmanaged(CorrectionRegion).empty;
    defer out.deinit(allocator);
    try appendTestRegions(allocator, &out, root, 0, 0);
    return try out.toOwnedSlice(allocator);
}

/// Appends terminal regions from left to right for test-only inspection.
fn appendTestRegions(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(CorrectionRegion),
    node: *const CorrectionNode,
    ex_base: u32,
    deviation: i32,
) TestError!void {
    switch (node.*) {
        .region => |region| try out.append(allocator, switch (region) {
            .pristine => |r| .{ .pristine = .{
                .expected = .{ .start = ex_base, .end = ex_base + r.wid },
                .effective = .{
                    .start = applyDeviation(ex_base, deviation),
                    .end = applyDeviation(ex_base, deviation) + r.wid,
                },
                .wid = r.wid,
                .decisions = r.decisions,
            } },
            .evacuation => |r| .{ .evacuation = .{
                .expected = .{ .start = ex_base, .end = ex_base + r.ex_wid },
                .effective_at = applyDeviation(ex_base, deviation),
                .ex_wid = r.ex_wid,
                .decisions = r.decisions,
                .anomalies = r.anomalies,
            } },
            .imposition => |r| .{ .imposition = .{
                .expected_at = ex_base,
                .effective = .{
                    .start = applyDeviation(ex_base, deviation),
                    .end = applyDeviation(ex_base, deviation) + r.ef_wid,
                },
                .ef_wid = r.ef_wid,
                .decisions = r.decisions,
                .anomalies = r.anomalies,
            } },
        }),
        .span => |span| {
            try appendTestRegions(allocator, out, span.left, ex_base, deviation);
            try appendTestRegions(
                allocator,
                out,
                span.right,
                ex_base + span.ex_wid,
                addDeviation(deviation, span.deviation),
            );
        },
    }
}

/// Counts non-terminal span nodes in a correction tree.
fn countSpanNodes(node: *const CorrectionNode) usize {
    return switch (node.*) {
        .region => 0,
        .span => |span| 1 + countSpanNodes(span.left) + countSpanNodes(span.right),
    };
}

test "initText creates a synthetic genesis step" {
    var gs = try DeltaGuidanceSystem.initText(testing.allocator, "abcd");
    defer gs.deinit();

    try testing.expectEqual(@as(usize, 1), gs.decisions.items.len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.ef_len);
    try expectText("abcd", &gs);
}

test "openStep rejects expected-length mismatch and duplicate opens" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const wrong = try makeOwnedZDelta(allocator, "abc", "abc");
    try testing.expectError(error.ZDeltaTextLengthMismatch, gs.openStep(wrong, 1));

    const okay = try makeOwnedZDelta(allocator, "abcd", "abXd");
    try gs.openStep(okay, 1);
    const second = try makeOwnedZDelta(allocator, "abcd", "abcd");
    try testing.expectError(error.StepAlreadyOpen, gs.openStep(second, 2));
}

test "previewNext skips equals and previews a pure insert" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(zdelta, 1);

    const preview = (try gs.previewNext()).?;
    try testing.expectEqual(TargetClass.pure, preview.class);
    try testing.expectEqual(@as(u32, 1), preview.raw_op_index);
    try testing.expectEqual(@as(u32, 2), preview.expected_target.insert_at);
    try testing.expectEqual(@as(u32, 2), preview.effective_target.insert_at);
}

test "skipNext decline creates evacuation residue and leaves text unchanged" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.skipNext());

    try expectText("abcd", &gs);
    try testing.expectEqual(@as(usize, 2), gs.decisions.items.len);
    try testing.expectEqual(@as(usize, 1), gs.anomalies.items.len);
    try testing.expectEqualStrings("X", gs.residue.items);
    try testing.expectEqual(@as(u32, 5), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.ef_len);
}

test "skipNext rescue creates an imposition without storing duplicate bytes" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.skipNext());

    try expectText("abcd", &gs);
    try testing.expectEqual(@as(usize, 1), gs.anomalies.items.len);
    try testing.expectEqual(@as(usize, 0), gs.residue.items.len);
    try testing.expectEqual(@as(u32, 2), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.ef_len);
}

test "applyNext accepts delete and undo restores residue-backed bytes" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.applyNext(null));

    try expectText("ad", &gs);
    try testing.expectEqualStrings("bc", gs.residue.items);
    try testing.expect(try gs.undo());
    try expectText("abcd", &gs);
    try testing.expect(try gs.redo());
    try expectText("ad", &gs);
}

test "applyNext accepts insert and undo removes it" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.applyNext(null));

    try expectText("abXcd", &gs);
    try testing.expectEqualStrings("X", gs.residue.items);
    try testing.expect(try gs.undo());
    try expectText("abcd", &gs);
    try testing.expect(try gs.redo());
    try expectText("abXcd", &gs);
}

test "finishStep promotes rescued deletes into later impositions" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const first = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(first, 1);
    try testing.expect(try gs.skipNext());
    try testing.expectEqual(null, try gs.previewNext());
    try gs.finishStep();

    try testing.expectEqual(@as(u32, 2), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.ef_len);
    try expectText("abcd", &gs);

    const second = try makeOwnedZDelta(allocator, "ad", "");
    try gs.openStep(second, 2);
    const preview = (try gs.previewNext()).?;
    try testing.expectEqual(TargetClass.overlaid, preview.class);
    try testing.expectEqual(@as(usize, 1), preview.available_resolutions.len);
    try testing.expectEqual(ApplyResolution.delete_whole, preview.available_resolutions[0]);

    try testing.expect(try gs.applyNext(.delete_whole));
    try expectText("", &gs);
}

test "complex classification defers insertions adjacent to anomalous evacuations" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const first = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(first, 1);
    try testing.expect(try gs.skipNext());
    try gs.finishStep();

    const second = try makeOwnedZDelta(allocator, "abXcd", "abXYcd");
    try gs.openStep(second, 2);
    const preview = (try gs.previewNext()).?;
    try testing.expectEqual(TargetClass.complex, preview.class);
    try testing.expectEqual(EffectiveTarget.complex, preview.effective_target);
}

test "new decision after undo clears redo history" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.applyNext(null));
    try testing.expect(try gs.undo());
    try testing.expect(try gs.skipNext());
    try testing.expect(!(try gs.redo()));
}

test "previewNext marks inserts inside evacuations as stranded" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const first = try makeOwnedZDelta(allocator, "abcd", "abXYcd");
    try gs.openStep(first, 1);
    try testing.expect(try gs.skipNext());
    try gs.finishStep();

    const second = try makeOwnedZDelta(allocator, "abXYcd", "abXZYcd");
    try gs.openStep(second, 2);
    const preview = (try gs.previewNext()).?;
    try testing.expectEqual(TargetClass.stranded, preview.class);
    try testing.expectEqual(@as(u32, 2), preview.effective_target.insert_at);
    try testing.expectError(error.UnresolvedZDeltaOp, gs.applyNext(null));
    try testing.expectError(error.UnresolvedZDeltaOp, gs.skipNext());
}

test "declarative cases can inspect a fragmented mixed-insert surface" {
    const allocator = testing.allocator;
    var gs = try runDeclarativeGuidanceCase(allocator, .{
        .before = "abcdef",
        .after = "abXcdeYf",
        .decisions = &.{ .accept, .decline },
        .effective_after = "abXcdef",
    });
    defer gs.deinit();

    const regions = try collectTestRegions(allocator, gs.current_step.correction_root);
    defer allocator.free(regions);

    try testing.expectEqual(@as(u32, 7), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, 7), gs.current_step.ef_len);
    try testing.expectEqual(@as(usize, 5), regions.len);
    try testing.expectEqual(@as(usize, 4), countSpanNodes(gs.current_step.correction_root));
    try testing.expectEqual(treeExWid(gs.current_step.correction_root), gs.current_step.ex_len);
    try testing.expectEqual(treeEfWid(gs.current_step.correction_root), gs.current_step.ef_len);
    try testing.expectEqualStrings("XY", gs.residue.items);
    try testing.expectEqual(DecisionKind.insert, gs.decisions.items[1].kind());
    try testing.expectEqual(DecisionKind.decline, gs.decisions.items[2].kind());
    try testing.expectEqual(@as(u32, 2), regions[0].pristine.wid);
    try testing.expectEqual(@as(u32, 1), regions[1].imposition.ef_wid);
    try testing.expectEqual(@as(u32, 3), regions[2].pristine.wid);
    try testing.expectEqual(@as(u32, 1), regions[3].evacuation.ex_wid);
    try testing.expectEqual(@as(u32, 1), regions[4].pristine.wid);
    try testing.expect(regions[3].evacuation.anomalies != null);
}

test "declarative cases preserve distinct impositions from rescue and insert" {
    const allocator = testing.allocator;
    var gs = try runDeclarativeGuidanceCase(allocator, .{
        .before = "abcdef",
        .after = "abefX",
        .decisions = &.{ .rescue, .accept },
        .effective_after = "abcdefX",
    });
    defer gs.deinit();

    const regions = try collectTestRegions(allocator, gs.current_step.correction_root);
    defer allocator.free(regions);

    try testing.expectEqual(@as(u32, 4), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, 7), gs.current_step.ef_len);
    try testing.expectEqual(@as(usize, 4), regions.len);
    try testing.expectEqual(@as(usize, 3), countSpanNodes(gs.current_step.correction_root));
    try testing.expectEqual(@as(usize, 1), gs.anomalies.items.len);
    try testing.expectEqual(@as(usize, 1), gs.residue.items.len);
    try testing.expectEqualStrings("X", gs.residue.items);
    try testing.expectEqual(DecisionKind.rescue, gs.decisions.items[1].kind());
    try testing.expectEqual(DecisionKind.insert, gs.decisions.items[2].kind());
    try testing.expectEqual(@as(u32, 2), regions[0].pristine.wid);
    try testing.expectEqual(@as(u32, 2), regions[1].imposition.ef_wid);
    try testing.expect(regions[1].imposition.anomalies != null);
    try testing.expectEqual(@as(u32, 2), regions[2].pristine.wid);
    try testing.expectEqual(@as(u32, 1), regions[3].imposition.ef_wid);
    try testing.expectEqual(@as(?ProvenanceRef, null), regions[3].imposition.anomalies);
}

test "declarative cases build a deep sentence surface from alternating insert decisions" {
    const allocator = testing.allocator;
    const before = "The guide folds the map at dawn.";
    const after = "The patient guide carefully folds the old map at dawn today.";
    var gs = try runDeclarativeGuidanceCase(allocator, .{
        .before = before,
        .after = after,
        .decisions = &.{ .accept, .decline, .accept, .decline },
        .effective_after = "The patient guide folds the old map at dawn.",
    });
    defer gs.deinit();

    const regions = try collectTestRegions(allocator, gs.current_step.correction_root);
    defer allocator.free(regions);

    try testing.expectEqual(@as(u32, @intCast(after.len - "patient ".len - "old ".len)), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, @intCast("The patient guide folds the old map at dawn.".len)), gs.current_step.ef_len);
    try testing.expectEqual(@as(usize, 9), regions.len);
    try testing.expectEqual(@as(usize, 8), countSpanNodes(gs.current_step.correction_root));
    try testing.expectEqual(@as(usize, 2), gs.anomalies.items.len);
    try testing.expectEqual(DecisionKind.insert, gs.decisions.items[1].kind());
    try testing.expectEqual(DecisionKind.decline, gs.decisions.items[2].kind());
    try testing.expectEqual(DecisionKind.insert, gs.decisions.items[3].kind());
    try testing.expectEqual(DecisionKind.decline, gs.decisions.items[4].kind());
    try testing.expectEqual(@as(u32, @intCast("The ".len)), regions[0].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast("patient ".len)), regions[1].imposition.ef_wid);
    try testing.expectEqual(@as(u32, @intCast("guide ".len)), regions[2].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast("carefully ".len)), regions[3].evacuation.ex_wid);
    try testing.expect(regions[3].evacuation.anomalies != null);
    try testing.expectEqual(@as(u32, @intCast("folds the ".len)), regions[4].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast("old ".len)), regions[5].imposition.ef_wid);
    try testing.expectEqual(@as(u32, @intCast("map at dawn".len)), regions[6].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast(" today".len)), regions[7].evacuation.ex_wid);
    try testing.expect(regions[7].evacuation.anomalies != null);
    try testing.expectEqual(@as(u32, @intCast(".".len)), regions[8].pristine.wid);
}

test "declarative cases mix rescued and accepted sentence edits into a deeper tree" {
    const allocator = testing.allocator;
    const before = "The guide folds the small paper map before sunrise";
    var gs = try runDeclarativeGuidanceCase(allocator, .{
        .before = before,
        .after = "The guide folds the map before bright sunrise again",
        .decisions = &.{ .rescue, .accept, .accept },
        .effective_after = "The guide folds the small paper map before bright sunrise again",
    });
    defer gs.deinit();

    const regions = try collectTestRegions(allocator, gs.current_step.correction_root);
    defer allocator.free(regions);

    try testing.expectEqual(@as(u32, @intCast(before.len - "small paper ".len)), gs.current_step.ex_len);
    try testing.expectEqual(@as(u32, @intCast("The guide folds the small paper map before bright sunrise again".len)), gs.current_step.ef_len);
    try testing.expectEqual(@as(usize, 6), regions.len);
    try testing.expectEqual(@as(usize, 5), countSpanNodes(gs.current_step.correction_root));
    try testing.expectEqual(@as(usize, 1), gs.anomalies.items.len);
    try testing.expectEqual(DecisionKind.rescue, gs.decisions.items[1].kind());
    try testing.expectEqual(DecisionKind.insert, gs.decisions.items[2].kind());
    try testing.expectEqual(DecisionKind.insert, gs.decisions.items[3].kind());
    try testing.expectEqual(@as(u32, @intCast("The guide folds the ".len)), regions[0].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast("small paper ".len)), regions[1].imposition.ef_wid);
    try testing.expect(regions[1].imposition.anomalies != null);
    try testing.expectEqual(@as(u32, @intCast("map before ".len)), regions[2].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast("bright ".len)), regions[3].imposition.ef_wid);
    try testing.expectEqual(@as(?ProvenanceRef, null), regions[3].imposition.anomalies);
    try testing.expectEqual(@as(u32, @intCast("sunrise".len)), regions[4].pristine.wid);
    try testing.expectEqual(@as(u32, @intCast(" again".len)), regions[5].imposition.ef_wid);
    try testing.expectEqual(@as(?ProvenanceRef, null), regions[5].imposition.anomalies);
}

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const OOM = std.mem.Allocator.Error;
const TestError = Error || zdelta_mod.ZDeltaDecodeError || error{
    SkipZigTest,
    TestExpectedEqual,
    TestExpectedError,
    TestUnexpectedError,
    TestUnexpectedResult,
};
const apply_base = @import("apply_base.zig");
const common_apply = @import("common.zig");
const zdelta_mod = @import("../zdelta.zig");
const dmp = @import("../dmp.zig");
const common = @import("../dmp/common.zig");
const dbgassert = common.dbgassert;
const DeltaOp = common_apply.DeltaOp;
const DeltaSpan = common_apply.DeltaSpan;
const ZDelta = zdelta_mod.ZDelta;
