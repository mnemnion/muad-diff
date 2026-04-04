//! Partial-application driver with skip-history harmonization.
//!
//! `DeltaManager` shares the same slack-buffer storage rules as
//! `DeltaApplicator`, but it layers review-time policy on top of them.
//! Skipped operations remain as history, incoming deltas are rewritten against
//! that history, and blocked markers preserve places where the operator's past
//! choices make a later mutation impossible to apply blindly.

pub const DeltaManager = struct {
    allocator: Allocator,
    zdelta: ?*ZDelta,
    buffer: []u8,
    start: u32,
    end: u32,
    pivot: u32,
    budget: u32,
    t_idx: u32,
    z_idx: u32,
    // Skip history is not just a transcript artifact. It is the materialized
    // divergence between the reviewed text and the corpus baseline, and later
    // deltas must be harmonized against it before they can be trusted.
    skipped: std.ArrayListUnmanaged(SkippedDeltaOp),

    pub const growth_fudge: u32 = 16;

    pub fn init(allocator: Allocator, before: []const u8, zdelta: *ZDelta) !DeltaManager {
        errdefer zdelta.destroy(allocator);
        const before_len, const head_room, const tail_room = zdelta.textNumbers();
        if (before.len != before_len) return error.ZDeltaTextLengthMismatch;
        const midpoint = before_len / 2;
        const total_len: usize = before.len + head_room + tail_room;
        var text = try allocator.alloc(u8, total_len);
        @memcpy(text[head_room..][0..before.len], before);
        return .{
            .allocator = allocator,
            .buffer = text,
            .start = head_room,
            .end = head_room + before_len,
            .pivot = midpoint,
            .budget = head_room + tail_room,
            .zdelta = zdelta,
            .t_idx = 0,
            .z_idx = 0,
            .skipped = .empty,
        };
    }

    pub fn initText(allocator: Allocator, text: []const u8) !DeltaManager {
        const text_len = try apply_base.checkedTextLen(text.len);
        const extra_slack = try apply_base.initialSlack(text.len);
        const head_room = extra_slack / 2;
        const total_len = try std.math.add(usize, text.len, extra_slack);
        var buffer = try allocator.alloc(u8, total_len);
        @memcpy(buffer[head_room..][0..text.len], text);
        return .{
            .allocator = allocator,
            .zdelta = null,
            .buffer = buffer,
            .start = try checkedU32(head_room),
            .end = try addU32(try checkedU32(head_room), text_len),
            .pivot = text_len / 2,
            .budget = try checkedU32(extra_slack),
            .t_idx = 0,
            .z_idx = 0,
            .skipped = .empty,
        };
    }

    pub fn addDelta(tm: *DeltaManager, zdelta: *ZDelta) !void {
        if (tm.zdelta) |old_zdelta| {
            if (tm.z_idx < old_zdelta.ops.len) return error.NewDeltaRefusedOldDeltaNotFullyApplied;
            old_zdelta.destroy(tm.allocator);
        }
        tm.zdelta = zdelta;
        tm.z_idx = 0;
        tm.t_idx = 0;
        const original_before_len = zdelta.originalBeforeLength();

        for (tm.skipped.items) |*skipped| skipped.accounted_for_current_delta = false;
        try tm.harmonizeCurrentDelta();
        if (tm.equivalentLen() != original_before_len) return error.ZDeltaTextLengthMismatch;
        const before_len, const head_room, const tail_room = zdelta.textNumbers();
        if (tm.textLen() != before_len) return error.ZDeltaTextLengthMismatch;

        const total_change = zdelta.totalChange();
        if (total_change > 0) {
            const growth_need: u32 = @intCast(total_change);
            try tm.growForNeed(growth_need);
        }
        try tm.ensureHeadRoom(head_room);
        try tm.ensureTailRoom(tail_room);

        tm.pivot = before_len / 2;
        dbgassert(tm.t_idx == 0);
        dbgassert(tm.z_idx == 0);
    }

    pub fn deinit(tm: *DeltaManager) void {
        for (tm.skipped.items) |*skipped| skipped.deinit(tm.allocator);
        tm.skipped.deinit(tm.allocator);
        if (tm.zdelta) |zdelta| zdelta.destroy(tm.allocator);
        tm.allocator.free(tm.buffer);
        tm.* = undefined;
    }

    pub fn view(tm: *const DeltaManager) []const u8 {
        return tm.buffer[tm.start..tm.end];
    }

    pub fn skippedItems(tm: *const DeltaManager) []const SkippedDeltaOp {
        return tm.skipped.items;
    }

    pub fn previewNext(tm: *const DeltaManager) !?PreviewDeltaOp {
        const zdelta = tm.zdelta orelse return error.MissingZDelta;
        var t_idx = tm.t_idx;
        var z_idx = tm.z_idx;
        while (z_idx < zdelta.ops.len) {
            const op = zdelta.ops[z_idx];
            if (op.state == .blocked or op.effective != .equal) {
                return .{
                    .text_index = t_idx,
                    .delta_index = z_idx,
                    .op = op,
                };
            }
            t_idx += op.effective.equal;
            z_idx += 1;
        }
        return null;
    }

    pub fn move(tm: *DeltaManager) ![]u8 {
        if (tm.zdelta) |zdelta| {
            if (tm.z_idx < zdelta.ops.len) return error.UnfinishedZDelta;
        }
        const text_len = tm.end - tm.start;
        @memmove(tm.buffer[0..text_len], tm.buffer[tm.start..][0..text_len]);
        const text = try tm.allocator.realloc(tm.buffer, text_len);
        tm.buffer = &.{};
        if (tm.zdelta) |zdelta| zdelta.destroy(tm.allocator);
        tm.zdelta = null;
        return text;
    }

    pub fn applyAll(tm: *DeltaManager) !void {
        while (try tm.applyNext()) |_| {}
    }

    pub fn applyNext(tm: *DeltaManager) !?void {
        const analyzed = (try tm.advanceToHarmonizedMutation()) orelse return null;
        if (analyzed.state == .blocked) return error.UnresolvedZDeltaOp;
        switch (analyzed.effective) {
            .delete => |len| {
                tm.delete(tm.t_idx, len);
                tm.z_idx += 1;
                return;
            },
            .insert => |span| {
                try tm.insert(tm.t_idx, try tm.deltaInsertText(span));
                tm.t_idx += span.len;
                tm.z_idx += 1;
                return;
            },
            .equal => unreachable,
        }
    }

    pub fn skipNext(tm: *DeltaManager) !?void {
        const analyzed = (try tm.advanceToHarmonizedMutation()) orelse return null;
        if (analyzed.state == .blocked) return error.UnresolvedZDeltaOp;
        var skipped = try tm.captureSkippedOp(analyzed.effective);
        errdefer skipped.deinit(tm.allocator);
        try tm.skipped.append(tm.allocator, skipped);

        switch (analyzed.effective) {
            .insert => |span| try tm.rewriteTailAfterSkippedInsert(span.len),
            .delete => |len| try tm.rewriteTailAfterSkippedDelete(len),
            .equal => unreachable,
        }
    }

    fn rebase(tm: *DeltaManager, new_start: u32) void {
        apply_base.rebase(tm, new_start);
    }

    fn growForNeed(tm: *DeltaManager, need: u32) !void {
        try apply_base.growForNeed(tm, growth_fudge, need);
    }

    fn ensureHeadRoom(tm: *DeltaManager, need: u32) !void {
        try apply_base.ensureHeadRoom(tm, growth_fudge, need);
    }

    fn ensureTailRoom(tm: *DeltaManager, need: u32) !void {
        try apply_base.ensureTailRoom(tm, growth_fudge, need);
    }

    pub fn insert(tm: *DeltaManager, at: u32, new_text: []const u8) !void {
        dbgassert(new_text.len <= std.math.maxInt(u32));
        const new_len: u32 = @intCast(new_text.len);
        dbgassert(at <= tm.textLen());

        if (at < tm.pivot) {
            try tm.ensureHeadRoom(new_len);
            const new_start = tm.start - new_len;
            @memmove(
                tm.buffer[new_start..][0..at],
                tm.buffer[tm.start..][0..at],
            );
            tm.start = new_start;
        } else {
            try tm.ensureTailRoom(new_len);
            const abs_start = tm.start + at;
            @memmove(
                tm.buffer[abs_start + new_len ..][0 .. tm.end - abs_start],
                tm.buffer[abs_start..][0 .. tm.end - abs_start],
            );
            tm.end += new_len;
        }

        @memcpy(tm.buffer[tm.start + at ..][0..new_len], new_text);
        tm.budget -|= new_len;
    }

    pub fn delete(tm: *DeltaManager, start: u32, len: u32) void {
        const abs_start = tm.start + start;
        const abs_end = abs_start + len;
        dbgassert(start <= tm.textLen());
        dbgassert(len <= tm.textLen() - start);

        if (start < tm.pivot) {
            @memmove(
                tm.buffer[tm.start + len ..][0..start],
                tm.buffer[tm.start..][0..start],
            );
            tm.start += len;
        } else {
            @memmove(
                tm.buffer[abs_start..][0 .. tm.end - abs_end],
                tm.buffer[abs_end..][0 .. tm.end - abs_end],
            );
            tm.end -= len;
        }

        tm.budget +|= len;
    }

    fn currentHarmonizedDeltaOp(tm: *const DeltaManager) !?HarmonizedDeltaOp {
        const zdelta = tm.zdelta orelse return error.MissingZDelta;
        dbgassert(tm.z_idx < zdelta.ops.len);
        return zdelta.ops[tm.z_idx];
    }

    fn advanceToHarmonizedMutation(tm: *DeltaManager) !?HarmonizedDeltaOp {
        const zdelta = tm.zdelta orelse return error.MissingZDelta;
        while (tm.z_idx < zdelta.ops.len) {
            const op = (try tm.currentHarmonizedDeltaOp()).?;
            if (op.state == .blocked) return op;
            switch (op.effective) {
                .equal => |len| {
                    tm.t_idx += len;
                    tm.z_idx += 1;
                },
                .insert, .delete => return op,
            }
        }
        return null;
    }

    fn deltaInsertText(tm: *const DeltaManager, span: DeltaSpan) ![]const u8 {
        const zdelta = tm.zdelta.?;
        const offset: usize = span.offset;
        const len: usize = span.len;
        return zdelta.insert_text[offset..][0..len];
    }

    fn captureSkippedOp(tm: *const DeltaManager, op: DeltaOp) !SkippedDeltaOp {
        const text = switch (op) {
            .insert => |span| try tm.allocator.dupe(u8, try tm.deltaInsertText(span)),
            .delete => |len| try tm.allocator.dupe(u8, tm.view()[tm.t_idx..][0..len]),
            .equal => unreachable,
        };
        return .{
            .at = tm.t_idx,
            .z_idx = tm.z_idx,
            .op = op,
            .text = text,
            .accounted_for_current_delta = false,
        };
    }

    fn rewriteTailAfterSkippedDelete(tm: *DeltaManager, len: u32) !void {
        const zdelta = tm.zdelta.?;
        var rebuilt = std.ArrayListUnmanaged(HarmonizedDeltaOp).empty;
        defer rebuilt.deinit(tm.allocator);
        try rebuilt.ensureTotalCapacity(tm.allocator, zdelta.ops.len);
        rebuilt.appendSliceAssumeCapacity(zdelta.ops[0..tm.z_idx]);
        try appendRewrittenOp(tm.allocator, &rebuilt, .{ .equal = len }, .{ .equal = len }, null);
        for (zdelta.ops[tm.z_idx + 1 ..]) |op| {
            try appendAnalyzedOp(tm.allocator, &rebuilt, op);
        }

        tm.allocator.free(zdelta.ops);
        zdelta.ops = try rebuilt.toOwnedSlice(tm.allocator);
    }

    fn rewriteTailAfterSkippedInsert(tm: *DeltaManager, skipped_len: u32) !void {
        const zdelta = tm.zdelta.?;
        var rebuilt = std.ArrayListUnmanaged(HarmonizedDeltaOp).empty;
        defer rebuilt.deinit(tm.allocator);
        try rebuilt.ensureTotalCapacity(tm.allocator, zdelta.ops.len);
        rebuilt.appendSliceAssumeCapacity(zdelta.ops[0..tm.z_idx]);

        var pending = skipped_len;
        for (zdelta.ops[tm.z_idx + 1 ..]) |op| {
            switch (op.effective) {
                .insert => try appendAnalyzedOp(tm.allocator, &rebuilt, op),
                .equal => |len| {
                    const dropped = @min(len, pending);
                    pending -= dropped;
                    const kept = len - dropped;
                    if (kept != 0) try appendRewrittenOp(tm.allocator, &rebuilt, op.original, .{ .equal = kept }, null);
                },
                .delete => try appendAnalyzedOp(tm.allocator, &rebuilt, op),
            }
        }

        tm.allocator.free(zdelta.ops);
        zdelta.ops = try rebuilt.toOwnedSlice(tm.allocator);
    }

    fn harmonizeCurrentDelta(tm: *DeltaManager) !void {
        if (tm.skipped.items.len == 0) return;
        for (tm.skipped.items, 0..) |*skipped, idx| {
            try tm.applySkipHistoryEntry(skipped, cast(u32, idx));
        }
    }

    fn applySkipHistoryEntry(tm: *DeltaManager, skipped: *SkippedDeltaOp, skip_index: u32) !void {
        switch (skipped.op) {
            .delete => |len| try tm.harmonizeSkippedDelete(skipped.at, len, skip_index),
            .insert => |span| try tm.harmonizeSkippedInsert(skipped.at, span.len, skip_index),
            .equal => unreachable,
        }
        skipped.accounted_for_current_delta = true;
    }

    fn harmonizeSkippedDelete(tm: *DeltaManager, at: u32, len: u32, skip_index: u32) !void {
        const zdelta = tm.zdelta.?;
        var rebuilt = std.ArrayListUnmanaged(HarmonizedDeltaOp).empty;
        defer rebuilt.deinit(tm.allocator);
        try rebuilt.ensureTotalCapacity(tm.allocator, zdelta.ops.len + 1);

        var cursor: u32 = 0;
        var inserted = false;
        for (zdelta.ops) |op| {
            switch (op.effective) {
                .insert => {
                    if (!inserted and cursor == at) {
                        try appendBlockedOrRewrittenEqual(tm.allocator, &rebuilt, len, skip_index);
                        inserted = true;
                    }
                    try appendAnalyzedOp(tm.allocator, &rebuilt, op);
                },
                .equal, .delete => |count| {
                    if (!inserted and at >= cursor and at <= cursor + count) {
                        const prefix = at - cursor;
                        const suffix = count - prefix;
                        if (prefix != 0) {
                            try appendRewrittenOp(
                                tm.allocator,
                                &rebuilt,
                                resizeOp(op.original, prefix),
                                makeSameKind(op.effective, prefix),
                                op.skip_index,
                            );
                        }
                        try appendBlockedOrRewrittenEqual(tm.allocator, &rebuilt, len, skip_index);
                        inserted = true;
                        if (suffix != 0) {
                            try appendRewrittenOp(
                                tm.allocator,
                                &rebuilt,
                                resizeOp(op.original, suffix),
                                makeSameKind(op.effective, suffix),
                                op.skip_index,
                            );
                        }
                    } else {
                        try appendAnalyzedOp(tm.allocator, &rebuilt, op);
                    }
                    cursor += count;
                },
            }
        }
        if (!inserted and cursor == at) {
            try appendBlockedOrRewrittenEqual(tm.allocator, &rebuilt, len, skip_index);
            inserted = true;
        }
        if (!inserted) try appendBlockedMarker(tm.allocator, &rebuilt, skip_index);

        tm.allocator.free(zdelta.ops);
        zdelta.ops = try rebuilt.toOwnedSlice(tm.allocator);
    }

    fn harmonizeSkippedInsert(tm: *DeltaManager, at: u32, skipped_len: u32, skip_index: u32) !void {
        const zdelta = tm.zdelta.?;
        var rebuilt = std.ArrayListUnmanaged(HarmonizedDeltaOp).empty;
        defer rebuilt.deinit(tm.allocator);
        try rebuilt.ensureTotalCapacity(tm.allocator, zdelta.ops.len + 1);

        var cursor: u32 = 0;
        var pending = skipped_len;
        var reached = false;
        for (zdelta.ops) |op| {
            switch (op.effective) {
                .insert => {
                    if (!reached and cursor == at) reached = true;
                    try appendAnalyzedOp(tm.allocator, &rebuilt, op);
                },
                .equal, .delete => |count| {
                    if (!reached and at > cursor and at < cursor + count) {
                        const prefix = at - cursor;
                        const suffix = count - prefix;
                        if (prefix != 0) {
                            try appendRewrittenOp(
                                tm.allocator,
                                &rebuilt,
                                resizeOp(op.original, prefix),
                                makeSameKind(op.effective, prefix),
                                op.skip_index,
                            );
                        }
                        reached = true;
                        if (suffix != 0) {
                            switch (op.effective) {
                                .equal => {
                                    const remainder = HarmonizedDeltaOp{
                                        .original = resizeOp(op.original, suffix),
                                        .effective = .{ .equal = suffix },
                                        .state = op.state,
                                        .skip_index = op.skip_index,
                                    };
                                    try rewriteAfterSkippedInsertSegment(
                                        tm.allocator,
                                        &rebuilt,
                                        remainder,
                                        &pending,
                                        skip_index,
                                    );
                                },
                                .delete => {
                                    try appendRewrittenOp(
                                        tm.allocator,
                                        &rebuilt,
                                        resizeOp(op.original, suffix),
                                        .{ .delete = suffix },
                                        op.skip_index,
                                    );
                                },
                                .insert => unreachable,
                            }
                        }
                    } else if (reached or at == cursor) {
                        reached = true;
                        switch (op.effective) {
                            .equal => try rewriteAfterSkippedInsertSegment(
                                tm.allocator,
                                &rebuilt,
                                op,
                                &pending,
                                skip_index,
                            ),
                            .delete => try appendAnalyzedOp(tm.allocator, &rebuilt, op),
                            .insert => unreachable,
                        }
                    } else {
                        try appendAnalyzedOp(tm.allocator, &rebuilt, op);
                    }
                    cursor += count;
                },
            }
        }
        if (pending != 0) try appendBlockedMarker(tm.allocator, &rebuilt, skip_index);

        tm.allocator.free(zdelta.ops);
        zdelta.ops = try rebuilt.toOwnedSlice(tm.allocator);
    }

    pub fn textLen(tm: *const DeltaManager) u32 {
        return tm.end - tm.start;
    }

    fn equivalentLen(tm: *const DeltaManager) u32 {
        var len: i33 = cast(i33, tm.textLen());
        for (tm.skipped.items) |skipped| {
            switch (skipped.op) {
                .insert => |span| len += cast(i33, span.len),
                .delete => |count| len -= cast(i33, count),
                .equal => unreachable,
            }
        }
        dbgassert(len >= 0);
        return cast(u32, len);
    }

    fn totalSlack(tm: *const DeltaManager) u32 {
        return apply_base.totalSlack(tm);
    }
};

fn appendRewrittenOp(
    allocator: Allocator,
    ops: *std.ArrayListUnmanaged(HarmonizedDeltaOp),
    original: DeltaOp,
    effective: DeltaOp,
    skip_index: ?u32,
) !void {
    switch (effective) {
        .equal => |len| if (len != 0) try ops.append(allocator, .{
            .original = original,
            .effective = effective,
            .state = if (std.meta.eql(original, effective)) .unchanged else .rewritten,
            .skip_index = skip_index,
        }),
        .delete => |len| if (len != 0) try ops.append(allocator, .{
            .original = original,
            .effective = effective,
            .state = if (std.meta.eql(original, effective)) .unchanged else .rewritten,
            .skip_index = skip_index,
        }),
        .insert => |span| if (span.len != 0) try ops.append(allocator, .{
            .original = original,
            .effective = effective,
            .state = if (std.meta.eql(original, effective)) .unchanged else .rewritten,
            .skip_index = skip_index,
        }),
    }
}

fn appendAnalyzedOp(
    allocator: Allocator,
    ops: *std.ArrayListUnmanaged(HarmonizedDeltaOp),
    op: HarmonizedDeltaOp,
) !void {
    try appendRewrittenOp(allocator, ops, op.original, op.effective, op.skip_index);
    if (ops.items.len != 0) {
        ops.items[ops.items.len - 1].state = op.state;
    }
}

fn appendBlockedMarker(
    allocator: Allocator,
    ops: *std.ArrayListUnmanaged(HarmonizedDeltaOp),
    skip_index: u32,
) !void {
    try ops.append(allocator, .{
        .original = .{ .equal = 0 },
        .effective = .{ .equal = 0 },
        .state = .blocked,
        .skip_index = skip_index,
    });
}

fn appendBlockedOrRewrittenEqual(
    allocator: Allocator,
    ops: *std.ArrayListUnmanaged(HarmonizedDeltaOp),
    len: u32,
    skip_index: u32,
) !void {
    try appendRewrittenOp(allocator, ops, .{ .equal = len }, .{ .equal = len }, skip_index);
    if (ops.items.len != 0) ops.items[ops.items.len - 1].state = .rewritten;
}

fn rewriteAfterSkippedInsertSegment(
    allocator: Allocator,
    ops: *std.ArrayListUnmanaged(HarmonizedDeltaOp),
    op: HarmonizedDeltaOp,
    pending: *u32,
    skip_index: u32,
) !void {
    const len = op.effective.equal;
    const dropped = @min(len, pending.*);
    pending.* -= dropped;
    const kept = len - dropped;
    if (kept != 0) try appendRewrittenOp(allocator, ops, op.original, .{ .equal = kept }, skip_index);
}

fn makeSameKind(op: DeltaOp, len: u32) DeltaOp {
    return switch (op) {
        .equal => .{ .equal = len },
        .delete => .{ .delete = len },
        .insert => unreachable,
    };
}

fn resizeOp(op: DeltaOp, len: u32) DeltaOp {
    return switch (op) {
        .equal => .{ .equal = len },
        .delete => .{ .delete = len },
        .insert => |span| .{ .insert = .{
            .offset = span.offset,
            .len = len,
        } },
    };
}

fn testManager(
    comptime TManager: type,
    allocator: Allocator,
    before: []const u8,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !TManager {
    const zdelta = try allocator.create(ZDelta);
    errdefer allocator.destroy(zdelta);
    zdelta.* = try testZDelta(allocator, insert_text, ops);

    return TManager.init(allocator, before, zdelta);
}

fn testTextManager(
    allocator: Allocator,
    before: []const u8,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !DeltaApplicator {
    return testManager(DeltaApplicator, allocator, before, insert_text, ops);
}

fn testDeltaManager(
    allocator: Allocator,
    before: []const u8,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !DeltaManager {
    return testManager(DeltaManager, allocator, before, insert_text, ops);
}

fn testOwnedZDelta(
    allocator: Allocator,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !*ZDelta {
    const zdelta = try allocator.create(ZDelta);
    errdefer allocator.destroy(zdelta);
    zdelta.* = try testZDelta(allocator, insert_text, ops);
    return zdelta;
}

fn expectManagerText(
    expected: []const u8,
    tm: anytype,
) !void {
    try testing.expectEqualStrings(expected, tm.view());
}

fn assertSharedApplicatorInterface(comptime TManager: type) void {
    _ = TManager.init;
    _ = TManager.initText;
    _ = TManager.addDelta;
    _ = TManager.deinit;
    _ = TManager.view;
    _ = TManager.move;
    _ = TManager.applyAll;
    _ = TManager.applyNext;
    _ = TManager.insert;
    _ = TManager.delete;
    _ = TManager.textLen;
}

test "ZDelta applicators expose the shared baseline interface" {
    inline for (shared_applicator_types) |TManager| {
        assertSharedApplicatorInterface(TManager);
    }
}

test "ZDelta TextManager rejects wrong text length" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        const zdelta = try allocator.create(ZDelta);
        errdefer zdelta.destroy(allocator);
        zdelta.* = try testZDelta(allocator, "", &.{
            .{ .equal = 3 },
        });

        try testing.expectError(
            error.ZDeltaTextLengthMismatch,
            TManager.init(allocator, "ab", zdelta),
        );
    }
}

test "ZDelta TextManager initText empty" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "");
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(u32, 0), tm.end);
        try testing.expectEqual(@as(u32, 0), tm.pivot);
        try testing.expectEqual(@as(u32, 0), tm.budget);
        try testing.expectEqual(@as(?*ZDelta, null), tm.zdelta);
        try testing.expectEqual(@as(u32, 0), tm.t_idx);
        try testing.expectEqual(@as(u32, 0), tm.z_idx);
        try expectManagerText("", &tm);
    }
}

test "ZDelta TextManager initText rounds slack evenly" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "abcde");
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 1), tm.start);
        try testing.expectEqual(@as(u32, 6), tm.end);
        try testing.expectEqual(@as(u32, 2), tm.budget);
        try testing.expectEqual(@as(usize, 7), tm.buffer.len);
        try expectManagerText("abcde", &tm);
    }
}

test "ZDelta TextManager init empty" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "", "", &.{});
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(u32, 0), tm.end);
        try testing.expectEqual(@as(u32, 0), tm.pivot);
        try testing.expectEqual(@as(u32, 0), tm.budget);
        try testing.expectEqual(@as(usize, 0), tm.zdelta.?.insert_text.len);
        try testing.expectEqual(@as(u32, 0), tm.t_idx);
        try testing.expectEqual(@as(u32, 0), tm.z_idx);
        try testing.expect(tm.zdelta != null);
        try expectManagerText("", &tm);
    }
}

test "ZDelta TextManager addDelta attaches and recenters" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "abcd");
        defer tm.deinit();
        tm.pivot = 0;
        tm.t_idx = 9;
        tm.z_idx = 9;

        const zdelta = try testOwnedZDelta(allocator, "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 2 },
            .{ .delete = 1 },
            .{ .insert = .{ .offset = 1, .len = 1 } },
            .{ .equal = 1 },
        });
        try tm.addDelta(zdelta);

        try testing.expect(tm.zdelta == zdelta);
        try testing.expectEqual(@as(u32, 2), tm.pivot);
        try testing.expectEqual(@as(u32, 0), tm.t_idx);
        try testing.expectEqual(@as(u32, 0), tm.z_idx);
        try testing.expectEqual(@as(u32, 1), tm.start);
        try testing.expectEqual(@as(u32, 5), tm.end);
        try testing.expectEqual(@as(u32, 2), tm.budget);
    }
}

test "ZDelta TextManager addDelta refuses to replace active delta" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "X", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 4 },
        });
        defer tm.deinit();

        const replacement = try testOwnedZDelta(allocator, "Y", &.{
            .{ .equal = 4 },
            .{ .insert = .{ .offset = 0, .len = 1 } },
        });
        defer replacement.destroy(allocator);
        try testing.expectError(error.NewDeltaRefusedOldDeltaNotFullyApplied, tm.addDelta(replacement));

        try testing.expect(tm.zdelta != null);
        try testing.expect(tm.zdelta != replacement);
        try testing.expectEqual(@as(u32, 0), tm.z_idx);
        try testing.expectEqual(@as(u32, 0), tm.t_idx);
    }
}

test "ZDelta TextManager addDelta replaces exhausted owned delta" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "X", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 4 },
        });
        defer tm.deinit();

        try tm.applyAll();

        const replacement = try testOwnedZDelta(allocator, "Y", &.{
            .{ .equal = 5 },
            .{ .insert = .{ .offset = 0, .len = 1 } },
        });
        try tm.addDelta(replacement);

        try testing.expect(tm.zdelta == replacement);
        try testing.expectEqual(@as(u32, 0), tm.z_idx);
        try testing.expectEqual(@as(u32, 0), tm.t_idx);
    }
}

test "ZDelta TextManager addDelta rejects wrong text length" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "ab");
        defer tm.deinit();

        const zdelta = try testOwnedZDelta(allocator, "", &.{
            .{ .equal = 3 },
        });
        try testing.expectError(error.ZDeltaTextLengthMismatch, tm.addDelta(zdelta));
        try testing.expect(tm.zdelta == zdelta);
    }
}

test "ZDelta TextManager addDelta grows to cover net positive change" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "abc");
        defer tm.deinit();

        const original_buffer_len = tm.buffer.len;
        try testing.expectEqual(@as(u32, 2), tm.budget);

        const zdelta = try testOwnedZDelta(allocator, "WXYZ", &.{
            .{ .equal = 3 },
            .{ .insert = .{ .offset = 0, .len = 4 } },
        });
        try tm.addDelta(zdelta);

        try testing.expect(tm.buffer.len > original_buffer_len);
        try testing.expectEqual(@as(u32, 20), tm.budget);
    }
}

test "ZDelta TextManager addDelta reserves directional slack" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "abc");
        defer tm.deinit();

        const zdelta = try testOwnedZDelta(allocator, "X", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 3 },
        });
        try tm.addDelta(zdelta);

        try testing.expectEqual(@as(u32, 1), tm.start);
        try testing.expectEqual(@as(usize, 1), tm.buffer.len - tm.end);
    }
}

test "ZDelta TextManager init and split lifecycle are equivalent" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var init_tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 2 },
            .{ .delete = 1 },
            .{ .insert = .{ .offset = 1, .len = 1 } },
            .{ .equal = 1 },
        });
        defer init_tm.deinit();

        var split_tm: TManager = try .initText(allocator, "abcd");
        defer split_tm.deinit();
        const zdelta = try testOwnedZDelta(allocator, "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 2 },
            .{ .delete = 1 },
            .{ .insert = .{ .offset = 1, .len = 1 } },
            .{ .equal = 1 },
        });
        try split_tm.addDelta(zdelta);

        try init_tm.applyAll();
        try split_tm.applyAll();

        try testing.expectEqual(init_tm.t_idx, split_tm.t_idx);
        try testing.expectEqual(init_tm.z_idx, split_tm.z_idx);
        try testing.expectEqual(init_tm.textLen(), split_tm.textLen());
        try expectManagerText(init_tm.view(), &split_tm);
    }
}

test "ZDelta TextManager partial skip surface is available" {
    comptime {
        _ = DeltaManager.skipNext;
        _ = DeltaManager.skippedItems;
    }
}

test "ZDelta TextManager skipNext skips insert and records text" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try testing.expectEqual(@as(usize, 1), tm.skippedItems().len);
    try testing.expectEqual(@as(u32, 0), tm.skippedItems()[0].at);
    try testing.expectEqual(@as(u32, 0), tm.skippedItems()[0].z_idx);
    try testing.expectEqualDeep(DeltaOp{ .insert = .{ .offset = 0, .len = 1 } }, tm.skippedItems()[0].op);
    try testing.expectEqualStrings("X", tm.skippedItems()[0].text);

    try testing.expectEqual(@as(?void, {}), try tm.applyNext());
    try testing.expectEqual(@as(?void, {}), try tm.applyNext());
    try testing.expectEqual(@as(?void, null), try tm.applyNext());
    try expectManagerText("aYcd", &tm);
}

test "ZDelta TextManager skipNext preserves later delete lengths after skipped insert" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .delete = 2 },
        .{ .equal = 2 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try testing.expectEqual(@as(?void, {}), try tm.applyNext());
    try testing.expectEqual(@as(?void, null), try tm.applyNext());
    try expectManagerText("cd", &tm);
}

test "ZDelta TextManager skipNext skips delete and records text" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "Y", &.{
        .{ .equal = 1 },
        .{ .delete = 2 },
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 1 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try testing.expectEqual(@as(usize, 1), tm.skippedItems().len);
    try testing.expectEqual(@as(u32, 1), tm.skippedItems()[0].at);
    try testing.expectEqualDeep(DeltaOp{ .delete = 2 }, tm.skippedItems()[0].op);
    try testing.expectEqualStrings("bc", tm.skippedItems()[0].text);

    try testing.expectEqual(@as(?void, {}), try tm.applyNext());
    try testing.expectEqual(@as(?void, null), try tm.applyNext());
    try expectManagerText("abcYd", &tm);
}

test "ZDelta TextManager skipNext returns null when only equals remain" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "", &.{
        .{ .equal = 4 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, null), try tm.skipNext());
    try testing.expectEqual(@as(u32, 4), tm.t_idx);
    try testing.expectEqual(@as(u32, 1), tm.z_idx);
    try testing.expectEqual(@as(usize, 0), tm.skippedItems().len);
}

test "ZDelta TextManager skipNext rejects missing delta" {
    const allocator = testing.allocator;
    var tm: DeltaManager = try .initText(allocator, "abcd");
    defer tm.deinit();

    try testing.expectError(error.MissingZDelta, tm.skipNext());
}

test "ZDelta TextManager skipNext accumulates history across skips" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try testing.expectEqual(@as(usize, 2), tm.skippedItems().len);
    try testing.expectEqualStrings("X", tm.skippedItems()[0].text);
    try testing.expectEqualStrings("b", tm.skippedItems()[1].text);
}

test "ZDelta TextManager skip history survives later delta attachment" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 4 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try tm.applyAll();

    const next = try testOwnedZDelta(allocator, "Y", &.{
        .{ .equal = 5 },
        .{ .insert = .{ .offset = 0, .len = 1 } },
    });
    try tm.addDelta(next);
    try testing.expectEqual(@as(usize, 1), tm.skippedItems().len);
    try testing.expectEqualStrings("X", tm.skippedItems()[0].text);
    try testing.expect(tm.skippedItems()[0].accounted_for_current_delta);
    try testing.expectEqualDeep(DeltaOp{ .equal = 5 }, tm.zdelta.?.ops[0].original);
    try testing.expectEqualDeep(DeltaOp{ .equal = 4 }, tm.zdelta.?.ops[0].effective);
    try testing.expectEqual(HarmonizedOpState.rewritten, tm.zdelta.?.ops[0].state);
}

test "ZDelta TextManager harmonizes skipped insert without shrinking later delete" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 4 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try tm.applyAll();

    const next = try testOwnedZDelta(allocator, "", &.{
        .{ .equal = 1 },
        .{ .delete = 2 },
        .{ .equal = 2 },
    });
    try tm.addDelta(next);
    try tm.applyAll();

    try expectManagerText("cd", &tm);
}

test "ZDelta TextManager equivalentLen accounts for skipped history" {
    const allocator = testing.allocator;

    var skipped_insert = try testDeltaManager(allocator, "abcd", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 4 },
    });
    defer skipped_insert.deinit();

    try testing.expectEqual(@as(?void, {}), try skipped_insert.skipNext());
    try skipped_insert.applyAll();
    try testing.expectEqual(@as(u32, 4), skipped_insert.textLen());
    try testing.expectEqual(@as(u32, 5), skipped_insert.equivalentLen());

    var skipped_delete = try testDeltaManager(allocator, "abcd", "", &.{
        .{ .equal = 1 },
        .{ .delete = 2 },
        .{ .equal = 1 },
    });
    defer skipped_delete.deinit();

    try testing.expectEqual(@as(?void, {}), try skipped_delete.skipNext());
    try skipped_delete.applyAll();
    try testing.expectEqual(@as(u32, 4), skipped_delete.textLen());
    try testing.expectEqual(@as(u32, 2), skipped_delete.equivalentLen());
}

test "ZDelta TextManager addDelta rejects blocked harmonization with impossible original length" {
    const allocator = testing.allocator;
    var tm = try testDeltaManager(allocator, "abcd", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 4 },
    });
    defer tm.deinit();

    try testing.expectEqual(@as(?void, {}), try tm.skipNext());
    try tm.applyAll();

    const blocked = try testOwnedZDelta(allocator, "Y", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
    });
    try testing.expectError(error.ZDeltaTextLengthMismatch, tm.addDelta(blocked));
    try testing.expect(tm.zdelta == blocked);
}

test "ZDelta TextManager plans front and tail slack" {
    const allocator = testing.allocator;

    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var front = try testManager(TManager, allocator, "abc", "X", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 3 },
        });
        defer front.deinit();
        try testing.expectEqual(@as(u32, 1), front.start);
        try testing.expectEqual(@as(u32, 4), front.end);
        try testing.expectEqual(@as(u32, 1), front.budget);
        try testing.expectEqual(@as(usize, 1), front.zdelta.?.insert_text.len);

        var tail = try testManager(TManager, allocator, "abc", "X", &.{
            .{ .equal = 3 },
            .{ .insert = .{ .offset = 0, .len = 1 } },
        });
        defer tail.deinit();
        try testing.expectEqual(@as(u32, 0), tail.start);
        try testing.expectEqual(@as(u32, 3), tail.end);
        try testing.expectEqual(@as(u32, 1), tail.budget);
        try testing.expectEqual(@as(usize, 1), tail.zdelta.?.insert_text.len);
        try testing.expectEqual(@as(usize, 1), tail.buffer.len - tail.end);
    }
}

test "ZDelta TextManager plans mixed pressure" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 2 },
            .{ .delete = 1 },
            .{ .insert = .{ .offset = 1, .len = 1 } },
            .{ .equal = 1 },
        });
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 1), tm.start);
        try testing.expectEqual(@as(u32, 1), tm.budget);
        try testing.expectEqual(@as(usize, 0), tm.buffer.len - tm.end);
        try testing.expectEqual(@as(usize, 2), tm.zdelta.?.insert_text.len);
    }
}

test "ZDelta TextManager rebases with sufficient total slack" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abc", "X", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 3 },
        });
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 1), tm.start);
        try testing.expectEqual(@as(usize, 0), tm.buffer.len - tm.end);
        try testing.expectEqual(@as(u32, 1), tm.budget);

        try tm.insert(3, "X");
        try expectManagerText("abcX", &tm);
        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(usize, 0), tm.buffer.len - tm.end);
        try testing.expectEqual(@as(u32, 0), tm.budget);
    }
}

test "ZDelta TextManager keeps midpoint fixed across front-heavy edits" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcdefghij", "12345!", &.{
            .{ .insert = .{ .offset = 0, .len = 5 } },
            .{ .equal = 4 },
            .{ .insert = .{ .offset = 5, .len = 1 } },
            .{ .equal = 6 },
        });
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 5), tm.pivot);
        try testing.expectEqual(@as(u32, 5), tm.start);
        try testing.expectEqual(@as(u32, 6), tm.budget);
        try testing.expectEqual(@as(usize, 1), tm.buffer.len - tm.end);

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 5), tm.pivot);
        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(u32, 1), tm.budget);
        try testing.expectEqual(@as(usize, 1), tm.buffer.len - tm.end);

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 5), tm.pivot);
        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(u32, 0), tm.budget);
        try testing.expectEqual(@as(usize, 0), tm.buffer.len - tm.end);
        try expectManagerText("12345abcd!efghij", &tm);
    }
}

test "ZDelta TextManager grows after exhausting planned slack" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcdefghij", "12345!?", &.{
            .{ .insert = .{ .offset = 0, .len = 5 } },
            .{ .equal = 4 },
            .{ .insert = .{ .offset = 5, .len = 1 } },
            .{ .insert = .{ .offset = 6, .len = 1 } },
            .{ .equal = 6 },
        });
        defer tm.deinit();

        const original_buffer_len = tm.buffer.len;
        try testing.expectEqual(@as(u32, 7), tm.budget);

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 2), tm.budget);
        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 1), tm.budget);
        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 0), tm.budget);

        try tm.insert(tm.textLen(), "??");
        try testing.expect(tm.buffer.len > original_buffer_len);
        try testing.expectEqual(@as(u32, TManager.growth_fudge), tm.budget);
        try expectManagerText("12345abcd!?efghij??", &tm);
    }
}

test "ZDelta TextManager replace same size" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "", &.{
            .{ .equal = 4 },
        });
        defer tm.deinit();

        tm.delete(1, 2);
        try testing.expectEqual(@as(u32, 2), tm.budget);
        try tm.insert(1, "XY");
        try expectManagerText("aXYd", &tm);
        try testing.expectEqual(@as(u32, 0), tm.budget);
        try testing.expectEqual(@as(usize, 0), tm.zdelta.?.insert_text.len);
    }
}

test "ZDelta TextManager budget tracks net edit pressure" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcdef", "", &.{
            .{ .equal = 6 },
        });
        defer tm.deinit();

        try testing.expectEqual(@as(u32, 0), tm.budget);

        tm.delete(1, 2);
        try testing.expectEqual(@as(u32, 2), tm.budget);
        try testing.expectEqual(@as(u32, 2), tm.start);
        try testing.expectEqual(@as(usize, 0), tm.buffer.len - tm.end);

        try tm.insert(1, "XYZ");
        try testing.expectEqual(@as(u32, TManager.growth_fudge), tm.budget);
        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(usize, TManager.growth_fudge), tm.buffer.len - tm.end);
        try expectManagerText("aXYZdef", &tm);
    }
}

test "ZDelta TextManager grow from head side" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 2 } },
            .{ .equal = 4 },
        });
        defer tm.deinit();

        try tm.insert(0, "XY");
        try expectManagerText("XYabcd", &tm);
        try testing.expectEqual(@as(u32, 0), tm.start);
        try testing.expectEqual(@as(u32, 0), tm.budget);
        try testing.expectEqual(@as(usize, 2), tm.zdelta.?.insert_text.len);
    }
}

test "ZDelta TextManager grow from tail side" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .equal = 4 },
            .{ .insert = .{ .offset = 0, .len = 2 } },
        });
        defer tm.deinit();

        try tm.insert(4, "XY");
        try expectManagerText("abcdXY", &tm);
        try testing.expectEqual(@as(u32, 0), tm.budget);
        try testing.expectEqual(@as(usize, 2), tm.zdelta.?.insert_text.len);
    }
}

test "ZDelta TextManager shrink from head side" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "", &.{
            .{ .delete = 2 },
            .{ .equal = 2 },
        });
        defer tm.deinit();

        tm.delete(0, 2);
        try expectManagerText("cd", &tm);
        try testing.expectEqual(@as(u32, 2), tm.start);
        try testing.expectEqual(@as(u32, 2), tm.budget);
        try testing.expectEqual(@as(usize, 0), tm.zdelta.?.insert_text.len);
    }
}

test "ZDelta TextManager shrink from tail side" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "", &.{
            .{ .equal = 2 },
            .{ .delete = 2 },
        });
        defer tm.deinit();

        tm.delete(2, 2);
        try expectManagerText("ab", &tm);
        try testing.expectEqual(@as(u32, 2), tm.budget);
        try testing.expectEqual(@as(usize, 0), tm.zdelta.?.insert_text.len);
    }
}

test "ZDelta TextManager move rejects unfinished delta" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 2 } },
            .{ .equal = 4 },
        });
        defer tm.deinit();

        try tm.insert(0, "XY");
        try testing.expectError(error.UnfinishedZDelta, tm.move());
    }
}

test "ZDelta TextManager move without delta trims slack" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm: TManager = try .initText(allocator, "abcd");
        defer tm.deinit();

        try tm.insert(0, "XY");
        const finished = try tm.move();
        defer allocator.free(finished);
        tm.buffer = &.{};
        try testing.expectEqual(@as(?*ZDelta, null), tm.zdelta);
        try testing.expectEqualStrings("XYabcd", finished);
    }
}

test "ZDelta TextManager move after exhausting delta trims slack" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 2 } },
            .{ .equal = 4 },
        });

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(?void, null), try tm.applyNext());

        const finished = try tm.move();
        defer allocator.free(finished);
        tm.buffer = &.{};
        try testing.expectEqual(@as(?*ZDelta, null), tm.zdelta);
        try testing.expectEqualStrings("XYabcd", finished);
    }
}

test "ZDelta TextManager applyNext rejects missing owned delta" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "X", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 4 },
        });
        defer tm.deinit();

        const zdelta = tm.zdelta.?;
        defer zdelta.destroy(allocator);
        tm.zdelta = null;
        try testing.expectError(error.MissingZDelta, tm.applyNext());
    }
}

test "ZDelta TextManager applyNext" {
    const allocator = testing.allocator;
    inline for (.{ DeltaApplicator, DeltaManager }) |TManager| {
        var tm = try testManager(TManager, allocator, "abcd", "XY", &.{
            .{ .insert = .{ .offset = 0, .len = 1 } },
            .{ .equal = 2 },
            .{ .delete = 1 },
            .{ .insert = .{ .offset = 1, .len = 1 } },
            .{ .equal = 1 },
        });
        defer tm.deinit();

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 1), tm.t_idx);
        try testing.expectEqual(@as(u32, 1), tm.z_idx);
        try expectManagerText("Xabcd", &tm);

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 3), tm.t_idx);
        try testing.expectEqual(@as(u32, 3), tm.z_idx);
        try expectManagerText("Xabd", &tm);

        try testing.expectEqual(@as(?void, {}), try tm.applyNext());
        try testing.expectEqual(@as(u32, 4), tm.t_idx);
        try testing.expectEqual(@as(u32, 4), tm.z_idx);
        try expectManagerText("XabYd", &tm);

        try testing.expectEqual(@as(?void, null), try tm.applyNext());
        try testing.expectEqual(@as(u32, 5), tm.t_idx);
        try testing.expectEqual(@as(u32, 5), tm.z_idx);
        try expectManagerText("XabYd", &tm);
    }
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const apply_base = @import("apply_base.zig");
const common_apply = @import("common.zig");
const whole_apply = @import("whole_apply.zig");
const zdelta_mod = @import("../zdelta.zig");
const ZDelta = zdelta_mod.ZDelta;
const addU32 = zdelta_mod.addU32;
const checkedU32 = zdelta_mod.checkedU32;
const testZDelta = zdelta_mod.testZDelta;
const common = @import("../dmp/common.zig");
const dbgassert = common.dbgassert;
const cast = common.cast;
const DeltaApplicator = whole_apply.DeltaApplicator;
const shared_applicator_types = .{ DeltaApplicator, DeltaManager };
const DeltaSpan = common_apply.DeltaSpan;
const DeltaOp = common_apply.DeltaOp;
const HarmonizedOpState = common_apply.HarmonizedOpState;
const HarmonizedDeltaOp = common_apply.HarmonizedDeltaOp;
const PreviewDeltaOp = common_apply.PreviewDeltaOp;
const SkippedDeltaOp = common_apply.SkippedDeltaOp;
