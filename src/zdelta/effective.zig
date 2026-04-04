//! Partial-path objective-coordinate zdelta form.
//!
//! The raw `ZDelta` format is a compact instruction stream. The partial path
//! needs something richer: every op should already know where it applies in the
//! text as that step is reached, while still remembering the raw-origin
//! coordinates that came from the corpus delta.

pub const EffectiveTextSpan = struct {
    start: u32,
    end: u32,

    pub fn len(span: EffectiveTextSpan) u32 {
        return span.end - span.start;
    }
};

pub const EffectiveInsert = struct {
    at: u32,
    text: DeltaSpan,

    pub fn len(insert: EffectiveInsert) u32 {
        return insert.text.len;
    }
};

pub const EffectiveOp = union(enum) {
    equal: EffectiveTextSpan,
    delete: EffectiveTextSpan,
    insert: EffectiveInsert,

    pub fn len(op: EffectiveOp) u32 {
        return switch (op) {
            .equal => |span| span.len(),
            .delete => |span| span.len(),
            .insert => |insert| insert.len(),
        };
    }

    pub fn start(op: EffectiveOp) u32 {
        return switch (op) {
            .equal => |span| span.start,
            .delete => |span| span.start,
            .insert => |insert| insert.at,
        };
    }
};

pub const EffectiveOpState = enum {
    unchanged,
    rewritten,
    blocked,
};

pub const EffectiveDeltaOp = struct {
    source_op_index: u32,
    source: EffectiveOp,
    current: EffectiveOp,
    state: EffectiveOpState,
    skip_index: ?u32,
};

pub const EffectivePreviewOp = struct {
    text_index: u32,
    delta_index: u32,
    op: EffectiveDeltaOp,
};

pub const EffectiveSkippedChange = union(enum) {
    insert: EffectiveInsert,
    delete: EffectiveTextSpan,

    pub fn len(change: EffectiveSkippedChange) u32 {
        return switch (change) {
            .insert => |insert| insert.len(),
            .delete => |span| span.len(),
        };
    }

    pub fn at(change: EffectiveSkippedChange) u32 {
        return switch (change) {
            .insert => |insert| insert.at,
            .delete => |span| span.start,
        };
    }
};

pub const EffectiveSkippedOp = struct {
    at: u32,
    z_idx: u32,
    op: EffectiveSkippedChange,
    text: []u8,
    accounted_for_current_delta: bool,

    pub fn deinit(skipped: *EffectiveSkippedOp, allocator: Allocator) void {
        allocator.free(skipped.text);
        skipped.* = undefined;
    }
};

// These temporary relative ops let the harmonization code keep reasoning in
// the old length-based stream while the stored representation stays objective.
pub const RelativeDeltaOp = struct {
    source_op_index: u32,
    original: DeltaOp,
    current: DeltaOp,
    state: EffectiveOpState,
    skip_index: ?u32,
};

pub const EffectiveZDelta = struct {
    insert_text: []u8,
    ops: []EffectiveDeltaOp,

    pub fn deinit(delta: *EffectiveZDelta, allocator: Allocator) void {
        allocator.free(delta.insert_text);
        allocator.free(delta.ops);
        delta.* = undefined;
    }

    pub fn destroy(delta: *EffectiveZDelta, allocator: Allocator) void {
        delta.deinit(allocator);
        allocator.destroy(delta);
    }

    pub fn beforeLength(delta: *const EffectiveZDelta) u32 {
        var len: u32 = 0;
        for (delta.ops) |op| {
            switch (op.current) {
                .equal => |span| len += span.len(),
                .delete => |span| len += span.len(),
                .insert => {},
            }
        }
        return len;
    }

    pub fn originalBeforeLength(delta: *const EffectiveZDelta) u32 {
        var len: u32 = 0;
        for (delta.ops) |op| {
            switch (op.source) {
                .equal => |span| len += span.len(),
                .delete => |span| len += span.len(),
                .insert => {},
            }
        }
        return len;
    }

    fn midpoint(delta: *const EffectiveZDelta) u32 {
        return delta.beforeLength() / 2;
    }

    pub fn afterLength(delta: *const EffectiveZDelta) u32 {
        var len: u32 = @intCast(delta.insert_text.len);
        for (delta.ops) |op| {
            switch (op.current) {
                .equal => |span| len += span.len(),
                .insert, .delete => {},
            }
        }
        return len;
    }

    fn padding(delta: *const EffectiveZDelta) struct { u32, u32 } {
        const mid = delta.midpoint();
        var t_idx: u32 = 0;
        var head_now: i64 = 0;
        var tail_now: i64 = 0;
        var head_max: i64 = 0;
        var tail_max: i64 = 0;

        for (delta.ops) |op| {
            switch (op.current) {
                .equal => |span| {
                    t_idx += span.len();
                },
                .delete => |span| {
                    const len = span.len();
                    if (t_idx < mid) {
                        head_now -= len;
                    } else {
                        tail_now -= len;
                    }
                },
                .insert => |insert| {
                    const len = insert.len();
                    if (t_idx < mid) {
                        head_now += len;
                    } else {
                        tail_now += len;
                    }
                    t_idx += len;
                },
            }
            head_max = @max(head_max, head_now);
            tail_max = @max(tail_max, tail_now);
        }

        return .{
            cast(u32, @max(@as(i64, 0), head_max)),
            cast(u32, @max(@as(i64, 0), tail_max)),
        };
    }

    pub fn textNumbers(delta: *const EffectiveZDelta) struct { u32, u32, u32 } {
        const before_len = delta.beforeLength();
        const pre_padding, const post_padding = delta.padding();
        return .{
            before_len,
            pre_padding,
            post_padding,
        };
    }

    pub fn totalChange(delta: *const EffectiveZDelta) i33 {
        var change: i33 = 0;
        for (delta.ops) |op| {
            switch (op.current) {
                .insert => |insert| change += cast(i33, insert.len()),
                .delete => |span| change -= cast(i33, span.len()),
                .equal => {},
            }
        }
        return change;
    }

    pub fn toOwnedRelativeOps(
        delta: *const EffectiveZDelta,
        allocator: Allocator,
    ) ![]RelativeDeltaOp {
        var relative = try allocator.alloc(RelativeDeltaOp, delta.ops.len);
        errdefer allocator.free(relative);
        for (delta.ops, 0..) |op, idx| {
            relative[idx] = .{
                .source_op_index = op.source_op_index,
                .original = effectToRelative(op.source),
                .current = effectToRelative(op.current),
                .state = op.state,
                .skip_index = op.skip_index,
            };
        }
        return relative;
    }

    pub fn replaceFromRelativeOps(
        delta: *EffectiveZDelta,
        allocator: Allocator,
        relative: []const RelativeDeltaOp,
    ) !void {
        const rebuilt = try fromRelativeOps(allocator, delta.insert_text, relative);
        allocator.free(delta.ops);
        delta.ops = rebuilt.ops;
        allocator.free(rebuilt.insert_text);
    }
};

// NOTE: Since the normal path to the below function is one which ends with
// the disposal of the 'raw_delta', we could do this destructively and move
// the text instead of duping it.  Playing it safe for now.
pub fn fromZDelta(allocator: Allocator, raw_delta: *const ZDelta) !EffectiveZDelta {
    const insert_text = try allocator.dupe(u8, raw_delta.insert_text);
    errdefer allocator.free(insert_text);

    const ops = try allocator.alloc(EffectiveDeltaOp, raw_delta.ops.len);
    errdefer allocator.free(ops);

    var source_cursor: u32 = 0;
    var current_cursor: u32 = 0;
    for (raw_delta.ops, 0..) |op, idx| {
        ops[idx] = .{
            .source_op_index = try checkedU32(idx),
            .source = convertSourceOp(op, &source_cursor),
            .current = convertCurrentOp(op, &current_cursor),
            .state = .unchanged,
            .skip_index = null,
        };
    }

    return .{
        .insert_text = insert_text,
        .ops = ops,
    };
}

fn fromRelativeOps(
    allocator: Allocator,
    insert_text: []const u8,
    relative: []const RelativeDeltaOp,
) !EffectiveZDelta {
    const ops = try allocator.alloc(EffectiveDeltaOp, relative.len);
    errdefer allocator.free(ops);

    var source_cursor: u32 = 0;
    var current_cursor: u32 = 0;
    for (relative, 0..) |op, idx| {
        ops[idx] = .{
            .source_op_index = op.source_op_index,
            .source = convertSourceOp(op.original, &source_cursor),
            .current = convertCurrentOp(op.current, &current_cursor),
            .state = op.state,
            .skip_index = op.skip_index,
        };
    }

    return .{
        .insert_text = try allocator.dupe(u8, insert_text),
        .ops = ops,
    };
}

fn convertSourceOp(op: DeltaOp, cursor: *u32) EffectiveOp {
    return switch (op) {
        .equal => |len| blk: {
            const start = cursor.*;
            cursor.* += len;
            break :blk .{ .equal = .{ .start = start, .end = cursor.* } };
        },
        .delete => |len| blk: {
            const start = cursor.*;
            cursor.* += len;
            break :blk .{ .delete = .{ .start = start, .end = cursor.* } };
        },
        .insert => |span| .{ .insert = .{ .at = cursor.*, .text = span } },
    };
}

fn convertCurrentOp(op: DeltaOp, cursor: *u32) EffectiveOp {
    return switch (op) {
        .equal => |len| blk: {
            const start = cursor.*;
            cursor.* += len;
            break :blk .{ .equal = .{ .start = start, .end = cursor.* } };
        },
        .delete => |len| blk: {
            const start = cursor.*;
            break :blk .{ .delete = .{ .start = start, .end = start + len } };
        },
        .insert => |span| blk: {
            const at = cursor.*;
            cursor.* += span.len;
            break :blk .{ .insert = .{ .at = at, .text = span } };
        },
    };
}

fn effectToRelative(effect: EffectiveOp) DeltaOp {
    return switch (effect) {
        .equal => |span| .{ .equal = span.len() },
        .delete => |span| .{ .delete = span.len() },
        .insert => |insert| .{ .insert = insert.text },
    };
}

fn checkedU32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.ZDeltaTooLarge;
}

//| Tests

const testing = std.testing;

fn testRawZDelta(
    allocator: Allocator,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !ZDelta {
    const owned_insert_text = try allocator.dupe(u8, insert_text);
    errdefer allocator.free(owned_insert_text);
    return .{
        .version = .b,
        .insert_text = owned_insert_text,
        .ops = try allocator.dupe(DeltaOp, ops),
    };
}

test "effective conversion produces objective coordinates" {
    const allocator = testing.allocator;
    var raw = try testRawZDelta(allocator, "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer raw.deinit(allocator);

    var effective = try fromZDelta(allocator, &raw);
    defer effective.deinit(allocator);

    try testing.expectEqualDeep(
        EffectiveOp{ .insert = .{ .at = 0, .text = .{ .offset = 0, .len = 1 } } },
        effective.ops[0].current,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .equal = .{ .start = 1, .end = 3 } },
        effective.ops[1].current,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .delete = .{ .start = 3, .end = 4 } },
        effective.ops[2].current,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .insert = .{ .at = 3, .text = .{ .offset = 1, .len = 1 } } },
        effective.ops[3].current,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .equal = .{ .start = 4, .end = 5 } },
        effective.ops[4].current,
    );
}

test "effective conversion preserves source coordinates" {
    const allocator = testing.allocator;
    var raw = try testRawZDelta(allocator, "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer raw.deinit(allocator);

    var effective = try fromZDelta(allocator, &raw);
    defer effective.deinit(allocator);

    try testing.expectEqual(@as(u32, 0), effective.ops[0].source_op_index);
    try testing.expectEqualDeep(
        EffectiveOp{ .insert = .{ .at = 0, .text = .{ .offset = 0, .len = 1 } } },
        effective.ops[0].source,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .equal = .{ .start = 0, .end = 2 } },
        effective.ops[1].source,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .delete = .{ .start = 2, .end = 3 } },
        effective.ops[2].source,
    );
    try testing.expectEqualDeep(
        EffectiveOp{ .insert = .{ .at = 3, .text = .{ .offset = 1, .len = 1 } } },
        effective.ops[3].source,
    );
}

test "effective conversion starts unchanged" {
    const allocator = testing.allocator;
    var raw = try testRawZDelta(allocator, "", &.{
        .{ .equal = 2 },
    });
    defer raw.deinit(allocator);

    var effective = try fromZDelta(allocator, &raw);
    defer effective.deinit(allocator);

    try testing.expectEqual(EffectiveOpState.unchanged, effective.ops[0].state);
    try testing.expectEqual(@as(?u32, null), effective.ops[0].skip_index);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const common_apply = @import("common.zig");
const common = @import("../dmp/common.zig");
const zdelta_mod = @import("../zdelta.zig");
const cast = common.cast;
const DeltaOp = common_apply.DeltaOp;
const DeltaSpan = common_apply.DeltaSpan;
const ZDelta = zdelta_mod.ZDelta;
