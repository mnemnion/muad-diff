//! Shared buffer-management policy for zdelta application.
//!
//! `DeltaApplicator` and `DeltaManager` intentionally share the same storage
//! model: active text lives inside a single slack buffer that can grow and
//! recenter around a pivot. That memory policy is independent from review-time
//! concerns like skipped history and harmonization, so it lives here instead of
//! being copy-pasted into both applicators.

pub fn rebase(state: anytype, new_start: u32) void {
    if (new_start == state.start) return;
    const active_len = state.end - state.start;
    @memmove(
        state.buffer[new_start..][0..active_len],
        state.buffer[state.start..][0..active_len],
    );
    state.start = new_start;
    state.end = new_start + active_len;
}

pub fn growForNeed(state: anytype, comptime growth_fudge: u32, need: u32) !void {
    if (need <= state.budget) return;
    const shortfall = need - state.budget;
    const growth = shortfall +| growth_fudge;
    const new_len = state.buffer.len + growth;
    state.buffer = try state.allocator.realloc(state.buffer, new_len);
    state.budget +|= growth;
}

pub fn ensureHeadRoom(state: anytype, comptime growth_fudge: u32, need: u32) !void {
    if (need <= state.start) return;
    if (need > state.budget) try growForNeed(state, growth_fudge, need);
    if (is_debug) dbgassert(need <= totalSlack(state));
    rebase(state, need);
}

pub fn ensureTailRoom(state: anytype, comptime growth_fudge: u32, need: u32) !void {
    const tail_room: u32 = @intCast(state.buffer.len - state.end);
    if (need <= tail_room) return;
    if (need > state.budget) try growForNeed(state, growth_fudge, need);
    if (is_debug) dbgassert(need <= totalSlack(state));
    rebase(state, totalSlack(state) - need);
}

pub fn totalSlack(state: anytype) u32 {
    return state.start + cast(u32, state.buffer.len) - state.end;
}

pub fn initialSlack(text_len: usize) !usize {
    if (text_len == 0) return 0;
    const twenty_percent = @divFloor(text_len - 1, 5) + 1;
    return if (twenty_percent % 2 == 0)
        twenty_percent
    else
        twenty_percent + 1;
}

pub fn checkedTextLen(text_len: usize) !u32 {
    return std.math.cast(u32, text_len) orelse error.ZDeltaTooLarge;
}

const TestState = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    start: u32,
    end: u32,
    budget: u32,

    fn init(allocator: std.mem.Allocator) !TestState {
        const buffer = try allocator.dupe(u8, "abcd__");
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .start = 0,
            .end = 4,
            .budget = 2,
        };
    }

    fn deinit(state: *TestState) void {
        state.allocator.free(state.buffer);
    }
};

fn testGrowForNeed(allocator: std.mem.Allocator) !void {
    var state = try TestState.init(allocator);
    defer state.deinit();

    try growForNeed(&state, 3, 5);

    try testing.expectEqual(@as(usize, 12), state.buffer.len);
    try testing.expectEqual(@as(u32, 8), state.budget);
}

test "growForNeed grows slack budget" {
    try testing.checkAllAllocationFailures(testing.allocator, testGrowForNeed, .{});
}

fn testEnsureHeadRoom(allocator: std.mem.Allocator) !void {
    var state = try TestState.init(allocator);
    defer state.deinit();

    try ensureHeadRoom(&state, 3, 5);

    try testing.expectEqual(@as(u32, 5), state.start);
    try testing.expectEqual(@as(u32, 9), state.end);
    try testing.expectEqualStrings("abcd", state.buffer[state.start..state.end]);
}

test "ensureHeadRoom grows and rebases when head slack is short" {
    try testing.checkAllAllocationFailures(testing.allocator, testEnsureHeadRoom, .{});
}

test "initialSlack rounds odd slack up to keep room balanced" {
    try testing.expectEqual(@as(usize, 0), try initialSlack(0));
    try testing.expectEqual(@as(usize, 2), try initialSlack(1));
    try testing.expectEqual(@as(usize, 2), try initialSlack(6));
}

const std = @import("std");
const builtin = @import("builtin");
const common = @import("../dmp/common.zig");
const dbgassert = common.dbgassert;
const cast = common.cast;
const is_debug = builtin.mode == .Debug;
const testing = std.testing;
