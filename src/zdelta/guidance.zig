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
//! - The public "correction tree" is backed internally by a normalized region
//!   slice.  We still materialize `CorrectionNode` trees for each step so the
//!   step state matches the design, but the region slice is the authoritative
//!   query surface in this commit.
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

/// Records one reviewed action taken against an attached raw delta op.
pub const DecisionRecord = union(enum) {
    insert: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        raw_op_index: u32,
        expected_at: u32,
        effective_at_before: u32,
        effective_at_after: u32,
        residue_off: u32,
        residue_len: u32,
    },
    delete: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        raw_op_index: u32,
        expected: Span,
        effective_before: Span,
        effective_after: Span,
        residue_off: u32,
        residue_len: u32,
        resolution: ?ApplyResolution,
    },
    decline: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        raw_op_index: u32,
        expected_at: u32,
        anomaly: AnomalyIndex,
    },
    rescue: struct {
        id: DecisionIndex,
        revision_ordinal: usize,
        raw_op_index: u32,
        expected: Span,
        anomaly: AnomalyIndex,
        resolution: ?ApplyResolution,
    },
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

    /// Returns the region's expected-axis start position.
    fn expectedStart(region: CorrectionRegion) u32 {
        return switch (region) {
            .pristine => |r| r.expected.start,
            .evacuation => |r| r.expected.start,
            .imposition => |r| r.expected_at,
        };
    }

    /// Returns the region's expected-axis end position.
    fn expectedEnd(region: CorrectionRegion) u32 {
        return switch (region) {
            .pristine => |r| r.expected.end,
            .evacuation => |r| r.expected.end,
            .imposition => |r| r.expected_at,
        };
    }

    /// Returns the region's effective-axis start position.
    fn effectiveStart(region: CorrectionRegion) u32 {
        return switch (region) {
            .pristine => |r| r.effective.start,
            .evacuation => |r| r.effective_at,
            .imposition => |r| r.effective.start,
        };
    }

    /// Returns the region's effective-axis end position.
    fn effectiveEnd(region: CorrectionRegion) u32 {
        return switch (region) {
            .pristine => |r| r.effective.end,
            .evacuation => |r| r.effective_at,
            .imposition => |r| r.effective.end,
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

    /// Rewrites a region so its coordinates are absolute on both axes.
    fn normalize(region: CorrectionRegion, expected_cursor: *u32, effective_cursor: *u32) CorrectionRegion {
        return switch (region) {
            .pristine => |r| pristine: {
                const start_e = expected_cursor.*;
                const start_f = effective_cursor.*;
                expected_cursor.* += r.wid;
                effective_cursor.* += r.wid;
                break :pristine .{ .pristine = .{
                    .expected = .{ .start = start_e, .end = expected_cursor.* },
                    .effective = .{ .start = start_f, .end = effective_cursor.* },
                    .wid = r.wid,
                    .decisions = r.decisions,
                } };
            },
            .evacuation => |r| .{ .evacuation = .{
                .expected = .{
                    .start = expected_cursor.*,
                    .end = expected_cursor.* + r.ex_wid,
                },
                .effective_at = effective_cursor.*,
                .ex_wid = r.ex_wid,
                .decisions = r.decisions,
                .anomalies = r.anomalies,
            } },
            .imposition => |r| imposition: {
                const start_f = effective_cursor.*;
                effective_cursor.* += r.ef_wid;
                break :imposition .{ .imposition = .{
                    .expected_at = expected_cursor.*,
                    .effective = .{ .start = start_f, .end = effective_cursor.* },
                    .ef_wid = r.ef_wid,
                    .decisions = r.decisions,
                    .anomalies = r.anomalies,
                } };
            },
        };
    }
};

/// Interval-tree node covering a contiguous portion of the correction surface.
pub const CorrectionNode = union(enum) {
    span: struct {
        ex_wid: u32,
        ef_wid: u32,
        deviation: i32,
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
    regions: []CorrectionRegion,

    effective_len: u32,
    expected_len: u32,

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

/// Review-capable delta engine owning text, history, anomalies, and provenance.
pub const DeltaGuidanceSystem = struct {
    allocator: Allocator,
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

    pub const growth_fudge: u32 = 16;

    /// Creates a guidance system from initial text and seeds the synthetic genesis step.
    pub fn initText(allocator: Allocator, text: []const u8) !DeltaGuidanceSystem {
        const text_len = try apply_base.checkedTextLen(text.len);
        const extra_slack = try apply_base.initialSlack(text.len);
        const head_room = extra_slack / 2;
        const total_len = try std.math.add(usize, text.len, extra_slack);
        var buffer = try allocator.alloc(u8, total_len);
        @memcpy(buffer[head_room..][0..text.len], text);

        var gs = DeltaGuidanceSystem{
            .allocator = allocator,
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
        errdefer gs.deinit();

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
        const regions = try gs.normalizeAndOwnRegions(&.{.{ .pristine = .{
            .expected = .{ .start = 0, .end = text_len },
            .effective = .{ .start = 0, .end = text_len },
            .wid = text_len,
            .decisions = decision_ref,
        } }});
        const root = try gs.buildTree(regions);

        const step = try allocator.create(Step);
        step.* = .{
            .prior = null,
            .next = null,
            .correction_root = root,
            .regions = regions,
            .effective_len = text_len,
            .expected_len = text_len,
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
        if (@intFromPtr(gs.current_step) != 0) {
            var head = gs.current_step;
            while (head.prior) |prior| head = prior;
            gs.freeStepChain(head);
        }
        if (gs.buffer.len != 0) gs.allocator.free(gs.buffer);
        gs.* = undefined;
    }

    /// Returns the current effective text slice from the slack buffer.
    pub fn currentText(gs: *const DeltaGuidanceSystem) []const u8 {
        return gs.buffer[gs.start..gs.end];
    }

    /// Attaches a raw delta as the next review step against the current expected text.
    pub fn openStep(gs: *DeltaGuidanceSystem, raw_delta: *ZDelta, target_revision: usize) !void {
        errdefer raw_delta.destroy(gs.allocator);
        if (gs.attached_step != null) return error.StepAlreadyOpen;
        if (gs.current_step.expected_len != raw_delta.originalBeforeLength()) return error.ZDeltaTextLengthMismatch;

        const before_len, const head_room, const tail_room = raw_delta.textNumbers();
        _ = before_len;
        const total_change = raw_delta.totalChange();
        if (total_change > 0) {
            const growth_need: u32 = @intCast(total_change);
            try gs.growForNeed(growth_need);
        }
        try gs.ensureHeadRoom(head_room);
        try gs.ensureTailRoom(tail_room);

        gs.pivot = gs.current_step.effective_len / 2;
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
    pub fn previewNext(gs: *DeltaGuidanceSystem) !?EffectiveEdit {
        const scanned = try gs.scanNextEdit() orelse return null;
        return scanned.edit;
    }

    /// Accepts the next actionable edit and advances the open step by one decision.
    pub fn applyNext(gs: *DeltaGuidanceSystem, resolution: ?ApplyResolution) !bool {
        const scanned = try gs.scanNextEdit() orelse return false;
        if (scanned.edit.class == .complex) return error.UnresolvedZDeltaOp;

        const chosen = try gs.resolveApply(&scanned.edit, resolution);
        switch (scanned.op) {
            .insert => |span| try gs.applyInsert(scanned, span, chosen),
            .delete => |len| try gs.applyDelete(scanned, len, chosen),
            .equal => unreachable,
        }
        return true;
    }

    /// Declines or rescues the next actionable edit and advances the open step.
    pub fn skipNext(gs: *DeltaGuidanceSystem) !bool {
        const scanned = try gs.scanNextEdit() orelse return false;
        if (scanned.edit.class == .complex) return error.UnresolvedZDeltaOp;

        switch (scanned.op) {
            .insert => |span| try gs.skipInsert(scanned, span),
            .delete => |len| try gs.skipDelete(scanned, len),
            .equal => unreachable,
        }
        return true;
    }

    /// Applies every remaining actionable edit in the attached delta.
    pub fn applyRest(gs: *DeltaGuidanceSystem, default_resolution: ?ApplyResolution) !usize {
        var count: usize = 0;
        while (try gs.applyNext(default_resolution)) count += 1;
        return count;
    }

    /// Skips every remaining actionable edit in the attached delta.
    pub fn skipRest(gs: *DeltaGuidanceSystem) !usize {
        var count: usize = 0;
        while (try gs.skipNext()) count += 1;
        return count;
    }

    /// Promotes the completed correction surface onto the next revision's expected axis.
    pub fn finishStep(gs: *DeltaGuidanceSystem) !void {
        const attached = gs.attached_step orelse return error.MissingZDelta;
        if (try gs.scanNextEdit()) |_| return error.UnfinishedZDelta;

        // Finish is not a reviewed decision, so the current step is mutated in
        // place.  The undo/redo path remains decision-based; finish only changes
        // which axis that last decided correction surface is keyed against.
        var promoted_builder = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer promoted_builder.deinit(gs.allocator);

        for (gs.current_step.regions) |region| {
            switch (region) {
                .pristine => |r| try promoted_builder.append(gs.allocator, .{ .pristine = .{
                    .expected = r.expected,
                    .effective = r.effective,
                    .wid = r.wid,
                    .decisions = r.decisions,
                } }),
                .evacuation => |r| {
                    if (r.anomalies != null) try promoted_builder.append(gs.allocator, .{ .evacuation = .{
                        .expected = r.expected,
                        .effective_at = r.effective_at,
                        .ex_wid = r.ex_wid,
                        .decisions = r.decisions,
                        .anomalies = r.anomalies,
                    } });
                },
                .imposition => |r| {
                    if (r.anomalies) |anoms| {
                        try promoted_builder.append(gs.allocator, .{ .imposition = .{
                            .expected_at = r.expected_at,
                            .effective = r.effective,
                            .ef_wid = r.ef_wid,
                            .decisions = r.decisions,
                            .anomalies = anoms,
                        } });
                    } else {
                        try promoted_builder.append(gs.allocator, .{ .pristine = .{
                            .expected = .{ .start = 0, .end = 0 },
                            .effective = .{ .start = 0, .end = 0 },
                            .wid = r.ef_wid,
                            .decisions = r.decisions,
                        } });
                    }
                },
            }
        }

        const new_regions = try gs.normalizeAndOwnRegions(promoted_builder.items);
        const new_root = try gs.buildTree(new_regions);
        gs.freeTree(gs.current_step.correction_root);
        gs.allocator.free(gs.current_step.regions);
        gs.current_step.correction_root = new_root;
        gs.current_step.regions = new_regions;
        gs.current_step.expected_len = computeExpectedLen(new_regions);
        gs.current_step.effective_len = computeEffectiveLen(new_regions);
        gs.current_step.raw_index_next = 0;
        gs.current_step.expected_cursor_next = 0;

        attached.raw_delta.destroy(gs.allocator);
        gs.attached_step = null;
        gs.pivot = gs.current_step.effective_len / 2;
    }

    /// Moves back one decided step and restores buffer contents plus preview cursor state.
    pub fn undo(gs: *DeltaGuidanceSystem) !bool {
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
    pub fn redo(gs: *DeltaGuidanceSystem) !bool {
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
    fn growForNeed(gs: *DeltaGuidanceSystem, need: u32) !void {
        try apply_base.growForNeed(gs, growth_fudge, need);
    }

    /// Ensures there is enough slack before the text for a front-biased edit.
    fn ensureHeadRoom(gs: *DeltaGuidanceSystem, need: u32) !void {
        try apply_base.ensureHeadRoom(gs, growth_fudge, need);
    }

    /// Ensures there is enough slack after the text for a tail-biased edit.
    fn ensureTailRoom(gs: *DeltaGuidanceSystem, need: u32) !void {
        try apply_base.ensureTailRoom(gs, growth_fudge, need);
    }

    /// Inserts bytes into the effective buffer at the requested effective offset.
    fn insert(gs: *DeltaGuidanceSystem, at: u32, new_text: []const u8) !void {
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
    fn scanNextEdit(gs: *DeltaGuidanceSystem) !?ScannedEdit {
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
    fn previewInsert(gs: *DeltaGuidanceSystem, raw_index: u32, expected_at: u32, insert_len: u32) !EffectiveEdit {
        _ = insert_len;
        gs.preview_anomalies.clearRetainingCapacity();

        const state = gs.boundaryState(expected_at);
        if (state.inside_anomalous_evacuation) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .insert_at = expected_at },
                .effective_target = .complex,
                .class = .complex,
                .touched_anomalies = .{ .off = 0, .len = 0 },
                .available_resolutions = no_resolutions[0..],
            };
        }
        if (state.has_imposition_here or state.has_anomalous_neighbor) {
            return .{
                .raw_op_index = raw_index,
                .expected_target = .{ .insert_at = expected_at },
                .effective_target = .complex,
                .class = .complex,
                .touched_anomalies = .{ .off = 0, .len = 0 },
                .available_resolutions = no_resolutions[0..],
            };
        }

        return .{
            .raw_op_index = raw_index,
            .expected_target = .{ .insert_at = expected_at },
            .effective_target = .{ .insert_at = try gs.effectiveInsertPoint(expected_at) },
            .class = .pure,
            .touched_anomalies = .{ .off = 0, .len = 0 },
            .available_resolutions = no_resolutions[0..],
        };
    }

    /// Classifies a deletion against the current correction surface.
    fn previewDelete(gs: *DeltaGuidanceSystem, raw_index: u32, expected_start: u32, len: u32) !EffectiveEdit {
        gs.preview_anomalies.clearRetainingCapacity();

        const expected = Span{ .start = expected_start, .end = expected_start + len };
        var touching = try gs.collectTouchedRegions(expected);
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

        for (touching.items) |idx| {
            const region = gs.current_step.regions[idx];
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
    fn resolveApply(gs: *DeltaGuidanceSystem, edit: *const EffectiveEdit, resolution: ?ApplyResolution) !?ApplyResolution {
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
    fn applyInsert(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, span: DeltaSpan, resolution: ?ApplyResolution) !void {
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
        const split = try gs.splitRegionsAtExpected(gs.current_step.regions, scanned.expected_cursor);
        defer gs.allocator.free(split);

        var builder = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer builder.deinit(gs.allocator);

        var inserted = false;
        for (split) |region| {
            if (!inserted) {
                switch (region) {
                    .imposition => |r| {
                        if (r.expected_at == scanned.expected_cursor) {
                            try builder.append(gs.allocator, region);
                            continue;
                        }
                    },
                    else => {},
                }
                if (region.expectedStart() >= scanned.expected_cursor) {
                    try builder.append(gs.allocator, .{ .imposition = .{
                        .expected_at = scanned.expected_cursor,
                        .effective = .{ .start = 0, .end = 0 },
                        .ef_wid = span.len,
                        .decisions = decision_ref,
                        .anomalies = null,
                    } });
                    inserted = true;
                }
            }
            try builder.append(gs.allocator, region);
        }
        if (!inserted) try builder.append(gs.allocator, .{ .imposition = .{
            .expected_at = scanned.expected_cursor,
            .effective = .{ .start = 0, .end = 0 },
            .ef_wid = span.len,
            .decisions = decision_ref,
            .anomalies = null,
        } });

        try gs.commitNewStep(builder.items, decision, null, scanned.raw_index + 1, scanned.expected_cursor);
    }

    /// Declines a raw insert, recording an evacuation anomaly without changing text.
    fn skipInsert(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, span: DeltaSpan) !void {
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
        const split = try gs.splitRegionsAtExpected(gs.current_step.regions, scanned.expected_cursor);
        defer gs.allocator.free(split);

        var builder = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer builder.deinit(gs.allocator);

        var inserted = false;
        for (split) |region| {
            if (!inserted) {
                switch (region) {
                    .imposition => |r| {
                        if (r.expected_at == scanned.expected_cursor) {
                            try builder.append(gs.allocator, region);
                            continue;
                        }
                    },
                    else => {},
                }
                if (region.expectedStart() >= scanned.expected_cursor) {
                    try builder.append(gs.allocator, .{ .evacuation = .{
                        .expected = .{ .start = 0, .end = 0 },
                        .effective_at = 0,
                        .ex_wid = span.len,
                        .decisions = decision_ref,
                        .anomalies = anomaly_ref,
                    } });
                    inserted = true;
                }
            }
            try builder.append(gs.allocator, region);
        }
        if (!inserted) try builder.append(gs.allocator, .{ .evacuation = .{
            .expected = .{ .start = 0, .end = 0 },
            .effective_at = 0,
            .ex_wid = span.len,
            .decisions = decision_ref,
            .anomalies = anomaly_ref,
        } });

        try gs.commitNewStep(builder.items, decision, anomaly, scanned.raw_index + 1, scanned.expected_cursor + span.len);
    }

    /// Accepts a raw delete, storing removed bytes in residue for undo.
    fn applyDelete(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, len: u32, resolution: ?ApplyResolution) !void {
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

        const split_once = try gs.splitRegionsAtExpected(gs.current_step.regions, expected.start);
        defer gs.allocator.free(split_once);
        const split = try gs.splitRegionsAtExpected(split_once, expected.end);
        defer gs.allocator.free(split);
        const decision_ref = try gs.appendDecisionProvenance(&.{decision});

        var builder = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer builder.deinit(gs.allocator);

        for (split) |region| {
            if (!expectedSpansOverlap(region, expected)) {
                if (!isImpositionInside(region, expected)) try builder.append(gs.allocator, region);
                continue;
            }
            switch (region) {
                .pristine => |r| try builder.append(gs.allocator, .{ .evacuation = .{
                    .expected = .{ .start = 0, .end = 0 },
                    .effective_at = 0,
                    .ex_wid = r.wid,
                    .decisions = try gs.combineDecisionRefs(r.decisions, decision),
                    .anomalies = null,
                } }),
                .evacuation => |r| try builder.append(gs.allocator, .{ .evacuation = .{
                    .expected = .{ .start = 0, .end = 0 },
                    .effective_at = 0,
                    .ex_wid = r.ex_wid,
                    .decisions = try gs.combineDecisionRefs(r.decisions, decision),
                    .anomalies = r.anomalies,
                } }),
                .imposition => |r| {
                    if (resolution == .delete_whole and r.anomalies != null and r.expected_at >= expected.start and r.expected_at < expected.end) {
                        // Drop the imposed text entirely.
                    } else {
                        try builder.append(gs.allocator, region);
                    }
                },
            }
        }

        try gs.commitNewStep(builder.items, decision, null, scanned.raw_index + 1, scanned.expected_cursor + len);
        _ = decision_ref;
    }

    /// Rescues a raw delete, preserving the effective text as an imposition anomaly.
    fn skipDelete(gs: *DeltaGuidanceSystem, scanned: ScannedEdit, len: u32) !void {
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
        const split_once = try gs.splitRegionsAtExpected(gs.current_step.regions, expected.start);
        defer gs.allocator.free(split_once);
        const split = try gs.splitRegionsAtExpected(split_once, expected.end);
        defer gs.allocator.free(split);

        var builder = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer builder.deinit(gs.allocator);

        var inserted = false;
        for (split) |region| {
            if (expectedSpansOverlap(region, expected)) {
                switch (region) {
                    .pristine => {},
                    else => return error.UnresolvedZDeltaOp,
                }
                if (!inserted) {
                    try builder.append(gs.allocator, .{ .imposition = .{
                        .expected_at = expected.start,
                        .effective = .{ .start = 0, .end = 0 },
                        .ef_wid = len,
                        .decisions = decision_ref,
                        .anomalies = anomaly_ref,
                    } });
                    inserted = true;
                }
                continue;
            }
            if (!inserted and region.expectedStart() >= expected.end) {
                try builder.append(gs.allocator, .{ .imposition = .{
                    .expected_at = expected.start,
                    .effective = .{ .start = 0, .end = 0 },
                    .ef_wid = len,
                    .decisions = decision_ref,
                    .anomalies = anomaly_ref,
                } });
                inserted = true;
            }
            try builder.append(gs.allocator, region);
        }
        if (!inserted) try builder.append(gs.allocator, .{ .imposition = .{
            .expected_at = expected.start,
            .effective = .{ .start = 0, .end = 0 },
            .ef_wid = len,
            .decisions = decision_ref,
            .anomalies = anomaly_ref,
        } });

        try gs.commitNewStep(builder.items, decision, anomaly, scanned.raw_index + 1, scanned.expected_cursor);
    }

    /// Normalizes newly built regions, snapshots the next cursor, and advances history.
    fn commitNewStep(
        gs: *DeltaGuidanceSystem,
        raw_regions: []const CorrectionRegion,
        decision: DecisionIndex,
        anomaly: ?AnomalyIndex,
        raw_index_next: u32,
        expected_cursor_next: u32,
    ) !void {
        if (gs.current_step.next) |future| gs.freeFutureFrom(future);
        gs.current_step.next = null;

        const regions = try gs.normalizeAndOwnRegions(raw_regions);
        const root = try gs.buildTree(regions);
        const step = try gs.allocator.create(Step);
        step.* = .{
            .prior = gs.current_step,
            .next = null,
            .correction_root = root,
            .regions = regions,
            .effective_len = computeEffectiveLen(regions),
            .expected_len = computeExpectedLen(regions),
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

    /// Reverses the text effects of a single recorded decision.
    fn undoDecision(gs: *DeltaGuidanceSystem, decision: DecisionIndex) !void {
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
    fn redoDecision(gs: *DeltaGuidanceSystem, decision: DecisionIndex) !void {
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
    fn deltaInsertText(gs: *const DeltaGuidanceSystem, span: DeltaSpan) ![]const u8 {
        const attached = gs.attached_step orelse return error.MissingZDelta;
        return attached.raw_delta.insert_text[span.offset..][0..span.len];
    }

    /// Appends a decision record and returns its stable global id.
    fn appendDecision(gs: *DeltaGuidanceSystem, record: DecisionRecord) !DecisionIndex {
        try gs.decisions.append(gs.allocator, record);
        return decisionIndex(gs.decisions.items.len - 1);
    }

    /// Appends an anomaly record and returns its stable global id.
    fn appendAnomaly(gs: *DeltaGuidanceSystem, record: AnomalyRecord) !AnomalyIndex {
        try gs.anomalies.append(gs.allocator, record);
        return anomalyIndex(gs.anomalies.items.len - 1);
    }

    /// Copies undo-relevant bytes into the shared residue store.
    fn appendResidue(gs: *DeltaGuidanceSystem, bytes: []const u8) !ProvenanceRef {
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
    fn appendDecisionProvenance(gs: *DeltaGuidanceSystem, values: []const DecisionIndex) !ProvenanceRef {
        const off = try checkedU32(gs.decision_provenance.items.len);
        try gs.decision_provenance.appendSlice(gs.allocator, values);
        return .{ .off = off, .len = try checkedU32(values.len) };
    }

    /// Appends anomaly ids to the provenance side table and returns their range.
    fn appendAnomalyProvenance(gs: *DeltaGuidanceSystem, values: []const AnomalyIndex) !ProvenanceRef {
        const off = try checkedU32(gs.anomaly_provenance.items.len);
        try gs.anomaly_provenance.appendSlice(gs.allocator, values);
        return .{ .off = off, .len = try checkedU32(values.len) };
    }

    /// Extends an existing decision provenance range with one additional decision id.
    fn combineDecisionRefs(gs: *DeltaGuidanceSystem, base: ProvenanceRef, extra: DecisionIndex) !ProvenanceRef {
        const start: usize = base.off;
        const len: usize = base.len;
        var scratch = std.ArrayListUnmanaged(DecisionIndex).empty;
        defer scratch.deinit(gs.allocator);
        try scratch.appendSlice(gs.allocator, gs.decision_provenance.items[start..][0..len]);
        try scratch.append(gs.allocator, extra);
        return gs.appendDecisionProvenance(scratch.items);
    }

    /// Copies anomaly ids into preview scratch space for the current classification result.
    fn appendPreviewAnomalies(gs: *DeltaGuidanceSystem, ref: ProvenanceRef) !void {
        const start: usize = ref.off;
        const len: usize = ref.len;
        try gs.preview_anomalies.appendSlice(gs.allocator, gs.anomaly_provenance.items[start..][0..len]);
    }

    /// Converts builder-style regions into absolute coordinates owned by a new step.
    fn normalizeAndOwnRegions(gs: *DeltaGuidanceSystem, raw_regions: []const CorrectionRegion) ![]CorrectionRegion {
        var normalized = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer normalized.deinit(gs.allocator);

        var expected_cursor: u32 = 0;
        var effective_cursor: u32 = 0;
        if (raw_regions.len == 0) {
            const empty_decisions = try gs.appendDecisionProvenance(&.{});
            try normalized.append(gs.allocator, .{ .pristine = .{
                .expected = .{ .start = 0, .end = 0 },
                .effective = .{ .start = 0, .end = 0 },
                .wid = 0,
                .decisions = empty_decisions,
            } });
        } else {
            try normalized.ensureTotalCapacity(gs.allocator, raw_regions.len);
            for (raw_regions) |region| {
                const normalized_region = region.normalize(&expected_cursor, &effective_cursor);
                switch (normalized_region) {
                    .evacuation => expected_cursor += normalized_region.exWid(),
                    .imposition => {},
                    .pristine => {},
                }
                normalized.appendAssumeCapacity(normalized_region);
            }
        }
        return try normalized.toOwnedSlice(gs.allocator);
    }

    /// Materializes the public correction tree from a normalized region slice.
    fn buildTree(gs: *DeltaGuidanceSystem, regions: []const CorrectionRegion) !*CorrectionNode {
        return gs.buildTreeRange(regions, 0, regions.len);
    }

    /// Builds one balanced tree node covering a contiguous subrange of regions.
    fn buildTreeRange(gs: *DeltaGuidanceSystem, regions: []const CorrectionRegion, start: usize, end: usize) !*CorrectionNode {
        dbgassert(start < end);
        const node = try gs.allocator.create(CorrectionNode);
        if (end - start == 1) {
            node.* = .{ .region = regions[start] };
            return node;
        }
        const mid = start + (end - start) / 2;
        const left = try gs.buildTreeRange(regions, start, mid);
        errdefer gs.freeTree(left);
        const right = try gs.buildTreeRange(regions, mid, end);
        errdefer gs.freeTree(right);
        node.* = .{ .span = .{
            .ex_wid = treeExWid(left),
            .ef_wid = treeEfWid(left),
            .deviation = @as(i32, @intCast(treeEfWid(left))) - @as(i32, @intCast(treeExWid(left))),
            .pivot = treeEfWid(left),
            .left = left,
            .right = right,
        } };
        return node;
    }

    /// Recursively frees a correction tree.
    fn freeTree(gs: *DeltaGuidanceSystem, node: *CorrectionNode) void {
        switch (node.*) {
            .span => |span| {
                gs.freeTree(span.left);
                gs.freeTree(span.right);
            },
            .region => {},
        }
        gs.allocator.destroy(node);
    }

    /// Frees a linked run of steps together with each step's owned tree and regions.
    fn freeStepChain(gs: *DeltaGuidanceSystem, step: *Step) void {
        var cursor: ?*Step = step;
        while (cursor) |current| {
            const next = current.next;
            gs.freeTree(current.correction_root);
            gs.allocator.free(current.regions);
            gs.allocator.destroy(current);
            cursor = next;
        }
    }

    /// Frees redo history starting from the given future step.
    fn freeFutureFrom(gs: *DeltaGuidanceSystem, step: *Step) void {
        gs.freeStepChain(step);
    }

    /// Splits any expected-spanning regions that straddle the requested expected point.
    fn splitRegionsAtExpected(gs: *DeltaGuidanceSystem, regions: []const CorrectionRegion, point: u32) ![]CorrectionRegion {
        var out = std.ArrayListUnmanaged(CorrectionRegion).empty;
        defer out.deinit(gs.allocator);

        for (regions) |region| {
            switch (region) {
                .pristine => |r| {
                    if (point <= r.expected.start or point >= r.expected.end) {
                        try out.append(gs.allocator, region);
                    } else {
                        const left_wid = point - r.expected.start;
                        const right_wid = r.expected.end - point;
                        try out.append(gs.allocator, .{ .pristine = .{
                            .expected = .{ .start = r.expected.start, .end = point },
                            .effective = .{ .start = r.effective.start, .end = r.effective.start + left_wid },
                            .wid = left_wid,
                            .decisions = r.decisions,
                        } });
                        try out.append(gs.allocator, .{ .pristine = .{
                            .expected = .{ .start = point, .end = r.expected.end },
                            .effective = .{ .start = r.effective.end - right_wid, .end = r.effective.end },
                            .wid = right_wid,
                            .decisions = r.decisions,
                        } });
                    }
                },
                .evacuation => |r| {
                    if (point <= r.expected.start or point >= r.expected.end) {
                        try out.append(gs.allocator, region);
                    } else {
                        try out.append(gs.allocator, .{ .evacuation = .{
                            .expected = .{ .start = r.expected.start, .end = point },
                            .effective_at = r.effective_at,
                            .ex_wid = point - r.expected.start,
                            .decisions = r.decisions,
                            .anomalies = r.anomalies,
                        } });
                        try out.append(gs.allocator, .{ .evacuation = .{
                            .expected = .{ .start = point, .end = r.expected.end },
                            .effective_at = r.effective_at,
                            .ex_wid = r.expected.end - point,
                            .decisions = r.decisions,
                            .anomalies = r.anomalies,
                        } });
                    }
                },
                .imposition => try out.append(gs.allocator, region),
            }
        }

        return try out.toOwnedSlice(gs.allocator);
    }

    /// Returns indices of regions touched by an expected-axis delete target.
    fn collectTouchedRegions(gs: *DeltaGuidanceSystem, expected: Span) !std.ArrayListUnmanaged(usize) {
        var out = std.ArrayListUnmanaged(usize).empty;
        for (gs.current_step.regions, 0..) |region, idx| {
            if (expectedSpansOverlap(region, expected) or isImpositionInside(region, expected)) {
                try out.append(gs.allocator, idx);
            }
        }
        return out;
    }

    /// Reports whether an expected point lies strictly inside an anomalous evacuation.
    fn insideAnomalousEvacuation(gs: *const DeltaGuidanceSystem, point: u32) bool {
        for (gs.current_step.regions) |region| {
            switch (region) {
                .evacuation => |r| {
                    if (r.anomalies != null and point > r.expected.start and point < r.expected.end) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Summarizes anomaly and imposition state around an expected insertion boundary.
    fn boundaryState(gs: *const DeltaGuidanceSystem, point: u32) BoundaryState {
        var state = BoundaryState{};
        for (gs.current_step.regions) |region| {
            switch (region) {
                .evacuation => |r| {
                    if (r.anomalies != null and point > r.expected.start and point < r.expected.end) state.inside_anomalous_evacuation = true;
                    if (r.anomalies != null and (point == r.expected.start or point == r.expected.end)) state.has_anomalous_neighbor = true;
                },
                .imposition => |r| {
                    if (r.expected_at == point) {
                        state.has_imposition_here = true;
                        if (r.anomalies != null) state.has_anomalous_neighbor = true;
                    }
                },
                else => {},
            }
        }
        return state;
    }

    /// Maps an expected insertion point onto the effective axis.
    fn effectiveInsertPoint(gs: *const DeltaGuidanceSystem, point: u32) !u32 {
        var fallback: ?u32 = null;
        var after_impositions: ?u32 = null;
        for (gs.current_step.regions) |region| {
            switch (region) {
                .pristine => |r| {
                    if (point >= r.expected.start and point <= r.expected.end) {
                        return r.effective.start + (point - r.expected.start);
                    }
                    if (point < r.expected.start and fallback == null) fallback = r.effective.start;
                },
                .evacuation => |r| {
                    if (point >= r.expected.start and point <= r.expected.end) return r.effective_at;
                    if (point < r.expected.start and fallback == null) fallback = r.effective_at;
                },
                .imposition => |r| {
                    if (r.expected_at == point) after_impositions = r.effective.end;
                    if (r.expected_at > point and fallback == null) fallback = r.effective.start;
                },
            }
        }
        return after_impositions orelse fallback orelse gs.current_step.effective_len;
    }

    /// Maps an expected delete boundary onto the effective axis.
    fn effectiveDeleteBoundary(gs: *const DeltaGuidanceSystem, point: u32) !u32 {
        var fallback: ?u32 = null;
        for (gs.current_step.regions) |region| {
            switch (region) {
                .pristine => |r| {
                    if (point >= r.expected.start and point <= r.expected.end) {
                        return r.effective.start + (point - r.expected.start);
                    }
                    if (point < r.expected.start and fallback == null) fallback = r.effective.start;
                },
                .evacuation => |r| {
                    if (point >= r.expected.start and point <= r.expected.end) return r.effective_at;
                    if (point < r.expected.start and fallback == null) fallback = r.effective_at;
                },
                .imposition => |r| {
                    if (r.expected_at == point) return r.effective.start;
                    if (r.expected_at > point and fallback == null) fallback = r.effective.start;
                },
            }
        }
        return fallback orelse gs.current_step.effective_len;
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

const no_resolutions = [_]ApplyResolution{};
const delete_whole_only = [_]ApplyResolution{.delete_whole};

/// Reports whether a region with expected width overlaps the given expected span.
fn expectedSpansOverlap(region: CorrectionRegion, expected: Span) bool {
    return switch (region) {
        .pristine, .evacuation => region.expectedStart() < expected.end and expected.start < region.expectedEnd(),
        .imposition => false,
    };
}

/// Reports whether an imposition anchor falls inside the given expected span.
fn isImpositionInside(region: CorrectionRegion, expected: Span) bool {
    return switch (region) {
        .imposition => |r| r.expected_at >= expected.start and r.expected_at < expected.end,
        else => false,
    };
}

/// Sums expected-axis width across a normalized region slice.
fn computeExpectedLen(regions: []const CorrectionRegion) u32 {
    var len: u32 = 0;
    for (regions) |region| len += region.exWid();
    return len;
}

/// Sums effective-axis width across a normalized region slice.
fn computeEffectiveLen(regions: []const CorrectionRegion) u32 {
    var len: u32 = 0;
    for (regions) |region| len += region.efWid();
    return len;
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
        .span => |span| span.ef_wid + treeEfWid(span.right),
        .region => |region| region.efWid(),
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
fn checkedU32(value: usize) !u32 {
    return zdelta_mod.checkedU32(value);
}

/// Adds two u32 values using the shared zdelta checked addition helper.
fn addU32(a: u32, b: u32) !u32 {
    return zdelta_mod.addU32(a, b);
}

/// Test helper asserting the current effective text.
fn expectText(expected: []const u8, gs: *const DeltaGuidanceSystem) !void {
    try testing.expectEqualStrings(expected, gs.currentText());
}

/// Test helper that diffs two texts and decodes the result into an owned `ZDelta`.
fn makeOwnedZDelta(allocator: Allocator, before: []const u8, after: []const u8) !*ZDelta {
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

//| Test

/// Runs the non-`test` guidance checks from the root `zdelta.zig` test surface.
pub fn runRuntimeChecks() !void {
    try guidanceInitGenesis();
    try guidancePreviewPureInsert();
    try guidanceDeclineInsert();
    try guidanceRescueDelete();
    try guidanceAcceptDeleteUndoRedo();
    try guidanceFinishRescueThenDeleteWhole();
    try guidanceUndoClearsRedo();
}

/// Verifies genesis-step setup for a freshly initialized guidance system.
fn guidanceInitGenesis() !void {
    var gs = try DeltaGuidanceSystem.initText(testing.allocator, "abcd");
    defer gs.deinit();

    try testing.expectEqual(@as(usize, 1), gs.decisions.items.len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.expected_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.effective_len);
    try expectText("abcd", &gs);
}

/// Verifies pure insertion preview on an untouched pristine surface.
fn guidancePreviewPureInsert() !void {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(zdelta, 1);
    const preview = (try gs.previewNext()).?;
    try testing.expectEqual(TargetClass.pure, preview.class);
    try testing.expectEqual(@as(u32, 2), preview.expected_target.insert_at);
    try testing.expectEqual(@as(u32, 2), preview.effective_target.insert_at);
}

/// Verifies that declining an insert creates evacuation residue without text mutation.
fn guidanceDeclineInsert() !void {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "abXcd");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.skipNext());
    try expectText("abcd", &gs);
    try testing.expectEqualStrings("X", gs.residue.items);
    try testing.expectEqual(@as(u32, 5), gs.current_step.expected_len);
}

/// Verifies that rescuing a delete creates an imposition anomaly without residue bytes.
fn guidanceRescueDelete() !void {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.skipNext());
    try expectText("abcd", &gs);
    try testing.expectEqual(@as(usize, 0), gs.residue.items.len);
    try testing.expectEqual(@as(u32, 2), gs.current_step.expected_len);
}

/// Verifies accepted-delete residue storage together with undo and redo.
fn guidanceAcceptDeleteUndoRedo() !void {
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

/// Verifies finish-step promotion and later `delete_whole` over an imposition.
fn guidanceFinishRescueThenDeleteWhole() !void {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const first = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(first, 1);
    try testing.expect(try gs.skipNext());
    try testing.expectEqual(null, try gs.previewNext());
    try gs.finishStep();

    const second = try makeOwnedZDelta(allocator, "ad", "");
    try gs.openStep(second, 2);
    const preview = (try gs.previewNext()).?;
    try testing.expectEqual(TargetClass.overlaid, preview.class);
    try testing.expectEqual(@as(usize, 1), preview.available_resolutions.len);
    try testing.expectEqual(ApplyResolution.delete_whole, preview.available_resolutions[0]);
    try testing.expect(try gs.applyNext(.delete_whole));
    try expectText("", &gs);
}

/// Verifies that making a new decision after undo clears the redo branch.
fn guidanceUndoClearsRedo() !void {
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

test "DeltaGuidanceSystem initText creates a synthetic genesis step" {
    try guidanceInitGenesis();
}

test "DeltaGuidanceSystem openStep rejects expected-length mismatch and duplicate opens" {
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

test "DeltaGuidanceSystem previewNext skips equals and previews a pure insert" {
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

test "DeltaGuidanceSystem skipNext decline creates evacuation residue and leaves text unchanged" {
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
    try testing.expectEqual(@as(u32, 5), gs.current_step.expected_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.effective_len);
}

test "DeltaGuidanceSystem skipNext rescue creates an imposition without storing duplicate bytes" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const zdelta = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(zdelta, 1);
    try testing.expect(try gs.skipNext());

    try expectText("abcd", &gs);
    try testing.expectEqual(@as(usize, 1), gs.anomalies.items.len);
    try testing.expectEqual(@as(usize, 0), gs.residue.items.len);
    try testing.expectEqual(@as(u32, 2), gs.current_step.expected_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.effective_len);
}

test "DeltaGuidanceSystem applyNext accepts delete and undo restores residue-backed bytes" {
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

test "DeltaGuidanceSystem applyNext accepts insert and undo removes it" {
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

test "DeltaGuidanceSystem finishStep promotes rescued deletes into later impositions" {
    const allocator = testing.allocator;
    var gs = try DeltaGuidanceSystem.initText(allocator, "abcd");
    defer gs.deinit();

    const first = try makeOwnedZDelta(allocator, "abcd", "ad");
    try gs.openStep(first, 1);
    try testing.expect(try gs.skipNext());
    try testing.expectEqual(null, try gs.previewNext());
    try gs.finishStep();

    try testing.expectEqual(@as(u32, 2), gs.current_step.expected_len);
    try testing.expectEqual(@as(u32, 4), gs.current_step.effective_len);
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

test "DeltaGuidanceSystem complex classification defers insertions adjacent to anomalous evacuations" {
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

test "DeltaGuidanceSystem new decision after undo clears redo history" {
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

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const apply_base = @import("apply_base.zig");
const common_apply = @import("common.zig");
const zdelta_mod = @import("../zdelta.zig");
const dmp = @import("../dmp.zig");
const common = @import("../dmp/common.zig");
const dbgassert = common.dbgassert;
const DeltaOp = common_apply.DeltaOp;
const DeltaSpan = common_apply.DeltaSpan;
const ZDelta = zdelta_mod.ZDelta;
