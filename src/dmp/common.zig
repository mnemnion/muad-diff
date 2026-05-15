/// De-initialize a *DiffList
pub fn deinitDiffList(allocator: Allocator, diffs: anytype) void {
    defer diffs.deinit(allocator);
    for (diffs.items) |*edit| {
        edit.deinit(allocator);
    }
}

/// Clone a diff list, including each edit's owned text.
pub fn cloneDiffList(
    allocator: Allocator,
    diffs: anytype,
) Allocator.Error!@TypeOf(diffs.*) {
    var new_diffs: @TypeOf(diffs.*) = .empty;
    try new_diffs.ensureTotalCapacity(allocator, diffs.items.len);
    errdefer deinitDiffList(allocator, &new_diffs);
    for (diffs.items) |*edit| {
        new_diffs.appendAssumeCapacity(try edit.clone(allocator));
    }
    return new_diffs;
}

/// Copy a diff list, preserving each edit's ownership status.
pub fn copyDiffList(
    allocator: Allocator,
    diffs: anytype,
) Allocator.Error!@TypeOf(diffs.*) {
    var new_diffs: @TypeOf(diffs.*) = .empty;
    try new_diffs.ensureTotalCapacity(allocator, diffs.items.len);
    errdefer deinitDiffList(allocator, &new_diffs);
    for (diffs.items) |*edit| {
        new_diffs.appendAssumeCapacity(try edit.copy(allocator));
    }
    return new_diffs;
}

/// True when every edit in the run is borrowed.
pub fn diffRunAllBorrowed(run: anytype) bool {
    for (run) |edit| {
        if (edit.owned) return false;
    }
    return true;
}

/// Return one contiguous borrow covering the entire run, when possible.
pub fn diffBorrowedRunSpan(run: anytype) ?[]const u8 {
    if (run.len == 0) return "";
    var span = run[0].text;
    for (run[1..]) |edit| {
        if (span.ptr + span.len != edit.text.ptr) return null;
        span = span.ptr[0 .. span.len + edit.text.len];
    }
    return span;
}

/// Materialize a run of edits into owned contiguous storage.
pub fn diffMaterializeRun(allocator: Allocator, run: anytype) Allocator.Error![]u8 {
    var total: usize = 0;
    for (run) |edit| total += edit.text.len;
    const text = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    for (run) |edit| {
        @memcpy(text[cursor..][0..edit.text.len], edit.text);
        cursor += edit.text.len;
    }
    return text;
}

/// Concatenate two slices into a single owned edit.
pub fn diffMakeOwnedConcat2(
    comptime EditType: type,
    allocator: Allocator,
    operation: EditType.Operation,
    a: []const u8,
    b: []const u8,
) Allocator.Error!EditType {
    const text = try allocator.alloc(u8, a.len + b.len);
    @memcpy(text[0..a.len], a);
    @memcpy(text[a.len..], b);
    return .{
        .operation = operation,
        .owned = true,
        .text = text,
    };
}

/// Return the length in bytes of the first shared UTF-8 code point.
pub fn hasSharedPrefixLen(a: []const u8, b: []const u8) ?usize {
    if (a.len == 0 or b.len == 0) return null;
    const a_len = std.unicode.utf8ByteSequenceLength(a[0]) catch return null;
    const b_len = std.unicode.utf8ByteSequenceLength(b[0]) catch return null;
    if (a_len != b_len or a_len > a.len or b_len > b.len) return null;
    if (!std.mem.eql(u8, a[0..a_len], b[0..b_len])) return null;
    return a_len;
}

/// Default boundary score used by semantic lossless cleanup.
pub fn diffCleanupSemanticScore(one: []const u8, two: []const u8) usize {
    if (one.len == 0 or two.len == 0) return 6;
    const char1 = one[one.len - 1];
    const char2 = two[0];
    const nonAlphaNumeric1 = !std.ascii.isAlphanumeric(char1);
    const nonAlphaNumeric2 = !std.ascii.isAlphanumeric(char2);
    const whitespace1 = nonAlphaNumeric1 and std.ascii.isWhitespace(char1);
    const whitespace2 = nonAlphaNumeric2 and std.ascii.isWhitespace(char2);
    const lineBreak1 = whitespace1 and std.ascii.isControl(char1);
    const lineBreak2 = whitespace2 and std.ascii.isControl(char2);
    const blankLine1 = lineBreak1 and
        (std.mem.endsWith(u8, one, "\n\n") or std.mem.endsWith(u8, one, "\n\r\n"));
    const blankLine2 = lineBreak2 and
        (std.mem.startsWith(u8, two, "\n\n") or
            std.mem.startsWith(u8, two, "\r\n\n") or
            std.mem.startsWith(u8, two, "\n\r\n") or
            std.mem.startsWith(u8, two, "\r\n\r\n"));
    if (blankLine1 or blankLine2) return 5;
    if (lineBreak1 or lineBreak2) return 4;
    if (nonAlphaNumeric1 and !whitespace1 and whitespace2) return 3;
    if (whitespace1 or whitespace2) return 2;
    if (nonAlphaNumeric1 or nonAlphaNumeric2) return 1;
    return 0;
}

/// loc is a location in text1; compute and return the equivalent location in text2.
pub fn diffIndex(diffs: anytype, u_loc: usize) usize {
    var chars1: isize = 0;
    var chars2: isize = 0;
    var last_chars1: isize = 0;
    var last_chars2: isize = 0;
    const loc: isize = @intCast(u_loc);
    var last_was_delete = false;
    var overshot = false;
    for (diffs.items) |edit| {
        if (edit.operation != .insert) chars1 += @intCast(edit.text.len);
        if (edit.operation != .delete) chars2 += @intCast(edit.text.len);
        if (chars1 > loc) {
            last_was_delete = edit.operation == .delete;
            overshot = true;
            break;
        }
    }
    last_chars1 = chars1;
    last_chars2 = chars2;
    if (overshot and last_was_delete) return @intCast(last_chars2);
    return @intCast(last_chars2 + (loc - last_chars1));
}

/// Compute and return the source text (all equalities and deletions).
pub fn diffBeforeText(allocator: Allocator, diffs: anytype) Allocator.Error![]const u8 {
    var chars: ArrayListUnmanaged(u8) = .empty;
    defer chars.deinit(allocator);
    for (diffs.items) |edit| {
        if (edit.operation != .insert) try chars.appendSlice(allocator, edit.text);
    }
    return chars.toOwnedSlice(allocator);
}

/// Compute and return the destination text (all equalities and insertions).
pub fn diffAfterText(allocator: Allocator, diffs: anytype) Allocator.Error![]const u8 {
    var chars: ArrayListUnmanaged(u8) = .empty;
    defer chars.deinit(allocator);
    for (diffs.items) |edit| {
        if (edit.operation != .delete) try chars.appendSlice(allocator, edit.text);
    }
    return chars.toOwnedSlice(allocator);
}

/// Free a range of edits inside a list.
pub fn freeRangeDiffList(
    allocator: Allocator,
    diffs: anytype,
    start: usize,
    len: usize,
) void {
    const after_range = start + len;
    for (diffs.items[start..after_range]) |*e| e.deinit(allocator);
}

/// Determine if the suffix of one string is the prefix of another.
pub fn diffCommonOverlap(text1_in: []const u8, text2_in: []const u8) usize {
    var text1 = text1_in;
    var text2 = text2_in;
    const text1_length = text1.len;
    const text2_length = text2.len;
    if (text1_length == 0 or text2_length == 0) return 0;
    if (text1_length > text2_length) {
        text1 = text1[text1_length - text2_length ..];
    } else if (text1_length < text2_length) {
        text2 = text2[0..text1_length];
    }
    const text_length = @min(text1_length, text2_length);
    if (std.mem.eql(u8, text1, text2)) return text_length;

    var best: usize = 0;
    var length: usize = 1;
    const best_idx = idx: while (true) {
        const pattern = text1[text_length - length ..];
        const found = std.mem.indexOf(u8, text2, pattern) orelse break :idx best;
        length += found;
        if (found == 0 or std.mem.eql(u8, text1[text_length - length ..], text2[0..length])) {
            best = length;
            length += 1;
        }
    };
    if (best_idx == 0) return best_idx;
    if (isFollow(text2[best_idx])) return fixSplitBackward(text2, best_idx);
    return best_idx;
}

/// Find a common prefix which respects UTF-8 code point boundaries.
pub fn diffCommonPrefix(before: []const u8, after: []const u8) usize {
    const n = @min(before.len, after.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (after[i] != before[i]) return fixSplitBackward(before, i);
    }
    return n;
}

/// Find a common suffix which respects UTF-8 code point boundaries.
pub fn diffCommonSuffix(before: []const u8, after: []const u8) usize {
    const n = @min(before.len, after.len);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        if (after[after.len - i] != before[before.len - i]) {
            return before.len - fixSplitForward(before, before.len - i + 1);
        }
    }
    return n;
}

/// Encode one u32 'plan 9' style, up to six bytes for the whole range.
pub fn plan9Encode(c: u31, out: []u8) u3 {
    const length = plan9Width(c);
    assert(out.len >= length);

    switch (length) {
        1 => out[0] = @as(u8, @intCast(c)),
        2 => {
            out[0] = @as(u8, @intCast(0b1100_0000 | (c >> 6)));
            out[1] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        3 => {
            out[0] = @as(u8, @intCast(0b1110_0000 | (c >> 12)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((c >> 6) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        4 => {
            out[0] = @as(u8, @intCast(0b1111_0000 | (c >> 18)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((c >> 12) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | ((c >> 6) & 0b0011_1111)));
            out[3] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        5 => {
            out[0] = @as(u8, @intCast(0b1111_1000 | (c >> 24)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((c >> 18) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | ((c >> 12) & 0b0011_1111)));
            out[3] = @as(u8, @intCast(0b1000_0000 | ((c >> 6) & 0b0011_1111)));
            out[4] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        6 => {
            out[0] = @as(u8, @intCast(0b1111_1100 | (c >> 30)));
            out[1] = @as(u8, @intCast(0b1000_0000 | ((c >> 24) & 0b0011_1111)));
            out[2] = @as(u8, @intCast(0b1000_0000 | ((c >> 18) & 0b0011_1111)));
            out[3] = @as(u8, @intCast(0b1000_0000 | ((c >> 12) & 0b0011_1111)));
            out[4] = @as(u8, @intCast(0b1000_0000 | ((c >> 6) & 0b0011_1111)));
            out[5] = @as(u8, @intCast(0b1000_0000 | (c & 0b0011_1111)));
        },
        else => unreachable,
    }

    return length;
}

pub fn plan9Width(c: u31) u3 {
    return switch (c) {
        0x0000_0000...0x0000_007f => 1,
        0x0000_0080...0x0000_07ff => 2,
        0x0000_0800...0x0000_ffff => 3,
        0x0001_0000...0x001f_ffff => 4,
        0x0020_0000...0x03ff_ffff => 5,
        0x0400_0000...0x7fff_ffff => 6,
    };
}

test "semantic score recognizes blank lines starting the right side" {
    try testing.expectEqual(@as(usize, 5), diffCleanupSemanticScore("x", "\n\nnext"));
    try testing.expectEqual(@as(usize, 5), diffCleanupSemanticScore("x", "\r\n\nnext"));
    try testing.expectEqual(@as(usize, 5), diffCleanupSemanticScore("x", "\n\r\nnext"));
}

test "plan9Encode covers every width class" {
    const cases = [_]struct {
        value: u31,
        expected: []const u8,
    }{
        .{ .value = 0x7f, .expected = &.{0x7f} },
        .{ .value = 0x80, .expected = &.{ 0xc2, 0x80 } },
        .{ .value = 0x800, .expected = &.{ 0xe0, 0xa0, 0x80 } },
        .{ .value = 0x10000, .expected = &.{ 0xf0, 0x90, 0x80, 0x80 } },
        .{ .value = 0x200000, .expected = &.{ 0xf8, 0x88, 0x80, 0x80, 0x80 } },
        .{ .value = 0x4000000, .expected = &.{ 0xfc, 0x84, 0x80, 0x80, 0x80, 0x80 } },
    };

    for (cases) |case| {
        var out: [6]u8 = undefined;
        const len = plan9Encode(case.value, &out);
        try testing.expectEqual(case.expected.len, len);
        try testing.expectEqualSlices(u8, case.expected, out[0..len]);

        var cursor: usize = 0;
        try testing.expectEqual(@as(u32, case.value), plan9DecodeCursor(out[0..len], &cursor));
        try testing.expectEqual(case.expected.len, cursor);
    }
}

pub fn plan9DecodeCursor(bytes: []const u8, cursor: *usize) u32 {
    var byte: u16 = bytes[cursor.*];
    cursor.* += 1;
    if (byte < 0x80) return byte;

    var class: u8 = byte_class[byte];
    var state: u8 = state_dfa[class];
    var codepoint: u32 = byte & class_mask[class];

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state * 16 + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state * 16 + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state * 16 + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    class = byte_class[byte];
    state = state_dfa[state * 16 + class];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    cursor.* += 1;
    if (state == UTF_ACCEPT) return codepoint;

    byte = bytes[cursor.*];
    codepoint = (byte & 0x3f) | (codepoint << 6);
    cursor.* += 1;
    return codepoint;
}

pub const UTF_ACCEPT = 0;
pub const UTF_REJECT = 1;

/// Convert a boolean to `0` or `1`.
pub inline fn boolInt(b: bool) u8 {
    return @intFromBool(b);
}

/// Return true when a byte is a UTF-8 continuation byte.
pub inline fn isFollow(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

/// Advance an index to the next UTF-8 code point boundary.
pub inline fn fixSplitForward(text: []const u8, i: usize) usize {
    var idx = i;
    while (idx < text.len and isFollow(text[idx])) : (idx += 1) {}
    return idx;
}

/// Retreat an index to the previous UTF-8 code point boundary.
pub inline fn fixSplitBackward(text: []const u8, i: usize) usize {
    var idx = i;
    if (idx < text.len) while (idx != 0 and isFollow(text[idx])) : (idx -= 1) {};
    return idx;
}

/// Cast an integer value using Zig's checked integer conversion.
pub inline fn cast(as: type, val: anytype) as {
    return @as(as, @intCast(val));
}

/// Convert `usize` to `isize`.
pub inline fn u2i(val: usize) isize {
    return @intCast(val);
}

/// Convert `isize` to `usize`.
pub inline fn i2u(val: isize) usize {
    return @intCast(val);
}

/// Debug-only assertion helper.
pub inline fn dbgassert(ok: bool) void {
    if (is_debug) assert(ok);
}

// The Höhrmann-Thompson-Pike mashup we need and deserve

// zig fmt: off
const byte_class: [256]u8 = .{
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ,0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,0,0, // 00..1f
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ,0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,0,0, // 20..3f
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ,0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,0,0, // 40..5f
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 ,0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,0,0, // 60..7f
    1,1,1,1,2,2,2,2,3,3,3,3,3,3,3,3 ,4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,4,4, // 80..9f
    5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5 ,5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,5,5, // a0..bf
    7,7,6,6,6,6,6,6,6,6,6,6,6,6,6,6 ,6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,6,6, // c0..df
    9,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,11,10,10,10,10,10,10,10,13,12,12,12,15,14,7,7, // e0..ff
};

const class_mask: [16]u8 = .{
    0xff,
    0,
    0,
    0,
    0,
    0,
    0b0001_1111,
    0,
    0b0000_1111,
    0b0000_1111,
    0b0000_0111,
    0b0000_0111,
    0b0000_0011,
    0b0000_0011,
    0b0000_0001,
    0b0000_0001,
};

const state_dfa: [176]u8 = .{
    0,1,1,1,1,1,2,1,3,7,4,8,5,9,6,10,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    1,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,
    1,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,
    1,3,3,3,3,3,1,1,1,1,1,1,1,1,1,1,
    1,4,4,4,4,4,1,1,1,1,1,1,1,1,1,1,
    1,5,5,5,5,5,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,1,2,1,1,1,1,1,1,1,1,1,1,
    1,1,1,1,3,3,1,1,1,1,1,1,1,1,1,1,
    1,1,1,4,4,4,1,1,1,1,1,1,1,1,1,1,
    1,1,5,5,5,5,1,1,1,1,1,1,1,1,1,1,
};
// zig fmt: on

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const testing = std.testing;

const builtin = @import("builtin");
const is_debug = builtin.mode == .Debug;
