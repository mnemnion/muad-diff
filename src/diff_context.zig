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

pub fn fromDiff(allocator: Allocator, diff: dmp.Diff) OOM!DiffContext {
    var ctx: DiffContext = .default;
    errdefer ctx.deinit(allocator);

    try ctx.items.ensureTotalCapacity(allocator, diff.edits.items.len);

    var pre_line: u32 = 1;
    var post_line: u32 = 1;
    for (diff.edits.items) |edit| {
        const newline_count = countNewlines(edit.text);
        const line_delta: u32 = @intCast(newline_count);
        const other_pre = anchorForeignLine(pre_line, edit.text);
        const other_post = anchorForeignLine(post_line, edit.text);

        switch (edit.operation) {
            .equal => ctx.items.appendAssumeCapacity(.{
                .edit = try edit.copy(allocator),
                .pre_start = pre_line,
                .pre_end = pre_line + line_delta,
                .post_start = post_line,
                .post_end = post_line + line_delta,
            }),
            .delete => ctx.items.appendAssumeCapacity(.{
                .edit = try edit.copy(allocator),
                .pre_start = pre_line,
                .pre_end = pre_line + line_delta,
                .post_start = other_post,
                .post_end = other_post,
            }),
            .insert => ctx.items.appendAssumeCapacity(.{
                .edit = try edit.copy(allocator),
                .pre_start = other_pre,
                .pre_end = other_pre,
                .post_start = post_line,
                .post_end = post_line + line_delta,
            }),
        }

        switch (edit.operation) {
            .equal => {
                pre_line += line_delta;
                post_line += line_delta;
            },
            .delete => pre_line += line_delta,
            .insert => post_line += line_delta,
        }
    }

    return ctx;
}

pub fn deinit(ctx: *DiffContext, allocator: Allocator) void {
    deinitEditContextList(allocator, &ctx.items);
    ctx.items = .empty;
}

pub fn render(
    ctx: DiffContext,
    writer: anytype,
    deco: DiffDecorations,
    name: []const u8,
    show_lines: usize,
) !usize {
    var written: usize = 0;
    var line_start = true;
    written += try writeAllCounting(writer, "diff -- ");
    written += try writeAllCounting(writer, name);
    written += try writeAllCounting(writer, "\n");

    for (ctx.items.items, 0..) |item, index| {
        if (item.edit.operation != .equal) {
            written += try writeEditLines(writer, deco, item.edit, null, null, &line_start);
            continue;
        }

        const line_count = countDisplayLines(item.edit.text);
        if (line_count == 0 or line_count <= show_lines) {
            written += try writeEditLines(writer, deco, item.edit, null, null, &line_start);
            continue;
        }

        const is_first = index == 0;
        const is_last = index + 1 == ctx.items.items.len;
        const keep_head = if (is_last) show_lines else if (is_first) 0 else show_lines;
        const keep_tail = if (is_first) show_lines else if (is_last) 0 else show_lines;

        if (line_count <= keep_head + keep_tail) {
            written += try writeEditLines(writer, deco, item.edit, null, null, &line_start);
            continue;
        }

        if (keep_head != 0) {
            const head_end = byteOffsetAfterLines(item.edit.text, keep_head);
            written += try writeEditLines(writer, deco, item.edit, 0, head_end, &line_start);
        }

        const elision_line_offset = if (keep_head != 0 and keep_tail == 0)
            keep_head
        else
            line_count - keep_tail;
        if (is_last and keep_tail == 0) {
            written += try writeEofLine(writer, &line_start);
        } else {
            written += try writeElisionLine(writer, deco, item, elision_line_offset, &line_start);
        }

        if (keep_tail != 0) {
            const tail_start = byteOffsetAfterLines(item.edit.text, line_count - keep_tail);
            written += try writeEditLines(writer, deco, item.edit, tail_start, null, &line_start);
        }
    }

    try flushWriter(writer);
    return written;
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

fn countDisplayLines(text: []const u8) usize {
    if (text.len == 0) return 0;

    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn anchorForeignLine(current_line: u32, text: []const u8) u32 {
    if (text.len != 0 and text[0] == '\n' and current_line > 0) {
        return current_line - 1;
    }
    return current_line;
}

fn nextDisplayLine(text: []const u8, cursor: usize) ?struct { line: []const u8, next: usize } {
    if (cursor >= text.len) return null;

    const suffix = text[cursor..];
    if (std.mem.indexOfScalar(u8, suffix, '\n')) |nl| {
        const end = cursor + nl + 1;
        return .{ .line = text[cursor..end], .next = end };
    }

    return .{ .line = text[cursor..], .next = text.len };
}

fn byteOffsetAfterLines(text: []const u8, lines: usize) usize {
    if (lines == 0) return 0;
    if (text.len == 0) return 0;

    var cursor: usize = 0;
    var remaining = lines;
    while (remaining > 0) {
        const part = nextDisplayLine(text, cursor) orelse return text.len;
        cursor = part.next;
        remaining -= 1;
    }
    return cursor;
}

fn writeEditLines(
    writer: anytype,
    deco: DiffDecorations,
    edit: Edit,
    start_offset_opt: ?usize,
    end_offset_opt: ?usize,
    line_start: *bool,
) !usize {
    const text_start = start_offset_opt orelse 0;
    const text_end = end_offset_opt orelse edit.text.len;
    const text = edit.text[text_start..text_end];

    var written: usize = 0;
    var cursor: usize = 0;
    while (nextDisplayLine(text, cursor)) |part| {
        if (line_start.*) {
            written += try writeBlankGutter(writer);
            line_start.* = false;
        }
        const fragment_start = text_start + cursor;
        const fragment_end = text_start + part.next;
        written += try writeDecoratedSlice(
            writer,
            deco,
            edit.operation,
            edit.text,
            fragment_start,
            fragment_end,
        );
        if (part.line.len != 0 and part.line[part.line.len - 1] == '\n') {
            line_start.* = true;
        }
        cursor = part.next;
    }
    return written;
}

fn writeDecoratedText(writer: anytype, deco: DiffDecorations, edit: Edit) !usize {
    return dmp.writeDecoratedEdit(std.heap.page_allocator, writer, deco, edit);
}

fn writeDecoratedSlice(
    writer: anytype,
    deco: DiffDecorations,
    operation: Edit.Operation,
    full_text: []const u8,
    fragment_start: usize,
    fragment_end: usize,
) !usize {
    const fragment = full_text[fragment_start..fragment_end];
    const markers: struct {
        start: []const u8,
        end: []const u8,
        ws_start: []const u8,
        ws_end: []const u8,
    } = switch (operation) {
        .delete => .{
            .start = deco.delete_start,
            .end = deco.delete_end,
            .ws_start = deco.d_ws_start,
            .ws_end = deco.d_ws_end,
        },
        .insert => .{
            .start = deco.insert_start,
            .end = deco.insert_end,
            .ws_start = deco.i_ws_start,
            .ws_end = deco.i_ws_end,
        },
        .equal => .{
            .start = deco.equals_start,
            .end = deco.equals_end,
            .ws_start = "",
            .ws_end = "",
        },
    };

    var written: usize = 0;
    written += try writeAllCounting(writer, markers.start);

    if (operation == .equal or markers.ws_start.len == 0) {
        written += try writeProcessedSegment(writer, operation, deco, fragment);
        written += try writeAllCounting(writer, markers.end);
        return written;
    }

    const left_trimmed = std.mem.trimStart(u8, full_text, &std.ascii.whitespace);
    const leading_end = full_text.len - left_trimmed.len;
    const middle = std.mem.trimEnd(u8, left_trimmed, &std.ascii.whitespace);
    const trailing_start = leading_end + middle.len;

    if (fragment_start < leading_end) {
        const ws_end = @min(fragment_end, leading_end);
        written += try writeAllCounting(writer, markers.ws_start);
        written += try writeProcessedSegment(writer, operation, deco, full_text[fragment_start..ws_end]);
        written += try writeAllCounting(writer, markers.ws_end);
    }

    const middle_start = @max(fragment_start, leading_end);
    const middle_end = @min(fragment_end, trailing_start);
    if (middle_start < middle_end) {
        written += try writeProcessedSegment(writer, operation, deco, full_text[middle_start..middle_end]);
    }

    if (trailing_start < fragment_end) {
        const ws_start = @max(fragment_start, trailing_start);
        written += try writeAllCounting(writer, markers.ws_start);
        written += try writeProcessedSegment(writer, operation, deco, full_text[ws_start..fragment_end]);
        written += try writeAllCounting(writer, markers.ws_end);
    }

    written += try writeAllCounting(writer, markers.end);
    return written;
}

fn writeProcessedSegment(
    writer: anytype,
    operation: Edit.Operation,
    deco: DiffDecorations,
    text: []const u8,
) !usize {
    if (deco.pre_process) |lambda| {
        const allocator = std.heap.page_allocator;
        const processed = try lambda(allocator, Edit.asBorrow(operation, text));
        defer allocator.free(processed);
        return writeAllCounting(writer, processed);
    }

    return writeAllCounting(writer, text);
}

fn writeElisionLine(
    writer: anytype,
    deco: DiffDecorations,
    item: EditContext,
    line_offset: usize,
    line_start: *bool,
) !usize {
    const line_no = lineNumbersAtOffset(item, line_offset);
    var before_buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
    const before_text = try std.fmt.bufPrint(&before_buf, "{d}", .{line_no.pre});
    var after_buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
    const after_text = try std.fmt.bufPrint(&after_buf, "{d}", .{line_no.post});

    var written: usize = 0;
    if (!line_start.*) {
        written += try writeAllCounting(writer, "\n");
    }
    written += try writeBlankGutter(writer);
    written += try writeAllCounting(writer, "...");
    written += try writeAllCounting(writer, " ");
    written += try writeDecoratedText(writer, deco, Edit.asBorrow(.delete, before_text));
    written += try writeAllCounting(writer, ";");
    written += try writeDecoratedText(writer, deco, Edit.asBorrow(.insert, after_text));
    written += try writeAllCounting(writer, "\n");
    line_start.* = true;
    return written;
}

fn writeEofLine(writer: anytype, line_start: *bool) !usize {
    var written: usize = 0;
    if (!line_start.*) {
        written += try writeAllCounting(writer, "\n");
    }
    written += try writeBlankGutter(writer);
    written += try writeAllCounting(writer, "---[eof]---\n\n");
    line_start.* = true;
    return written;
}

fn lineNumbersAtOffset(item: EditContext, line_offset: usize) struct { pre: u32, post: u32 } {
    const offset: u32 = @intCast(line_offset);
    return .{
        .pre = item.pre_start + offset,
        .post = item.post_start + offset,
    };
}

fn writeBlankGutter(writer: anytype) !usize {
    return writeByteCounting(writer, ' ');
}

fn flushWriter(writer: anytype) !void {
    const Writer = @TypeOf(writer);
    switch (@typeInfo(Writer)) {
        .pointer => |pointer| {
            if (@hasDecl(pointer.child, "flush")) {
                try writer.flush();
            }
        },
        else => {
            if (@hasDecl(Writer, "flush")) {
                var w = writer;
                try w.flush();
            }
        },
    }
}

fn writeAllCounting(writer: anytype, text: []const u8) !usize {
    try writer.writeAll(text);
    return text.len;
}

fn writeByteCounting(writer: anytype, byte: u8) !usize {
    try writer.writeByte(byte);
    return 1;
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

fn appendBorrowedContext(
    ctx: *DiffContext,
    operation: Edit.Operation,
    text: []const u8,
) !void {
    var pre_line: u32 = 1;
    var post_line: u32 = 1;
    for (ctx.items.items) |item| {
        const line_delta: u32 = @intCast(countNewlines(item.edit.text));
        switch (item.edit.operation) {
            .equal => {
                pre_line += line_delta;
                post_line += line_delta;
            },
            .delete => pre_line += line_delta,
            .insert => post_line += line_delta,
        }
    }

    const line_delta: u32 = @intCast(countNewlines(text));
    const other_pre = anchorForeignLine(pre_line, text);
    const other_post = anchorForeignLine(post_line, text);
    try ctx.items.append(testing.allocator, .{
        .edit = Edit.asBorrow(operation, text),
        .pre_start = switch (operation) {
            .insert => other_pre,
            .delete, .equal => pre_line,
        },
        .pre_end = switch (operation) {
            .insert => other_pre,
            .delete, .equal => pre_line + line_delta,
        },
        .post_start = switch (operation) {
            .delete => other_post,
            .insert, .equal => post_line,
        },
        .post_end = switch (operation) {
            .delete => other_post,
            .insert, .equal => post_line + line_delta,
        },
    });
}

fn renderForTest(
    ctx: DiffContext,
    deco: DiffDecorations,
    show_lines: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit(); // kcov-test-cleanup
    const bytes_written = try ctx.render(&out.writer, deco, "sample", show_lines);
    try testing.expectEqual(bytes_written, out.writer.end);
    return out.toOwnedSlice();
}

test "render outputs short equal lines in full" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "alpha\nbeta\n");

    const rendered = try renderForTest(ctx, .{}, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n alpha\n beta\n",
        rendered,
    );
}

test "render truncates oversized middle equal context" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .delete, "before\n");
    try appendBorrowedContext(&ctx, .equal, "one\ntwo\nthree\nfour\nfive\n");
    try appendBorrowedContext(&ctx, .insert, "after\n");

    const rendered = try renderForTest(ctx, .{}, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n before\n one\n two\n ... 5;4\n four\n five\n after\n",
        rendered,
    );
}

test "render truncates oversized leading equal context toward first edit" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "one\ntwo\nthree\nfour\n");
    try appendBorrowedContext(&ctx, .insert, "after\n");

    const rendered = try renderForTest(ctx, .{}, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n ... 3;3\n three\n four\n after\n",
        rendered,
    );
}

test "render truncates oversized trailing equal context away from last edit" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .delete, "before\n");
    try appendBorrowedContext(&ctx, .equal, "one\ntwo\nthree\nfour\n");

    const rendered = try renderForTest(ctx, .{}, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n before\n one\n two\n ---[eof]---\n\n",
        rendered,
    );
}

test "render truncates oversized equal-only diff from the leading side" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "one\ntwo\nthree\nfour\n");

    const rendered = try renderForTest(ctx, .{}, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n one\n two\n three\n four\n",
        rendered,
    );
}

test "render with zero context emits only separators for truncated equals" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .delete, "before\n");
    try appendBorrowedContext(&ctx, .equal, "one\ntwo\n");
    try appendBorrowedContext(&ctx, .insert, "after\n");

    const rendered = try renderForTest(ctx, .{}, 0);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n before\n ... 4;3\n after\n",
        rendered,
    );
}

test "render handles mid-line fragments without line normalization" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "pre");
    try appendBorrowedContext(&ctx, .insert, "MID");
    try appendBorrowedContext(&ctx, .equal, "post\nnext");

    const rendered = try renderForTest(ctx, .{}, 1);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n preMIDpost\n ---[eof]---\n\n",
        rendered,
    );
}

test "render decorations wrap only the line body" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "same\n");
    try appendBorrowedContext(&ctx, .delete, "gone\n");
    try appendBorrowedContext(&ctx, .insert, "new\n");

    const rendered = try renderForTest(ctx, .{
        .equals_start = "<e>",
        .equals_end = "</e>",
        .delete_start = "<d>",
        .delete_end = "</d>",
        .insert_start = "<i>",
        .insert_end = "</i>",
    }, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n <e>same\n</e> <d>gone\n</d> <i>new\n</i>",
        rendered,
    );
}

test "render elision decorates before and after line numbers independently" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "one\ntwo\nthree\nfour\n");

    const rendered = try renderForTest(ctx, .{
        .delete_start = "<d>",
        .delete_end = "</d>",
        .insert_start = "<i>",
        .insert_end = "</i>",
    }, 2);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n one\n two\n three\n four\n",
        rendered,
    );
}

fn preProcessUpper(allocator: Allocator, edit: Edit) OOM![]const u8 {
    const out = try allocator.dupe(u8, edit.text);
    for (out) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }
    return out;
}

test "render honors pre_process per emitted line" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .equal, "alpha\nbeta");

    const rendered = try renderForTest(ctx, .{
        .pre_process = preProcessUpper,
    }, 3);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n ALPHA\n BETA",
        rendered,
    );
}

test "render decorates edit edge whitespace when configured" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .delete, "  gone\t");
    try appendBorrowedContext(&ctx, .insert, "\tnew  ");

    const rendered = try renderForTest(ctx, .{
        .delete_start = "<d>",
        .delete_end = "</d>",
        .d_ws_start = "<dw>",
        .d_ws_end = "</dw>",
        .insert_start = "<i>",
        .insert_end = "</i>",
        .i_ws_start = "<iw>",
        .i_ws_end = "</iw>",
    }, 3);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n <d><dw>  </dw>gone<dw>\t</dw></d><i><iw>\t</iw>new<iw>  </iw></i>",
        rendered,
    );
}

test "render only backgrounds true edit-edge whitespace across multiple lines" {
    var ctx: DiffContext = .default;
    defer ctx.deinit(testing.allocator);
    try appendBorrowedContext(&ctx, .insert, " head\n  body\n ");

    const rendered = try renderForTest(ctx, .{
        .insert_start = "<i>",
        .insert_end = "</i>",
        .i_ws_start = "<iw>",
        .i_ws_end = "</iw>",
    }, 3);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        "diff -- sample\n <i><iw> </iw>head\n</i> <i>  body<iw>\n</iw></i> <i><iw> </iw></i>",
        rendered,
    );
}

const DiffContext = @This();

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const dmp = @import("dmp.zig");
const Edit = dmp.Edit;
const DiffDecorations = dmp.DiffDecorations;
