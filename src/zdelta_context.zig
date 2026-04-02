//! Screen-bounded rendering helpers for interactive zdelta inspection.

const std = @import("std");
const dmp = @import("dmp");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

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

pub fn renderWholeDelta(
    allocator: Allocator,
    writer: anytype,
    before: []const u8,
    after: []const u8,
    name: []const u8,
    deco: dmp.DiffDecorations,
    settings: RenderSettings,
) !void {
    var diff: dmp.Diff = .default;
    defer diff.deinit(allocator);
    _ = try diff.diff(allocator, before, after);

    var ctx = try dmp.DiffContext.fromDiff(allocator, diff);
    defer ctx.deinit(allocator);
    try renderBoundedContext(
        allocator,
        writer,
        ctx,
        deco,
        name,
        settings.whole_delta_context_lines,
        settings.bodyLineBudget(),
    );
}

pub fn renderEdit(
    allocator: Allocator,
    writer: anytype,
    before: []const u8,
    at: u32,
    op: dmp.DeltaOp,
    insert_source: []const u8,
    name: []const u8,
    deco: dmp.DiffDecorations,
    settings: RenderSettings,
) !void {
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
    try renderBoundedContext(
        allocator,
        writer,
        ctx,
        deco,
        name,
        settings.edit_context_lines,
        settings.bodyLineBudget(),
    );
}

fn renderBoundedContext(
    allocator: Allocator,
    writer: anytype,
    ctx: dmp.DiffContext,
    deco: dmp.DiffDecorations,
    name: []const u8,
    show_lines: usize,
    max_lines: usize,
) !void {
    var rendered = ArrayList(u8).init(allocator);
    defer rendered.deinit();
    const buffer_writer = rendered.writer();
    _ = try ctx.render(buffer_writer, deco, name, show_lines);
    try writeTruncatedLines(writer, rendered.items, max_lines);
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

fn writeTruncatedLines(writer: anytype, text: []const u8, max_lines: usize) !void {
    if (max_lines == 0) return;
    const total_lines = countLines(text);
    if (total_lines <= max_lines) {
        try writer.writeAll(text);
        return;
    }

    const keep_lines = if (max_lines > 1) max_lines - 1 else 0;
    const keep_end = byteOffsetAfterLines(text, keep_lines);
    if (keep_end != 0) {
        try writer.writeAll(text[0..keep_end]);
        if (text[keep_end - 1] != '\n') try writer.writeByte('\n');
    }
    try writer.writeAll("... [truncated]\n");
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;

    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;
    return count;
}

fn byteOffsetAfterLines(text: []const u8, line_count: usize) usize {
    if (line_count == 0) return 0;

    var seen: usize = 0;
    for (text, 0..) |byte, idx| {
        if (byte != '\n') continue;
        seen += 1;
        if (seen == line_count) return idx + 1;
    }
    return text.len;
}

test "render whole delta truncates to the configured page" {
    const allocator = std.testing.allocator;
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();

    try renderWholeDelta(
        allocator,
        out.writer(),
        "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\n",
        "alpha\nbeta\ngamma changed\ndelta\nepsilon\nzeta\neta\n",
        "sample",
        .{},
        .{
            .page_lines = 6,
            .prompt_lines = 1,
            .whole_delta_context_lines = 2,
        },
    );

    try std.testing.expect(countLines(out.items) <= 5);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "diff -- sample"));
}

test "render edit shows inserted text" {
    const allocator = std.testing.allocator;
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();

    try renderEdit(
        allocator,
        out.writer(),
        "alpha\nbeta\ngamma\n",
        6,
        .{ .insert = .{ .offset = 0, .len = 6 } },
        "BRAVO\n",
        "edit",
        .{},
        .{
            .page_lines = 10,
            .prompt_lines = 2,
            .edit_context_lines = 1,
        },
    );

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "BRAVO"));
}
