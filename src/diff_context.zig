//! DiffContext represents a collection of edit contexts suitable for focused
//! diff displays.
//!
//! Each `EditContext` stores one `Edit` plus the inclusive line spans it
//! occupies in the before text (`pre_*`) and after text (`post_*`).
//!
//! Line spans are human-facing, 1-based, and inclusive. A single-line edit has
//! `start == end`; otherwise the end line advances by the count of `'\n'`
//! bytes in the edit text, including a trailing newline.
//!
//! Inserts and deletes don't have a location in the other document, meaning
//! we need a convention for how to represent them if followed immediately by
//! a newline.  We use the prior line, which, for inserts and deletes at the
//! top of the document, is `0`.

//| Fields

items: EditContextList = .empty,

//| Public Declarations

pub const EditContext = struct {
    edit: Edit,
    pre_start: u32,
    pre_end: u32,
    post_start: u32,
    post_end: u32,

    pub fn own(ctx: *EditContext, allocator: Allocator) OOM!void {
        try ctx.edit.own(allocator);
    }

    pub fn clone(ctx: EditContext, allocator: Allocator) OOM!EditContext {
        return .{
            .edit = try ctx.edit.clone(allocator),
            .pre_start = ctx.pre_start,
            .pre_end = ctx.pre_end,
            .post_start = ctx.post_start,
            .post_end = ctx.post_end,
        };
    }

    pub fn copy(ctx: EditContext, allocator: Allocator) OOM!EditContext {
        return .{
            .edit = try ctx.edit.copy(allocator),
            .pre_start = ctx.pre_start,
            .pre_end = ctx.pre_end,
            .post_start = ctx.post_start,
            .post_end = ctx.post_end,
        };
    }

    pub fn deinit(ctx: *EditContext, allocator: Allocator) void {
        ctx.edit.deinit(allocator);
    }
};

pub const EditContextList = ArrayListUnmanaged(EditContext);

pub const default: DiffContext = .{
    .items = .empty,
};

pub fn own(ctx: *DiffContext, allocator: Allocator) OOM!void {
    for (ctx.items.items) |*item| {
        try item.own(allocator);
    }
}

pub fn clone(ctx: DiffContext, allocator: Allocator) OOM!DiffContext {
    return .{
        .items = try cloneEditContextList(allocator, &ctx.items),
    };
}

pub fn copy(ctx: DiffContext, allocator: Allocator) OOM!DiffContext {
    return .{
        .items = try copyEditContextList(allocator, &ctx.items),
    };
}

pub fn deinit(ctx: *DiffContext, allocator: Allocator) void {
    deinitEditContextList(allocator, &ctx.items);
    ctx.items = .empty;
}

//| Private

fn deinitEditContextList(allocator: Allocator, items: *EditContextList) void {
    defer items.deinit(allocator);
    for (items.items) |*item| {
        item.deinit(allocator);
    }
}

fn cloneEditContextList(allocator: Allocator, items: *const EditContextList) OOM!EditContextList {
    var new_items: EditContextList = .empty;
    errdefer deinitEditContextList(allocator, &new_items);
    try new_items.ensureTotalCapacity(allocator, items.items.len);
    for (items.items) |item| {
        new_items.appendAssumeCapacity(try item.clone(allocator));
    }
    return new_items;
}

fn copyEditContextList(allocator: Allocator, items: *const EditContextList) OOM!EditContextList {
    var new_items: EditContextList = .empty;
    errdefer deinitEditContextList(allocator, &new_items);
    try new_items.ensureTotalCapacity(allocator, items.items.len);
    for (items.items) |item| {
        new_items.appendAssumeCapacity(try item.copy(allocator));
    }
    return new_items;
}

fn sampleContext(allocator: Allocator, owned: bool) OOM!EditContext {
    return .{
        .edit = try Edit.asBool(allocator, .insert, owned, "alpha\nbeta\n"),
        .pre_start = 0,
        .pre_end = 0,
        .post_start = 1,
        .post_end = 3,
    };
}

fn appendSample(allocator: Allocator, ctx: *DiffContext, owned: bool) OOM!void {
    var item = try sampleContext(allocator, owned);
    errdefer item.deinit(allocator);
    try ctx.items.append(allocator, item);
}

test "default starts empty" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ctx.items.items.len);
}

fn testCopyPreservesOwnership(allocator: Allocator) !void {
    var borrowed: DiffContext = .default;
    defer borrowed.deinit(allocator);
    try appendSample(allocator, &borrowed, false);

    const borrowed_copy = try borrowed.copy(allocator);
    var borrowed_copy_mut = borrowed_copy;
    defer borrowed_copy_mut.deinit(allocator);
    try testing.expectEqual(false, borrowed_copy_mut.items.items[0].edit.owned);
    try testing.expectEqualStrings(
        borrowed.items.items[0].edit.text,
        borrowed_copy_mut.items.items[0].edit.text,
    );
    try testing.expectEqual(@intFromPtr(borrowed.items.items[0].edit.text.ptr), @intFromPtr(borrowed_copy_mut.items.items[0].edit.text.ptr));

    var owned: DiffContext = .default;
    defer owned.deinit(allocator);
    try appendSample(allocator, &owned, true);

    const owned_copy = try owned.copy(allocator);
    var owned_copy_mut = owned_copy;
    defer owned_copy_mut.deinit(allocator);
    try testing.expectEqual(true, owned_copy_mut.items.items[0].edit.owned);
    try testing.expectEqualStrings(
        owned.items.items[0].edit.text,
        owned_copy_mut.items.items[0].edit.text,
    );
    try testing.expect(owned.items.items[0].edit.text.ptr != owned_copy_mut.items.items[0].edit.text.ptr);
}

test "copy preserves ownership semantics" {
    try testing.checkAllAllocationFailures(testing.allocator, testCopyPreservesOwnership, .{});
}

fn testCloneOwnsEditsIndependently(allocator: Allocator) !void {
    var ctx: DiffContext = .default;
    defer ctx.deinit(allocator);
    try appendSample(allocator, &ctx, false);

    const cloned = try ctx.clone(allocator);
    var cloned_mut = cloned;
    defer cloned_mut.deinit(allocator);
    try testing.expectEqual(true, cloned_mut.items.items[0].edit.owned);
    try testing.expectEqualStrings(ctx.items.items[0].edit.text, cloned_mut.items.items[0].edit.text);
    try testing.expect(ctx.items.items[0].edit.text.ptr != cloned_mut.items.items[0].edit.text.ptr);
}

test "clone owns edits independently" {
    try testing.checkAllAllocationFailures(testing.allocator, testCloneOwnsEditsIndependently, .{});
}

fn testOwnConvertsBorrowedEdits(allocator: Allocator) !void {
    var ctx: DiffContext = .default;
    defer ctx.deinit(allocator);
    try appendSample(allocator, &ctx, false);

    const before_ptr = ctx.items.items[0].edit.text.ptr;
    try ctx.own(allocator);
    try testing.expectEqual(true, ctx.items.items[0].edit.owned);
    try testing.expect(ctx.items.items[0].edit.text.ptr != before_ptr);
    try testing.expectEqualStrings("alpha\nbeta\n", ctx.items.items[0].edit.text);
}

test "own converts borrowed edits" {
    try testing.checkAllAllocationFailures(testing.allocator, testOwnConvertsBorrowedEdits, .{});
}

test "line metadata stores documented span semantics" {
    const single_line: EditContext = .{
        .edit = Edit.asBorrow(.equal, "single line"),
        .pre_start = 7,
        .pre_end = 7,
        .post_start = 9,
        .post_end = 9,
    };
    try testing.expectEqual(@as(u32, 7), single_line.pre_start);
    try testing.expectEqual(single_line.pre_start, single_line.pre_end);
    try testing.expectEqual(single_line.post_start, single_line.post_end);

    const multi_line: EditContext = .{
        .edit = Edit.asBorrow(.insert, "alpha\nbeta\ngamma"),
        .pre_start = 4,
        .pre_end = 4,
        .post_start = 10,
        .post_end = 12,
    };
    try testing.expectEqual(@as(u32, 10), multi_line.post_start);
    try testing.expectEqual(@as(u32, 12), multi_line.post_end);

    const trailing_newline: EditContext = .{
        .edit = Edit.asBorrow(.delete, "alpha\n"),
        .pre_start = 3,
        .pre_end = 4,
        .post_start = 2,
        .post_end = 2,
    };
    try testing.expectEqual(@as(u32, 4), trailing_newline.pre_end);

    const start_of_file_insert: EditContext = .{
        .edit = Edit.asBorrow(.insert, "intro"),
        .pre_start = 0,
        .pre_end = 0,
        .post_start = 1,
        .post_end = 1,
    };
    try testing.expectEqual(@as(u32, 0), start_of_file_insert.pre_start);
    try testing.expectEqual(start_of_file_insert.pre_start, start_of_file_insert.pre_end);
}

const DiffContext = @This();

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Diff = @import("dmp/Diff.zig");
const Edit = Diff.Edit;
