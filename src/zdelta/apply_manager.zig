// TODO: split this all up.
// ---
// It will not remain useful for there to be a comptime specialization between these two
// tasks.  One of them is already finished and unlikely to change, and we've written maybe
// 10% of the other.
// ---
// We will go so far as to make separate files.  We'll need common structs to live in
// zdelta/common.zig.  More notes found in the rest of this file.

pub const DeltaManager = TextManager(.partial);
pub const PartialTextManager = DeltaManager;

const WholeTextManager = TextManager(.whole);

/// A TextManager handles a text through at least one ZDelta application.
/// This is intended to be suitable both for rapid application of a single
/// delta, and for menu-style picking through a series of same.
pub fn TextManager(comptime tm_kind: TextManagerKind) type {
    return struct {
        /// The allocator which manages the buffer.  Must also be
        /// usable with owned *ZDeltas.
        allocator: Allocator,
        /// Owned delta used for incremental application.
        zdelta: ?*ZDelta,
        /// The buffer holding the text, and the room around it.
        buffer: []u8,
        /// The start of the text.
        start: u32,
        /// The end of the text.
        end: u32,
        /// The mark which determines whether edits choose
        /// the head or tail when pushing or pulling text.
        pivot: u32,
        /// Remaining net edit pressure before another growth is needed.
        budget: u32,
        /// The working index into the text.
        t_idx: u32,
        /// The working index into the ZDelta.
        z_idx: u32,
        /// Mutating ops skipped interactively and retained for later inspection.
        skipped: if (tm_kind == .partial) std.ArrayListUnmanaged(SkippedDeltaOp) else void,

        const TManager = @This();
        const Skipped = if (tm_kind == .partial) std.ArrayListUnmanaged(SkippedDeltaOp) else void;

        /// Initialize with the before text and its zDelta.  The text is copied, the zDelta
        /// is moved into the manager, and must be copied if retaining it after application
        /// is useful.
        pub fn init(allocator: Allocator, before: []const u8, zdelta: *ZDelta) !TManager {
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
                .skipped = if (tm_kind == .partial) Skipped.empty else {},
            };
        }

        /// Initialize with just the before text, which is copied.
        pub fn initText(allocator: Allocator, text: []const u8) !TManager {
            const text_len = try checkedTextLen(text.len);
            const extra_slack = try initialSlack(text.len);
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
                .skipped = if (tm_kind == .partial) Skipped.empty else {},
            };
        }

        /// Add a delta for application to the text.  Any previous delta
        /// must already be exhausted, that is, applied fully (including
        /// skips when applicable).
        pub fn addDelta(tm: *TManager, zdelta: *ZDelta) !void {
            if (tm.zdelta) |old_zdelta| {
                if (tm.z_idx < old_zdelta.ops.len) return error.NewDeltaRefusedOldDeltaNotFullyApplied;
                old_zdelta.destroy(tm.allocator);
            }
            tm.zdelta = zdelta;
            tm.z_idx = 0;
            tm.t_idx = 0;

            const original_before_len = zdelta.originalBeforeLength();
            if (tm_kind == .partial) {
                for (tm.skipped.items) |*skipped| skipped.accounted_for_current_delta = false;
                try tm.harmonizeCurrentDelta();
                if (tm.equivalentLen() != original_before_len) return error.ZDeltaTextLengthMismatch;
            } else {
                if (tm.textLen() != original_before_len) return error.ZDeltaTextLengthMismatch;
            }
            const before_len, const head_room, const tail_room = zdelta.textNumbers();

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

        /// Release all memory held by the TextManager.
        pub fn deinit(tm: *TManager) void {
            if (tm_kind == .partial) {
                for (tm.skipped.items) |*skipped| skipped.deinit(tm.allocator);
                tm.skipped.deinit(tm.allocator);
            }
            if (tm.zdelta) |zdelta| zdelta.destroy(tm.allocator);
            tm.allocator.free(tm.buffer);
            tm.* = undefined;
        }

        /// Return a view of the current text, which remains owned by the TextManager.
        pub fn view(tm: *const TManager) []const u8 {
            return tm.buffer[tm.start..tm.end];
        }

        pub fn skippedItems(tm: *const TManager) []const SkippedDeltaOp {
            if (tm_kind != .partial) @compileError("skippedItems is only available on TextManager(.partial)");
            return tm.skipped.items;
        }

        pub fn previewNext(tm: *const TManager) !?PreviewDeltaOp {
            if (tm_kind != .partial) @compileError("previewNext is only available on TextManager(.partial)");
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

        /// Move the text out of the TextManager.  The memory is now
        /// owned by the caller.
        pub fn move(tm: *TManager) ![]u8 {
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

        /// Apply all (remaining) ZDelta edits.
        pub fn applyAll(tm: *TManager) !void {
            while (try tm.applyNext()) |_| {}
        }

        /// Apply one mutating edit to the text, if any still remain.  If none
        /// remains, this function returns null, otherwise, void.
        pub fn applyNext(tm: *TManager) !?void {
            if (tm_kind == .partial) {
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
            } else {
                const op = (try tm.advanceToMutation()) orelse return null;
                switch (op) {
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
        }

        pub fn skipNext(tm: *TManager) !?void {
            if (tm_kind != .partial) @compileError("skipNext is only available on TextManager(.partial)");
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

            return;
        }

        /// Move the entire text to new_start.  This is only called
        /// if a budget shortfall caused us to have to reallocate.
        fn rebase(tm: *TManager, new_start: u32) void {
            if (new_start == tm.start) return;
            const active_len = tm.textLen();
            @memmove(
                tm.buffer[new_start..][0..active_len],
                tm.buffer[tm.start..][0..active_len],
            );
            tm.start = new_start;
            tm.end = new_start + active_len;
        }

        /// Reallocate the buffer, only if necessary.
        fn growForNeed(tm: *TManager, need: u32) !void {
            if (need <= tm.budget) return;
            const shortfall = need - tm.budget;
            const growth = shortfall +| growth_fudge;
            const new_len = tm.buffer.len + growth;
            tm.buffer = try tm.allocator.realloc(tm.buffer, new_len);
            tm.budget +|= growth;
        }

        /// Ensure there are `need` bytes available at the head,
        /// reallocating and rebasing if necessary.
        fn ensureHeadRoom(tm: *TManager, need: u32) !void {
            if (need <= tm.start) return;
            if (need > tm.budget) try tm.growForNeed(need);
            dbgassert(need <= tm.totalSlack());
            tm.rebase(need);
        }

        /// Ensure there are `need` bytes available at the tail,
        /// reallocating and rebasing if necessary.
        fn ensureTailRoom(tm: *TManager, need: u32) !void {
            const tail_room: u32 = @intCast(tm.buffer.len - tm.end);
            if (need <= tail_room) return;
            if (need > tm.budget) try tm.growForNeed(need);
            dbgassert(need <= tm.totalSlack());
            tm.rebase(tm.totalSlack() - need);
        }

        fn insert(
            tm: *TManager,
            at: u32,
            new_text: []const u8,
        ) !void {
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

        fn delete(
            tm: *TManager,
            start: u32,
            len: u32,
        ) void {
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

        /// Verify we have a ZDelta, and retrieve its current span given
        /// that we do.
        fn currentHarmonizedDeltaOp(tm: *const TManager) !?HarmonizedDeltaOp {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
            const zdelta = tm.zdelta orelse return error.MissingZDelta;
            dbgassert(tm.z_idx < zdelta.ops.len);
            return zdelta.ops[tm.z_idx];
        }

        fn currentDeltaOp(tm: *const TManager) !?DeltaOp {
            if (tm_kind != .whole) @compileError("wrong kind of TextManager (internal)");
            const zdelta = tm.zdelta orelse return error.MissingZDelta;
            dbgassert(tm.z_idx < zdelta.ops.len);
            dbgassert(zdelta.ops[tm.z_idx].state != .blocked);
            return zdelta.ops[tm.z_idx].effective;
        }

        fn advanceToHarmonizedMutation(tm: *TManager) !?HarmonizedDeltaOp {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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

        fn advanceToMutation(tm: *TManager) !?DeltaOp {
            if (tm_kind != .whole) @compileError("wrong kind of TextManager (internal)");
            const zdelta = tm.zdelta orelse return error.MissingZDelta;
            while (tm.z_idx < zdelta.ops.len) {
                const op = (try tm.currentDeltaOp()).?;
                switch (op) {
                    .equal => |len| {
                        tm.t_idx += len;
                        tm.z_idx += 1;
                    },
                    .insert, .delete => return op,
                }
            }
            return null;
        }

        /// Retrieve the insert text from a delta span.
        fn deltaInsertText(
            tm: *const TManager,
            span: DeltaSpan,
        ) ![]const u8 {
            const zdelta = tm.zdelta.?; // We got the span, we have a zdelta.
            const offset: usize = span.offset;
            const len: usize = span.len;
            return zdelta.insert_text[offset..][0..len];
        }

        fn captureSkippedOp(tm: *const TManager, op: DeltaOp) !SkippedDeltaOp {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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

        fn rewriteTailAfterSkippedDelete(tm: *TManager, len: u32) !void {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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

        fn rewriteTailAfterSkippedInsert(tm: *TManager, skipped_len: u32) !void {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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

        fn harmonizeCurrentDelta(tm: *TManager) !void {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
            if (tm.skipped.items.len == 0) return;
            for (tm.skipped.items, 0..) |*skipped, idx| {
                try tm.applySkipHistoryEntry(skipped, cast(u32, idx));
            }
        }

        fn applySkipHistoryEntry(tm: *TManager, skipped: *SkippedDeltaOp, skip_index: u32) !void {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
            switch (skipped.op) {
                .delete => |len| try tm.harmonizeSkippedDelete(skipped.at, len, skip_index),
                .insert => |span| try tm.harmonizeSkippedInsert(skipped.at, span.len, skip_index),
                .equal => unreachable,
            }
            skipped.accounted_for_current_delta = true;
        }

        fn harmonizeSkippedDelete(tm: *TManager, at: u32, len: u32, skip_index: u32) !void {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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
                                try appendRewrittenOp(tm.allocator, &rebuilt, op.original, makeSameKind(op.effective, prefix), op.skip_index);
                            }
                            try appendBlockedOrRewrittenEqual(tm.allocator, &rebuilt, len, skip_index);
                            inserted = true;
                            if (suffix != 0) {
                                try appendRewrittenOp(tm.allocator, &rebuilt, op.original, makeSameKind(op.effective, suffix), op.skip_index);
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

        fn harmonizeSkippedInsert(tm: *TManager, at: u32, skipped_len: u32, skip_index: u32) !void {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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
                                try appendRewrittenOp(tm.allocator, &rebuilt, op.original, makeSameKind(op.effective, prefix), op.skip_index);
                            }
                            reached = true;
                            if (suffix != 0) {
                                switch (op.effective) {
                                    .equal => {
                                        const remainder = HarmonizedDeltaOp{
                                            .original = op.original,
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
                                            op.original,
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

        const growth_fudge: u32 = 16;

        fn textLen(tm: *const TManager) u32 {
            return tm.end - tm.start;
        }

        fn equivalentLen(tm: *const TManager) u32 {
            if (tm_kind != .partial) @compileError("wrong kind of TextManager (internal)");
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

        fn totalSlack(tm: *const TManager) u32 {
            return tm.start + cast(u32, tm.buffer.len) - tm.end;
        }

        fn initialSlack(text_len: usize) !usize {
            if (text_len == 0) return 0;
            const twenty_percent = @divFloor(text_len - 1, 5) + 1;
            return if (twenty_percent % 2 == 0)
                twenty_percent
            else
                std.math.add(usize, twenty_percent, 1) catch error.ZDeltaTooLarge;
        }

        fn checkedTextLen(text_len: usize) !u32 {
            return std.math.cast(u32, text_len) orelse error.ZDeltaTooLarge;
        }
    };
}

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
) !WholeTextManager {
    return testManager(WholeTextManager, allocator, before, insert_text, ops);
}

fn testPartialTextManager(
    allocator: Allocator,
    before: []const u8,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !PartialTextManager {
    return testManager(PartialTextManager, allocator, before, insert_text, ops);
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

// TODO: We still want the two new types to have a common interface, and
// for what's now PartialTextManager to pass every test which is also
// passed by what's now WholeTextManager. Probably this means we keep
// the tests in the new home of no-longer-PartialTextManager, and do
// the same inline for thing we're doing right here.

test "ZDelta TextManager rejects wrong text length" {
    const allocator = testing.allocator;
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
        _ = PartialTextManager.skipNext;
        _ = PartialTextManager.skippedItems;
    }
}

test "ZDelta TextManager skipNext skips insert and records text" {
    const allocator = testing.allocator;
    var tm = try testPartialTextManager(allocator, "abcd", "XY", &.{
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
    var tm = try testPartialTextManager(allocator, "abcd", "X", &.{
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
    var tm = try testPartialTextManager(allocator, "abcd", "Y", &.{
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
    var tm = try testPartialTextManager(allocator, "abcd", "", &.{
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
    var tm: PartialTextManager = try .initText(allocator, "abcd");
    defer tm.deinit();

    try testing.expectError(error.MissingZDelta, tm.skipNext());
}

test "ZDelta TextManager skipNext accumulates history across skips" {
    const allocator = testing.allocator;
    var tm = try testPartialTextManager(allocator, "abcd", "XY", &.{
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
    var tm = try testPartialTextManager(allocator, "abcd", "X", &.{
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
    var tm = try testPartialTextManager(allocator, "abcd", "X", &.{
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

    var skipped_insert = try testPartialTextManager(allocator, "abcd", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 4 },
    });
    defer skipped_insert.deinit();

    try testing.expectEqual(@as(?void, {}), try skipped_insert.skipNext());
    try skipped_insert.applyAll();
    try testing.expectEqual(@as(u32, 4), skipped_insert.textLen());
    try testing.expectEqual(@as(u32, 5), skipped_insert.equivalentLen());

    var skipped_delete = try testPartialTextManager(allocator, "abcd", "", &.{
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
    var tm = try testPartialTextManager(allocator, "abcd", "X", &.{
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

    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
    inline for (.{ WholeTextManager, PartialTextManager }) |TManager| {
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
const common_apply = @import("common.zig");
const zdelta_mod = @import("../zdelta.zig");
const ZDelta = zdelta_mod.ZDelta;
const TextManagerKind = zdelta_mod.TextManagerKind;
const addU32 = zdelta_mod.addU32;
const checkedU32 = zdelta_mod.checkedU32;
const testZDelta = zdelta_mod.testZDelta;
const common = @import("../dmp/common.zig");
const dbgassert = common.dbgassert;
const cast = common.cast;
const DeltaSpan = common_apply.DeltaSpan;
const DeltaOp = common_apply.DeltaOp;
const HarmonizedOpState = common_apply.HarmonizedOpState;
const HarmonizedDeltaOp = common_apply.HarmonizedDeltaOp;
const PreviewDeltaOp = common_apply.PreviewDeltaOp;
const SkippedDeltaOp = common_apply.SkippedDeltaOp;
