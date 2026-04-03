//! Screen-bounded contextualization helpers for interactive zdelta inspection.

const std = @import("std");
const dmp = @import("../dmp.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Edit = dmp.Edit;
const DiffContext = dmp.DiffContext;

pub const RenderSettings = struct {
    page_lines: usize = 20,
    prompt_lines: usize = 5,
    whole_delta_context_lines: usize = 2,
    edit_context_lines: usize = 2,

    fn bodyLineBudget(settings: RenderSettings) usize {
        if (settings.page_lines <= settings.prompt_lines) return 1;
        return settings.page_lines - settings.prompt_lines;
    }
};

pub const PageLine = union(enum) {
    header: []u8,
    diff: struct {
        operation: Edit.Operation,
        text: []u8,
    },
    elision: ElisionLine,
    eof_marker: void,
    truncated: void,

    fn deinit(line: *PageLine, allocator: Allocator) void {
        switch (line.*) {
            .header => |text| allocator.free(text),
            .diff => |diff| allocator.free(diff.text),
            .elision, .eof_marker, .truncated => {},
        }
        line.* = undefined;
    }
};

pub const ElisionLine = struct {
    before: u32,
    after: u32,
};

pub const Page = struct {
    lines: ArrayList(PageLine),

    pub fn init(allocator: Allocator) Page {
        return .{ .lines = ArrayList(PageLine).init(allocator) };
    }

    pub fn deinit(page: *Page) void {
        for (page.lines.items) |*line| line.deinit(page.lines.allocator);
        page.lines.deinit();
        page.* = undefined;
    }
};

pub fn buildWholeDeltaPage(
    allocator: Allocator,
    before: []const u8,
    after: []const u8,
    name: []const u8,
    settings: RenderSettings,
) !Page {
    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);

    var ctx = try dmp.DiffContext.fromDiff(allocator, diff);
    defer ctx.deinit(allocator);
    return buildBoundedContextPage(
        allocator,
        ctx,
        name,
        settings.whole_delta_context_lines,
        settings.bodyLineBudget(),
    );
}

pub fn buildEditPage(
    allocator: Allocator,
    before: []const u8,
    at: u32,
    op: dmp.DeltaOp,
    insert_source: []const u8,
    name: []const u8,
    settings: RenderSettings,
) !Page {
    const offset: usize = @intCast(at);
    const delete_len: usize = switch (op) {
        .delete => |len| len,
        .insert, .equal => 0,
    };
    const suffix_origin = offset + delete_len;
    const snippet_start = lineStartForContext(before, offset, settings.edit_context_lines);
    const snippet_end = lineEndForContext(before, suffix_origin, settings.edit_context_lines);
    const prefix = before[snippet_start..offset];
    const deleted = before[offset..suffix_origin];
    const suffix = before[suffix_origin..snippet_end];
    const inserted = switch (op) {
        .insert => |span| insert_source[span.offset..][0..span.len],
        .delete, .equal => "",
    };

    const excerpt_before = try join3(allocator, prefix, deleted, suffix);
    defer allocator.free(excerpt_before);
    const excerpt_after = try join3(allocator, prefix, inserted, suffix);
    defer allocator.free(excerpt_after);

    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, excerpt_before, excerpt_after);

    var ctx = try dmp.DiffContext.fromDiff(allocator, diff);
    defer ctx.deinit(allocator);
    return buildBoundedContextPage(
        allocator,
        ctx,
        name,
        settings.edit_context_lines,
        settings.bodyLineBudget(),
    );
}

fn buildBoundedContextPage(
    allocator: Allocator,
    ctx: DiffContext,
    name: []const u8,
    show_lines: usize,
    max_lines: usize,
) !Page {
    var page = Page.init(allocator);
    errdefer page.deinit();

    try appendHeaderLine(&page, name);

    for (ctx.items.items, 0..) |item, index| {
        if (item.edit.operation != .equal) {
            try appendEditLines(&page, item.edit, null, null);
            continue;
        }

        const line_count = countDisplayLines(item.edit.text);
        if (line_count == 0 or line_count <= show_lines) {
            try appendEditLines(&page, item.edit, null, null);
            continue;
        }

        const is_first = index == 0;
        const is_last = index + 1 == ctx.items.items.len;
        const keep_head = if (is_last) show_lines else if (is_first) 0 else show_lines;
        const keep_tail = if (is_first) show_lines else if (is_last) 0 else show_lines;

        if (line_count <= keep_head + keep_tail) {
            try appendEditLines(&page, item.edit, null, null);
            continue;
        }

        if (keep_head != 0) {
            const head_end = byteOffsetAfterLines(item.edit.text, keep_head);
            try appendEditLines(&page, item.edit, 0, head_end);
        }

        const elision_line_offset = if (keep_head != 0 and keep_tail == 0)
            keep_head
        else
            line_count - keep_tail;
        if (is_last and keep_tail == 0) {
            try page.lines.append(.{ .eof_marker = {} });
        } else {
            try page.lines.append(.{
                .elision = lineNumbersAtOffset(item, elision_line_offset),
            });
        }

        if (keep_tail != 0) {
            const tail_start = byteOffsetAfterLines(item.edit.text, line_count - keep_tail);
            try appendEditLines(&page, item.edit, tail_start, null);
        }
    }

    try truncatePage(&page, max_lines);
    return page;
}

fn truncatePage(page: *Page, max_lines: usize) !void {
    if (max_lines == 0) {
        for (page.lines.items) |*line| line.deinit(page.lines.allocator);
        page.lines.clearRetainingCapacity();
        return;
    }
    if (page.lines.items.len <= max_lines) return;

    const keep = if (max_lines > 0) max_lines - 1 else 0;
    for (page.lines.items[keep..]) |*line| line.deinit(page.lines.allocator);
    page.lines.shrinkRetainingCapacity(keep);
    try page.lines.append(.{ .truncated = {} });
}

fn appendHeaderLine(page: *Page, name: []const u8) !void {
    const text = try std.fmt.allocPrint(page.lines.allocator, "diff -- {s}", .{name});
    errdefer page.lines.allocator.free(text);
    try page.lines.append(.{ .header = text });
}

fn appendEditLines(
    page: *Page,
    edit: Edit,
    start_offset_opt: ?usize,
    end_offset_opt: ?usize,
) !void {
    const text_start = start_offset_opt orelse 0;
    const text_end = end_offset_opt orelse edit.text.len;
    const text = edit.text[text_start..text_end];

    var cursor: usize = 0;
    while (nextDisplayLine(text, cursor)) |part| {
        const owned = try page.lines.allocator.dupe(u8, part.line);
        errdefer page.lines.allocator.free(owned);
        try page.lines.append(.{
            .diff = .{
                .operation = edit.operation,
                .text = owned,
            },
        });
        cursor = part.next;
    }
}

fn join3(allocator: Allocator, a: []const u8, b: []const u8, c: []const u8) ![]u8 {
    var joined = try allocator.alloc(u8, a.len + b.len + c.len);
    @memcpy(joined[0..a.len], a);
    @memcpy(joined[a.len..][0..b.len], b);
    @memcpy(joined[a.len + b.len ..][0..c.len], c);
    return joined;
}

fn lineStartForContext(text: []const u8, at: usize, extra_lines: usize) usize {
    var idx = @min(at, text.len);
    while (idx > 0 and text[idx - 1] != '\n') idx -= 1;
    var remaining = extra_lines;
    while (idx > 0 and remaining != 0) : (remaining -= 1) {
        idx -= 1;
        while (idx > 0 and text[idx - 1] != '\n') idx -= 1;
    }
    return idx;
}

fn lineEndForContext(text: []const u8, at: usize, extra_lines: usize) usize {
    var idx = @min(at, text.len);
    var remaining = extra_lines + 1;
    while (idx < text.len and remaining != 0) {
        if (text[idx] == '\n') remaining -= 1;
        idx += 1;
    }
    return idx;
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

fn lineNumbersAtOffset(item: DiffContext.EditContext, line_offset: usize) ElisionLine {
    const offset: u32 = @intCast(line_offset);
    return .{
        .before = item.pre_start + offset,
        .after = item.post_start + offset,
    };
}

test "whole delta page truncates to the configured budget" {
    const allocator = std.testing.allocator;
    var page = try buildWholeDeltaPage(
        allocator,
        "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\n",
        "alpha\nbeta\ngamma changed\ndelta\nepsilon\nzeta\neta\n",
        "sample",
        .{
            .page_lines = 6,
            .prompt_lines = 1,
            .whole_delta_context_lines = 2,
        },
    );
    defer page.deinit();

    try std.testing.expectEqual(@as(usize, 5), page.lines.items.len);
    try std.testing.expectEqualStrings("diff -- sample", page.lines.items[0].header);
    try std.testing.expectEqual(.truncated, page.lines.items[4]);
}

test "whole delta page represents eof marker explicitly" {
    const allocator = std.testing.allocator;
    var page = try buildWholeDeltaPage(
        allocator,
        "before\none\ntwo\nthree\nfour\n",
        "one\ntwo\nthree\nfour\n",
        "sample",
        .{
            .page_lines = 10,
            .prompt_lines = 1,
            .whole_delta_context_lines = 2,
        },
    );
    defer page.deinit();

    var found_eof = false;
    for (page.lines.items) |line| {
        if (line == .eof_marker) found_eof = true;
    }
    try std.testing.expect(found_eof);
}

test "edit page includes inserted text in a diff line" {
    const allocator = std.testing.allocator;
    var page = try buildEditPage(
        allocator,
        "alpha\nbeta\ngamma\n",
        6,
        .{ .insert = .{ .offset = 0, .len = 6 } },
        "BRAVO\n",
        "edit",
        .{
            .page_lines = 10,
            .prompt_lines = 2,
            .edit_context_lines = 1,
        },
    );
    defer page.deinit();

    var found_insert = false;
    for (page.lines.items) |line| {
        switch (line) {
            .diff => |diff| {
                if (diff.operation == .insert and std.mem.containsAtLeast(u8, diff.text, 1, "BRAVO")) {
                    found_insert = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_insert);
}
