// MIT License
//
// Copyright (c) 2023 diffz authors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const DiffMatchPatch = @This();

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.array_list.Managed;
const DiffMod = @import("dmp/Diff.zig");
const PatchMod = @import("dmp/Patch.zig");

pub const PatchList = PatchMod.PatchList;
pub const PatchConfig = PatchMod.PatchConfig;
pub const Patch = PatchMod;
pub const deinitPatchList = PatchMod.deinitPatchList;
pub const Hunk = PatchMod.Hunk;
pub const writePatch = PatchMod.writePatch;

const clonePatchList = PatchMod.clonePatchList;
const matchMain = PatchMod.matchMain;
const matchBitap = PatchMod.matchBitap;
const matchBitapScore = PatchMod.matchBitapScore;
const patchAddContext = PatchMod.patchAddContext;
const diffAndMakePatchWithConfig = PatchMod.diffAndMakePatchWithConfig;
const makePatchWithConfig = PatchMod.makePatchWithConfig;
const makePatchFromDiffsWithConfig = PatchMod.makePatchFromDiffsWithConfig;
const patchApplyWithConfig = PatchMod.patchApplyWithConfig;
const patchSplitMax = PatchMod.patchSplitMax;
const patchAddPadding = PatchMod.patchAddPadding;
const patchListToText = PatchMod.patchListToText;
const patchListFromText = PatchMod.patchListFromText;
const patchFromHeader = PatchMod.patchFromHeader;
const decodeUri = PatchMod.decodeUri;
const writeUriEncoded = PatchMod.writeUriEncoded;
const sliceToDiffList = PatchMod.sliceToDiffList;

pub const Edit = DiffMod.Edit;
pub const DiffList = DiffMod.DiffList;
pub const DiffConfig = DiffMod.DiffConfig;
pub const Diff = DiffMod;
pub const deinitDiffList = DiffMod.deinitDiffList;
pub const diffCleanupSemantic = DiffMod.diffCleanupSemantic;
pub const diffCleanupSemanticLossless = DiffMod.diffCleanupSemanticLossless;
pub const diffIndex = DiffMod.diffIndex;
pub const DiffDecorations = DiffMod.DiffDecorations;
pub const xterm_classic = DiffMod.xterm_classic;
pub const diffPrettyFormat = DiffMod.diffPrettyFormat;
pub const diffPrettyFormatXTerm = DiffMod.diffPrettyFormatXTerm;
pub const writeDiffPrettyFormat = DiffMod.writeDiffPrettyFormat;
pub const diffBeforeText = DiffMod.diffBeforeText;
pub const diffAfterText = DiffMod.diffAfterText;
pub const diffLevenshtein = DiffMod.diffLevenshtein;

const diffWithConfig = DiffMod.diffWithConfig;
const diffInternal = DiffMod.diffInternal;
const diffCommonPrefix = DiffMod.diffCommonPrefix;
const diffCommonSuffix = DiffMod.diffCommonSuffix;
const diffCompute = DiffMod.diffCompute;
const diffHalfMatchConfig = DiffMod.diffHalfMatchConfig;
const diffHalfMatchInternal = DiffMod.diffHalfMatchInternal;
const diffBisectConfig = DiffMod.diffBisectConfig;
const diffBisectSplit = DiffMod.diffBisectSplit;
const diffLinesToChars = DiffMod.diffLinesToChars;
const diffLinesToCharsMunge = DiffMod.diffLinesToCharsMunge;
const diffCharsToLines = DiffMod.diffCharsToLines;
const diffLineMode = DiffMod.diffLineMode;
const diffCleanupMerge = DiffMod.diffCleanupMerge;
const diffCommonOverlap = DiffMod.diffCommonOverlap;
const diffCleanupSemanticScore = DiffMod.diffCleanupSemanticScore;
const diffCleanupEfficiencyConfig = DiffMod.diffCleanupEfficiencyConfig;
const diffPrettyHtml = DiffMod.diffPrettyHtml;
const diffCleanupSemanticLosslessConfig = DiffMod.diffCleanupSemanticLossless;
const HalfMatchResult = DiffMod.HalfMatchResult;
const CHAR_OFFSET = DiffMod.CHAR_OFFSET;
const diffListFromConfig = DiffMod.diffListFromConfig;

pub const DiffError = error{
    OutOfMemory,
    BadPatchString,
};

const OutOfMemory = error.OutOfMemory;

//| Fields

//| Allocation Management Helpers

fn testPatchToText(allocator: Allocator) !void {
    //
    var p: Hunk = Hunk{
        .start1 = 20,
        .start2 = 21,
        .length1 = 18,
        .length2 = 17,
        .diffs = try sliceToDiffList(allocator, &.{
            .{ .operation = .equal, .text = "jump" },
            .{ .operation = .delete, .text = "s" },
            .{ .operation = .insert, .text = "ed" },
            .{ .operation = .equal, .text = " over " },
            .{ .operation = .delete, .text = "the" },
            .{ .operation = .insert, .text = "a" },
            .{ .operation = .equal, .text = "\nlaz" },
        }),
    };
    defer p.deinit(allocator);
    const strp = "@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n %0Alaz\n";
    const patch_str = try p.asText(allocator);
    defer allocator.free(patch_str);
    try testing.expectEqualStrings(strp, patch_str);
}

test "patch to text" {
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchToText,
        .{},
    );
}

fn testPatchRoundTrip(allocator: Allocator, patch_in: []const u8) !void {
    var patch = Patch.init();
    defer patch.deinit(allocator);
    _ = try patch.fromText(allocator, patch_in);
    const patch_out = try patch.toText(allocator);
    defer allocator.free(patch_out);
    try testing.expectEqualStrings(patch_in, patch_out);
}

test "workshop" {
    try testPatchRoundTrip(
        testing.allocator,
        "@@ -0,0 +1,3 @@\n+abc\n@@ -0,0 +1,3 @@\n+abc\n",
    );
}

test "patch from text" {
    const allocator = testing.allocator;
    var p0 = Patch.init();
    defer p0.deinit(allocator);
    _ = try p0.fromText(allocator, "");
    try testing.expectEqual(0, p0.hunks.items.len);
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -21,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n %0Alaz\n"},
    );
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchRoundTrip,
        .{"@@ -1 +1 @@\n-a\n+b\n"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -1,3 +0,0 @@\n-abc\n"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -0,0 +1,3 @@\n+abc\n"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchRoundTrip,
        .{"@@ -0,0 +1,3 @@\n+abc\n@@ -0,0 +1,3 @@\n+abc\n"},
    );
}

fn testBadPatchString(allocator: Allocator, patch: []const u8) !void {
    var parsed = Patch.init();
    defer parsed.deinit(allocator);
    _ = parsed.fromText(allocator, patch) catch |e| {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try testing.expectEqual(error.BadPatchString, e);
            },
        }
    };
}

test "error.BadPatchString" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"Bad\nPatch\nString\n"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ foo"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ +no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ !1,no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,3 +???"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,no"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,3 +4,5 ##"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,10??"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -1,10 ?"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@@ -1,3 +4,5 @!"},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@@ -1,3 +4,5 +add\n@!"},
    );
    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        testBadPatchString,
        .{"@@ -0,0 +1,3 @@\n+abc\n@@ -0,0 +1,3 @@\n+abc\n!!!"},
    );
}

fn testPatchAddContext(
    allocator: Allocator,
    config: PatchConfig,
    patch_text: []const u8,
    text: []const u8,
    expect: []const u8,
) !void {
    _, var patch = try patchFromHeader(allocator, patch_text);
    defer patch.deinit(allocator);
    const patch_og = try patch.asText(allocator);
    defer allocator.free(patch_og);
    try testing.expectEqualStrings(patch_text, patch_og);
    try patchAddContext(config, allocator, &patch, text);
    const patch_out = try patch.asText(allocator);
    defer allocator.free(patch_out);
    try testing.expectEqualStrings(expect, patch_out);
}

test "testPatchAddContext" {
    const allocator = testing.allocator;
    const config: PatchConfig = .{ .margin = 4 };
    // Simple case.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            config,
            "@@ -21,4 +21,10 @@\n-jump\n+somersault\n",
            "The quick brown fox jumps over the lazy dog.",
            "@@ -17,12 +17,18 @@\n fox \n-jump\n+somersault\n s ov\n",
        },
    );
    // Not enough trailing context.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            config,
            "@@ -21,4 +21,10 @@\n-jump\n+somersault\n",
            "The quick brown fox jumps.",
            "@@ -17,10 +17,16 @@\n fox \n-jump\n+somersault\n s.\n",
        },
    );
    // Not enough leading context.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            config,
            "@@ -3 +3,2 @@\n-e\n+at\n",
            "The quick brown fox jumps.",
            "@@ -1,7 +1,8 @@\n Th\n-e\n+at\n  qui\n",
        },
    );
    // Ambiguity.
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            config,
            "@@ -3 +3,2 @@\n-e\n+at\n",
            "The quick brown fox jumps.  The quick brown fox crashes.",
            "@@ -1,27 +1,28 @@\n Th\n-e\n+at\n  quick brown fox jumps. \n",
        },
    );
    // Unicode
    try std.testing.checkAllAllocationFailures(
        allocator,
        testPatchAddContext,
        .{
            config,
            "@@ -9,6 +10,3 @@\n-remove\n+add\n",
            "⊗⊘⊙remove⊙⊘⊗",
            \\@@ -3,18 +4,15 @@
            \\ %E2%8A%98%E2%8A%99
            \\-remove
            \\+add
            \\ %E2%8A%99%E2%8A%98
            \\
        },
    );
}

fn testMakePatch(allocator: Allocator) !void {
    var patch = Patch.initOptions(.{ .match_max_bits = 32 });
    defer patch.deinit(allocator);
    _ = try patch.diffAndMake(allocator, "", "");
    const null_patch_text = try patch.toText(allocator);
    defer allocator.free(null_patch_text);
    try testing.expectEqualStrings("", null_patch_text);
    const text1 = "The quick brown fox jumps over the lazy dog.";
    const text2 = "That quick brown fox jumped over a lazy dog.";
    { // The second patch must be "-21,17 +21,18", not "-22,17 +21,18" due to rolling context.
        const expectedPatch = "@@ -1,8 +1,7 @@\n Th\n-at\n+e\n  qui\n@@ -21,17 +21,18 @@\n jump\n-ed\n+s\n  over \n-a\n+the\n  laz\n";
        _ = try patch.diffAndMake(allocator, text2, text1);
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expectedPatch, patch_text);
    }
    {
        const expectedPatch = "@@ -1,11 +1,12 @@\n Th\n-e\n+at\n  quick b\n@@ -22,18 +22,17 @@\n jump\n-s\n+ed\n  over \n-the\n+a\n  laz\n";
        _ = try patch.diffAndMake(allocator, text1, text2);
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expectedPatch, patch_text);
        const config: DiffConfig = .{ .check_lines = false };
        var diffs = try diffListFromConfig(allocator, config, text1, text2);
        defer deinitDiffList(allocator, &diffs);
        _ = try patch.make(allocator, text1, diffs);
        const patch_text_2 = try patch.toText(allocator);
        defer allocator.free(patch_text_2);
        try testing.expectEqualStrings(expectedPatch, patch_text_2);
    }
    const expectedPatch2 = "@@ -1,21 +1,21 @@\n-%601234567890-=%5B%5D%5C;',./\n+~!@#$%25%5E&*()_+%7B%7D%7C:%22%3C%3E?\n";
    {
        _ = try patch.diffAndMake(
            allocator,
            "`1234567890-=[]\\;',./",
            "~!@#$%^&*()_+{}|:\"<>?",
        );
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expectedPatch2, patch_text);
    }
    {
        var diffs = try sliceToDiffList(allocator, &.{
            .{ .operation = .delete, .text = "`1234567890-=[]\\;',./" },
            .{ .operation = .insert, .text = "~!@#$%^&*()_+{}|:\"<>?" },
        });
        defer deinitDiffList(allocator, &diffs);
        _ = try patch.makeFromDiffs(allocator, diffs);
        for (patch.hunks.items[0].diffs.items, 0..) |a_diff, idx| {
            try testing.expect(a_diff.eql(diffs.items[idx]));
        }
    }
    {
        const text1a = "abcdef" ** 100;
        const text2a = text1a ++ "123";
        const expected_patch = "@@ -573,28 +573,31 @@\n cdefabcdefabcdefabcdefabcdef\n+123\n";
        _ = try patch.diffAndMake(allocator, text1a, text2a);
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expected_patch, patch_text);
    }
}

test "makePatch" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMakePatch,
        .{},
    );
}

fn testPatchSplitMax(allocator: Allocator) !void {
    // TODO get some tests which cover the max split we actually use: bitsize(usize)
    var patch = Patch.initOptions(.{ .match_max_bits = 32 });
    defer patch.deinit(allocator);
    {
        _ = try patch.diffAndMake(
            allocator,
            "abcdefghijklmnopqrstuvwxyz01234567890",
            "XabXcdXefXghXijXklXmnXopXqrXstXuvXwxXyzX01X23X45X67X89X0",
        );
        const expected_patch = "@@ -1,32 +1,46 @@\n+X\n ab\n+X\n cd\n+X\n ef\n+X\n gh\n+X\n ij\n+X\n kl\n+X\n mn\n+X\n op\n+X\n qr\n+X\n st\n+X\n uv\n+X\n wx\n+X\n yz\n+X\n 012345\n@@ -25,13 +39,18 @@\n zX01\n+X\n 23\n+X\n 45\n+X\n 67\n+X\n 89\n+X\n 0\n";
        try patchSplitMax(patch.config, allocator, &patch.hunks);
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(expected_patch, patch_text);
    }
    {
        _ = try patch.diffAndMake(
            allocator,
            "abcdef1234567890123456789012345678901234567890123456789012345678901234567890uvwxyz",
            "abcdefuvwxyz",
        );
        const text_before = try patch.toText(allocator);
        defer allocator.free(text_before);
        try patchSplitMax(patch.config, allocator, &patch.hunks);
        const text_after = try patch.toText(allocator);
        defer allocator.free(text_after);
        try testing.expectEqualStrings(text_before, text_after);
    }
    {
        _ = try patch.diffAndMake(
            allocator,
            "1234567890123456789012345678901234567890123456789012345678901234567890",
            "abc",
        );
        const pre_patch_text = try patch.toText(allocator);
        defer allocator.free(pre_patch_text);
        try patchSplitMax(patch.config, allocator, &patch.hunks);
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(
            "@@ -1,32 +1,4 @@\n-1234567890123456789012345678\n 9012\n@@ -29,32 +1,4 @@\n-9012345678901234567890123456\n 7890\n@@ -57,14 +1,3 @@\n-78901234567890\n+abc\n",
            patch_text,
        );
    }
    {
        _ = try patch.diffAndMake(
            allocator,
            "abcdefghij , h : 0 , t : 1 abcdefghij , h : 0 , t : 1 abcdefghij , h : 0 , t : 1",
            "abcdefghij , h : 1 , t : 1 abcdefghij , h : 1 , t : 1 abcdefghij , h : 0 , t : 1",
        );
        try patchSplitMax(patch.config, allocator, &patch.hunks);
        const patch_text = try patch.toText(allocator);
        defer allocator.free(patch_text);
        try testing.expectEqualStrings(
            "@@ -2,32 +2,32 @@\n bcdefghij , h : \n-0\n+1\n  , t : 1 abcdef\n@@ -29,32 +29,32 @@\n bcdefghij , h : \n-0\n+1\n  , t : 1 abcdef\n",
            patch_text,
        );
    }
}

test patchSplitMax {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchSplitMax,
        .{},
    );
    try testPatchSplitMax(testing.allocator);
}

fn testPatchAddPadding(
    allocator: Allocator,
    before: []const u8,
    after: []const u8,
    expect_before: []const u8,
    expect_after: []const u8,
) !void {
    var patch = Patch.init();
    defer patch.deinit(allocator);
    _ = try patch.diffAndMake(allocator, before, after);
    const patch_text_before = try patch.toText(allocator);
    defer allocator.free(patch_text_before);
    try testing.expectEqualStrings(expect_before, patch_text_before);
    const codes = try patchAddPadding(patch.config, allocator, &patch.hunks);
    allocator.free(codes);
    const patch_text_after = try patch.toText(allocator);
    defer allocator.free(patch_text_after);
    try testing.expectEqualStrings(expect_after, patch_text_after);
}
test patchAddPadding {
    // Both edges full.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchAddPadding,
        .{
            "",
            "test",
            "@@ -0,0 +1,4 @@\n+test\n",
            "@@ -1,8 +1,12 @@\n %01%02%03%04\n+test\n %01%02%03%04\n",
        },
    );
    // Both edges partial.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchAddPadding,
        .{
            "XY",
            "XtestY",
            "@@ -1,2 +1,6 @@\n X\n+test\n Y\n",
            "@@ -2,8 +2,12 @@\n %02%03%04X\n+test\n Y%01%02%03\n",
        },
    );
    // Both edges none.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchAddPadding,
        .{
            "XXXXYYYY",
            "XXXXtestYYYY",
            "@@ -1,8 +1,12 @@\n XXXX\n+test\n YYYY\n",
            "@@ -5,8 +5,12 @@\n XXXX\n+test\n YYYY\n",
        },
    );
}

fn testPatchApply(
    allocator: Allocator,
    config: PatchConfig,
    before: []const u8,
    after: []const u8,
    apply_to: []const u8,
    expect: []const u8,
    all_applied: bool,
) !void {
    var patch = Patch.initOptions(config);
    defer patch.deinit(allocator);
    _ = try patch.diffAndMake(allocator, before, after);
    const result, const success = try patch.apply(allocator, apply_to);
    defer allocator.free(result);
    try testing.expectEqual(all_applied, success);
    try testing.expectEqualStrings(expect, result);
}

test "testPatchApply" {
    // These tests differ from the source, because we just return one
    // bool for if all patches were successfully applied or not.
    var config: PatchConfig = .{
        .match_distance = 1000,
        .match_threshold = 0.5,
        .delete_threshold = 0.5,
        .match_max_bits = 32,
    }; // Necessary to get the correct legacy behavior
    // Null case.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "",
            "",
            "Hello World",
            "Hello World",
            true,
        },
    );
    // Exact match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            true,
        },
    );
    // Partial match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            "The quick red rabbit jumps over the tired tiger.",
            "That quick red rabbit jumped over a tired tiger.",
            true,
        },
    );
    // Failed match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "The quick brown fox jumps over the lazy dog.",
            "That quick brown fox jumped over a lazy dog.",
            "I am the very model of a modern major general.",
            "I am the very model of a modern major general.",
            false,
        },
    );
    // Big delete, small change.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "x1234567890123456789012345678901234567890123456789012345678901234567890y",
            "xabcy",
            "x123456789012345678901234567890-----++++++++++-----123456789012345678901234567890y",
            "xabcy",
            true,
        },
    );
    // Big delete, big change 1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "x1234567890123456789012345678901234567890123456789012345678901234567890y",
            "xabcy",
            "x12345678901234567890---------------++++++++++---------------12345678901234567890y",
            "xabc12345678901234567890---------------++++++++++---------------12345678901234567890y",
            false,
        },
    );
    config.delete_threshold = 0.6;
    // Big delete, big change 2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "x1234567890123456789012345678901234567890123456789012345678901234567890y",
            "xabcy",
            "x12345678901234567890---------------++++++++++---------------12345678901234567890y",
            "xabcy",
            true,
        },
    );
    config.delete_threshold = 0.6;
    config.match_threshold = 0.0;
    config.match_distance = 0;
    // Compensate for failed patch.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "abcdefghijklmnopqrstuvwxyz--------------------1234567890",
            "abcXXXXXXXXXXdefghijklmnopqrstuvwxyz--------------------1234567YYYYYYYYYY890",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567890",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567YYYYYYYYYY890",
            false,
        },
    );
    config.match_threshold = 0.5;
    config.match_distance = 1000;
    // Edge exact match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "",
            "test",
            "",
            "test",
            true,
        },
    );
    // Near edge exact match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "XY",
            "XtestY",
            "XY",
            "XtestY",
            true,
        },
    );
    // Edge partial match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testPatchApply,
        .{
            config,
            "y",
            "y123",
            "x",
            "x123",
            true,
        },
    );
}

test "patching does not affect patches" {
    const allocator = std.testing.allocator;
    const config: PatchConfig = .{
        .match_distance = 1000,
        .match_threshold = 0.5,
        .delete_threshold = 0.5,
        .match_max_bits = 32,
    }; // Need this so test #2 splits
    var patches1 = Patch.initOptions(config);
    defer patches1.deinit(allocator);
    _ = try patches1.diffAndMake(allocator, "", "test");
    const patch1_str = try patches1.toText(allocator);
    defer allocator.free(patch1_str);
    const result1, _ = try patches1.apply(allocator, "");
    allocator.free(result1);
    const patch1_str_after = try patches1.toText(allocator);
    defer allocator.free(patch1_str_after);
    try testing.expectEqualStrings(patch1_str, patch1_str_after);
    var patches2 = Patch.initOptions(config);
    defer patches2.deinit(allocator);
    _ = try patches2.diffAndMake(
        allocator,
        "The quick brown fox jumps over the lazy dog.",
        "Woof",
    );
    const patch2_str = try patches2.toText(allocator);
    defer allocator.free(patch2_str);
    const result2, _ = try patches2.apply(allocator, "The quick brown fox jumps over the lazy dog.");
    allocator.free(result2);
    const patch2_str_after = try patches2.toText(allocator);
    defer allocator.free(patch2_str_after);
    try testing.expectEqualStrings(patch2_str, patch2_str_after);
}
