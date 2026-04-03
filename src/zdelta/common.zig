pub const DeltaSpan = struct {
    offset: u32,
    len: u32,
};

pub const DeltaOp = union(enum) {
    insert: DeltaSpan,
    delete: u32,
    equal: u32,
};

pub const HarmonizedOpState = enum {
    unchanged,
    rewritten,
    blocked,
};

pub const HarmonizedDeltaOp = struct {
    original: DeltaOp,
    effective: DeltaOp,
    state: HarmonizedOpState,
    skip_index: ?u32,

    pub fn fromRaw(op: DeltaOp) HarmonizedDeltaOp {
        return .{
            .original = op,
            .effective = op,
            .state = .unchanged,
            .skip_index = null,
        };
    }
};

pub const PreviewDeltaOp = struct {
    text_index: u32,
    delta_index: u32,
    op: HarmonizedDeltaOp,
};

pub const SkippedDeltaOp = struct {
    at: u32,
    z_idx: u32,
    op: DeltaOp,
    text: []u8,
    accounted_for_current_delta: bool,

    pub fn deinit(skipped: *SkippedDeltaOp, allocator: Allocator) void {
        allocator.free(skipped.text);
        skipped.* = undefined;
    }
};

const std = @import("std");

const Allocator = std.mem.Allocator;
