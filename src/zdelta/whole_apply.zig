//! Whole-delta applicator.
//!
//! This is the uncomplicated baseline engine: attach a delta, walk its
//! mutations in order, and never preserve operator-facing provenance. The
//! storage policy is shared with `DeltaManager`, but this type intentionally
//! avoids skip history and harmonization.

pub const DeltaApplicator = struct {
    allocator: Allocator,
    zdelta: ?*ZDelta,
    buffer: []u8,
    start: u32,
    end: u32,
    pivot: u32,
    budget: u32,
    t_idx: u32,
    z_idx: u32,

    pub const growth_fudge: u32 = 16;

    pub fn init(allocator: Allocator, before: []const u8, zdelta: *ZDelta) !DeltaApplicator {
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
        };
    }

    pub fn initText(allocator: Allocator, text: []const u8) !DeltaApplicator {
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
        };
    }

    pub fn addDelta(tm: *DeltaApplicator, zdelta: *ZDelta) !void {
        if (tm.zdelta) |old_zdelta| {
            if (tm.z_idx < old_zdelta.ops.len) return error.NewDeltaRefusedOldDeltaNotFullyApplied;
            old_zdelta.destroy(tm.allocator);
        }
        tm.zdelta = zdelta;
        tm.z_idx = 0;
        tm.t_idx = 0;

        const original_before_len = zdelta.beforeLength();
        if (tm.textLen() != original_before_len) return error.ZDeltaTextLengthMismatch;
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

    pub fn deinit(tm: *DeltaApplicator) void {
        if (tm.zdelta) |zdelta| zdelta.destroy(tm.allocator);
        tm.allocator.free(tm.buffer);
        tm.* = undefined;
    }

    pub fn view(tm: *const DeltaApplicator) []const u8 {
        return tm.buffer[tm.start..tm.end];
    }

    pub fn move(tm: *DeltaApplicator) ![]u8 {
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

    pub fn applyAll(tm: *DeltaApplicator) !void {
        while (try tm.applyNext()) |_| {}
    }

    pub fn applyNext(tm: *DeltaApplicator) !?void {
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

    fn rebase(tm: *DeltaApplicator, new_start: u32) void {
        apply_base.rebase(tm, new_start);
    }

    fn growForNeed(tm: *DeltaApplicator, need: u32) !void {
        try apply_base.growForNeed(tm, growth_fudge, need);
    }

    fn ensureHeadRoom(tm: *DeltaApplicator, need: u32) !void {
        try apply_base.ensureHeadRoom(tm, growth_fudge, need);
    }

    fn ensureTailRoom(tm: *DeltaApplicator, need: u32) !void {
        try apply_base.ensureTailRoom(tm, growth_fudge, need);
    }

    pub fn insert(tm: *DeltaApplicator, at: u32, new_text: []const u8) !void {
        dbgassert(new_text.len <= std.math.maxInt(u32));
        const new_len: u32 = @intCast(new_text.len);
        dbgassert(at <= tm.textLen());

        if (at < tm.pivot) {
            try tm.ensureHeadRoom(new_len);
            const new_start = tm.start - new_len;
            @memmove(tm.buffer[new_start..][0..at], tm.buffer[tm.start..][0..at]);
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

    pub fn delete(tm: *DeltaApplicator, start: u32, len: u32) void {
        const abs_start = tm.start + start;
        const abs_end = abs_start + len;
        dbgassert(start <= tm.textLen());
        dbgassert(len <= tm.textLen() - start);

        if (start < tm.pivot) {
            @memmove(tm.buffer[tm.start + len ..][0..start], tm.buffer[tm.start..][0..start]);
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

    fn currentDeltaOp(tm: *const DeltaApplicator) !?DeltaOp {
        const zdelta = tm.zdelta orelse return error.MissingZDelta;
        dbgassert(tm.z_idx < zdelta.ops.len);
        return zdelta.ops[tm.z_idx];
    }

    fn advanceToMutation(tm: *DeltaApplicator) !?DeltaOp {
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

    fn deltaInsertText(tm: *const DeltaApplicator, span: DeltaSpan) ![]const u8 {
        const zdelta = tm.zdelta.?;
        const offset: usize = span.offset;
        const len: usize = span.len;
        return zdelta.insert_text[offset..][0..len];
    }

    pub fn textLen(tm: *const DeltaApplicator) u32 {
        return tm.end - tm.start;
    }

    fn totalSlack(tm: *const DeltaApplicator) u32 {
        return apply_base.totalSlack(tm);
    }
};

const std = @import("std");

const Allocator = std.mem.Allocator;
const apply_base = @import("apply_base.zig");
const common_apply = @import("common.zig");
const zdelta_mod = @import("../zdelta.zig");
const ZDelta = zdelta_mod.ZDelta;
const addU32 = zdelta_mod.addU32;
const checkedU32 = zdelta_mod.checkedU32;
const common = @import("../dmp/common.zig");
const dbgassert = common.dbgassert;
const DeltaOp = common_apply.DeltaOp;
const DeltaSpan = common_apply.DeltaSpan;
