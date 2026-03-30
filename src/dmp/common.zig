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
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    for (diffs.items) |edit| {
        if (edit.operation != .insert) try chars.appendSlice(allocator, edit.text);
    }
    return chars.toOwnedSlice(allocator);
}

/// Compute and return the destination text (all equalities and insertions).
pub fn diffAfterText(allocator: Allocator, diffs: anytype) Allocator.Error![]const u8 {
    var chars = ArrayListUnmanaged(u8){};
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

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;

const builtin = @import("builtin");
const is_debug = builtin.mode == .Debug;
