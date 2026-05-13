//! DiffFn builds a specialized diff engine while preserving the shared
//! `Edit` and `DiffList` representation from the generic diff module.
//!
//! The returned `Diff` stores its config, specialization context, and edit
//! list, and keeps the diff-proper behavior as receiver methods rather than
//! module-level entrypoints.
//!
//! Specialization points currently include:
//! - `context`: user-provided state stored on the `Diff`
//! - `LineIterator`: the segment iterator used by the line-mode speedup
//! - `semanticScore`: boundary scoring used by semantic lossless cleanup

const CHAR_OFFSET = 32;
const UNICODE_MAX = 0x10ffdf;
const UNICODE_TWO_THIRDS = 742724;
const UNICODE_ONE_THIRD = 371355;

comptime {
    assert(UNICODE_TWO_THIRDS + UNICODE_ONE_THIRD == UNICODE_MAX);
    assert(UNICODE_TWO_THIRDS + UNICODE_ONE_THIRD + CHAR_OFFSET == 0x10ffff);
}

/// Default iterator over lines, including the trailing newline when present.
pub const DefaultLineIterator = struct {
    cursor: usize = 0,
    text: []const u8,

    /// Return the next line, including its newline, if one is present.
    pub fn next(iter: *DefaultLineIterator) ?[]const u8 {
        if (iter.cursor == iter.text.len) return null;
        const maybe_newline = std.mem.indexOfScalarPos(
            u8,
            iter.text,
            iter.cursor,
            '\n',
        );
        if (maybe_newline) |nl| {
            const line = iter.text[iter.cursor .. nl + 1];
            iter.cursor = nl + 1;
            return line;
        } else {
            const line = iter.text[iter.cursor..];
            iter.cursor = iter.text.len;
            return line;
        }
    }

    /// Terminate the iterator early by returning all remaining text.
    /// `back_out` describes how far before the cursor to resume.
    pub fn short_circuit(iter: *DefaultLineIterator, back_out: usize) []const u8 {
        const from = iter.cursor - back_out;
        iter.cursor = iter.text.len;
        return iter.text[from..];
    }
};

const HalfMatchResult = struct {
    prefix_before: []const u8,
    suffix_before: []const u8,
    prefix_after: []const u8,
    suffix_after: []const u8,
    common_middle: []const u8,
};

const BorrowedLosslessWindow = struct {
    equality_1: []const u8,
    edit: []const u8,
    equality_2: []const u8,
};

/// Result of line- or segment-based compression prior to rediffing.
const LinesToCharsResult = struct {
    chars_1: []const u8,
    chars_2: []const u8,
    line_array: ArrayListUnmanaged([]const u8),

    pub fn deinit(result: *LinesToCharsResult, allocator: Allocator) void {
        allocator.free(result.chars_1);
        allocator.free(result.chars_2);
        result.line_array.deinit(allocator);
    }
};

/// Build a specialized `Diff` type from a loose comptime config.
///
/// Supported fields are:
/// - `context`: stored context type, default `void`
/// - `LineIterator`: iterator type for segmentation, default line iterator
/// - `semanticScore`: boundary-scoring function for semantic cleanup
pub fn DiffFn(config: anytype) type {
    const Config = @TypeOf(config);
    const Context = if (@hasField(Config, "context")) config.context else void;
    const LineIterator = if (@hasField(Config, "LineIterator"))
        config.LineIterator
    else
        DefaultLineIterator;
    const semanticScore = if (@hasField(Config, "semanticScore"))
        config.semanticScore
    else
        defaultSemanticScore;

    return struct {
        /// The diff configuration, see `DiffConfig`.
        config: DiffConfig,
        /// User-provided specialization context, stored on every `Diff`.
        context: Context,
        /// The individual edits making up this difference.
        edits: DiffList,

        const Diff = @This();

        pub const ContextType = Context;
        pub const IteratorType = LineIterator;

        pub const DiffError = OOM || error{TooManySegments};

        pub const default: Diff = .{
            .config = .default,
            .context = defaultContext(Context),
            .edits = .empty,
        };

        /// Initialize an empty `Diff` with the provided `DiffConfig`.
        pub fn init(cfg: DiffConfig) Diff {
            return .{
                .config = cfg,
                .context = defaultContext(Context),
                .edits = .empty,
            };
        }

        /// Initialize an empty `Diff` with explicit context.
        pub fn initContext(cfg: DiffConfig, context: Context) Diff {
            return .{
                .config = cfg,
                .context = context,
                .edits = .empty,
            };
        }

        /// Own all edits in the Diff.  After this operation it is safe
        /// to dispose of the original strings.
        pub fn own(difference: *Diff, allocator: Allocator) OOM!*Diff {
            for (difference.edits.items) |*e| {
                try e.own(allocator);
            }
            return difference;
        }

        /// Clone this `Diff`, including its owned edits.
        pub fn clone(difference: *const Diff, allocator: Allocator) OOM!Diff {
            return .{
                .config = difference.config,
                .context = difference.context,
                .edits = try cloneDiffList(allocator, &difference.edits),
            };
        }

        /// Make a copy of the Diff, preserving edit ownership status.
        pub fn copy(difference: *const Diff, allocator: Allocator) OOM!Diff {
            return .{
                .config = difference.config,
                .context = difference.context,
                .edits = try copyDiffList(allocator, &difference.edits),
            };
        }

        /// Release the storage owned by this `Diff`.
        pub fn deinit(difference: *Diff, allocator: Allocator) void {
            deinitDiffList(allocator, &difference.edits);
            difference.edits = .empty;
        }

        /// Find the differences between two texts.
        /// @param before Old string to be diffed.
        /// @param after New string to be diffed.
        /// @return difference.
        pub fn diff(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
        ) DiffError!*Diff {
            if (difference.edits.items.len != 0) {
                deinitDiffList(allocator, &difference.edits);
                difference.edits = .empty;
            }
            difference.edits = try difference.diffImpl(allocator, before, after);
            return difference;
        }

        /// Run only the iterator-backed speedup path and return the result.
        pub fn diffLines(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
        ) DiffError!*Diff {
            if (difference.edits.items.len != 0) {
                deinitDiffList(allocator, &difference.edits);
                difference.edits = .empty;
            }
            difference.edits = try difference.diffLine(allocator, before, after, std.math.maxInt(u64));
            return difference;
        }

        /// Reduce the number of edits by eliminating semantically trivial
        /// equalities.
        /// @return difference.
        pub fn cleanupSemantic(difference: *Diff, allocator: Allocator) OOM!*Diff {
            try difference.cleanupSemanticImpl(allocator, &difference.edits);
            return difference;
        }

        /// Look for single edits surrounded on both sides by equalities
        /// which can be shifted sideways to align the edit to a word boundary.
        /// e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
        /// @return difference.
        pub fn cleanupSemanticLossless(difference: *Diff, allocator: Allocator) OOM!*Diff {
            try difference.cleanupSemanticLosslessImpl(allocator, &difference.edits);
            return difference;
        }

        /// Reduce the number of edits by eliminating operationally trivial
        /// equalities.
        /// @return difference.
        pub fn cleanupEfficiency(difference: *Diff, allocator: Allocator) OOM!*Diff {
            try difference.cleanupEfficiencyImpl(allocator, &difference.edits);
            return difference;
        }

        /// Compute and return the source text (all equalities and deletions).
        pub fn beforeText(difference: Diff, allocator: Allocator) OOM![]const u8 {
            return diffBeforeText(allocator, difference.edits);
        }

        /// Compute and return the destination text (all equalities and insertions).
        pub fn afterText(difference: Diff, allocator: Allocator) OOM![]const u8 {
            return diffAfterText(allocator, difference.edits);
        }

        /// loc is a location in text1; compute and return the equivalent
        /// location in text2.
        pub fn index(difference: Diff, loc: usize) usize {
            return diffIndex(difference.edits, loc);
        }

        /// Answers the number of bytes total be added or removed by
        /// applying this difference.
        pub fn changeInBytes(difference: *const Diff) isize {
            var count: isize = 0;
            for (difference.edits.items) |edit| {
                switch (edit.operation) {
                    .insert => count += u2i(edit.text.len),
                    .delete => count -= u2i(edit.text.len),
                    .equal => {},
                }
            }
            return count;
        }

        /// Resolve the stored default context for this specialization.
        fn makeIterator(text: []const u8) LineIterator {
            if (@hasDecl(LineIterator, "init")) {
                return LineIterator.init(text);
            }
            return .{ .text = text };
        }

        /// Apply the configured semantic scoring function.
        fn cleanupSemanticScore(_: *const Diff, one: []const u8, two: []const u8) usize {
            return semanticScore(one, two);
        }

        /// Compute a `DiffList` using this `Diff`'s configuration.
        fn diffImpl(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
        ) DiffError!DiffList {
            const deadline = std.math.maxInt(u64);
            // Timeout clocking needs an explicit Zig 0.16 Io design.
            // const deadline = if (difference.config.timeout == 0)
            //     std.math.maxInt(u64)
            // else
            //     @as(u64, @intCast(std.time.milliTimestamp())) + difference.config.timeout;
            return difference.diffInternal(allocator, before, after, deadline);
        }

        /// Internal diff entrypoint which carries the computed deadline through
        /// the recursive diff pipeline.
        fn diffInternal(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
            deadline: u64,
        ) DiffError!DiffList {
            if (std.mem.eql(u8, before, after)) {
                var diffs: DiffList = .empty;
                errdefer deinitDiffList(allocator, &diffs);
                if (before.len != 0) {
                    try diffs.ensureUnusedCapacity(allocator, 1);
                    diffs.appendAssumeCapacity(Edit.asBorrow(.equal, before));
                }
                return diffs;
            }

            var common_length = diffCommonPrefix(before, after);
            const common_prefix = before[0..common_length];
            var trimmed_before = before[common_length..];
            var trimmed_after = after[common_length..];

            common_length = diffCommonSuffix(trimmed_before, trimmed_after);
            const common_suffix = trimmed_before[trimmed_before.len - common_length ..];
            trimmed_before = trimmed_before[0 .. trimmed_before.len - common_length];
            trimmed_after = trimmed_after[0 .. trimmed_after.len - common_length];

            var diffs = try difference.diffCompute(allocator, trimmed_before, trimmed_after, deadline);
            errdefer deinitDiffList(allocator, &diffs);

            if (common_prefix.len != 0) {
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(0, Edit.asBorrow(.equal, common_prefix));
            }
            if (common_suffix.len != 0) {
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.appendAssumeCapacity(Edit.asBorrow(.equal, common_suffix));
            }
            try difference.cleanupMergeImpl(allocator, &diffs);
            return diffs;
        }

        /// Find the differences between two texts, assuming they do not share
        /// a common prefix or suffix.
        fn diffCompute(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
            deadline: u64,
        ) DiffError!DiffList {
            if (before.len == 0) {
                var diffs: DiffList = .empty;
                errdefer deinitDiffList(allocator, &diffs);
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.appendAssumeCapacity(Edit.asBorrow(.insert, after));
                return diffs;
            }

            if (after.len == 0) {
                var diffs: DiffList = .empty;
                errdefer deinitDiffList(allocator, &diffs);
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.appendAssumeCapacity(Edit.asBorrow(.delete, before));
                return diffs;
            }

            const long_text = if (before.len > after.len) before else after;
            const short_text = if (before.len > after.len) after else before;

            if (std.mem.indexOf(u8, long_text, short_text)) |match_index| {
                var diffs: DiffList = .empty;
                const op: Edit.Operation = if (before.len > after.len) .delete else .insert;
                const equal_text = if (before.len > after.len)
                    before[match_index..][0..short_text.len]
                else
                    short_text;
                try diffs.ensureUnusedCapacity(allocator, 3);
                diffs.appendAssumeCapacity(Edit.asBorrow(op, long_text[0..match_index]));
                diffs.appendAssumeCapacity(Edit.asBorrow(.equal, equal_text));
                diffs.appendAssumeCapacity(Edit.asBorrow(op, long_text[match_index + short_text.len ..]));
                return diffs;
            }

            if (short_text.len == 1) {
                var diffs: DiffList = .empty;
                try diffs.ensureUnusedCapacity(allocator, 2);
                diffs.appendAssumeCapacity(Edit.asBorrow(.delete, before));
                diffs.appendAssumeCapacity(Edit.asBorrow(.insert, after));
                return diffs;
            }

            var maybe_half_match = try difference.diffHalfMatch(allocator, before, after);
            if (maybe_half_match) |*half_match| {
                var diffs = try difference.diffInternal(allocator, half_match.prefix_before, half_match.prefix_after, deadline);
                errdefer deinitDiffList(allocator, &diffs);
                var diffs_b = try difference.diffInternal(allocator, half_match.suffix_before, half_match.suffix_after, deadline);
                defer diffs_b.deinit(allocator);
                errdefer {
                    for (diffs_b.items) |*edit| edit.deinit(allocator);
                }

                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.appendAssumeCapacity(Edit.asBorrow(.equal, half_match.common_middle));
                half_match.common_middle = "";
                try diffs.appendSlice(allocator, diffs_b.items);
                return diffs;
            }

            if (difference.config.check_lines and
                before.len > difference.config.check_line_threshold and
                after.len > difference.config.check_line_threshold)
            {
                return difference.diffLineMode(allocator, before, after, deadline);
            }
            return difference.diffBisect(allocator, before, after, deadline);
        }

        /// Check whether the problem can be split in two around a large common
        /// middle block.
        fn diffHalfMatch(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
        ) DiffError!?HalfMatchResult {
            _ = allocator;
            if (difference.config.timeout == 0) return null;
            const long_text = if (before.len > after.len) before else after;
            const short_text = if (before.len > after.len) after else before;
            if (long_text.len < 4 or short_text.len * 2 < long_text.len) return null;

            const half_match_1 = try difference.diffHalfMatchInternal(long_text, short_text, (long_text.len + 3) / 4);
            const half_match_2 = try difference.diffHalfMatchInternal(long_text, short_text, (long_text.len + 1) / 2);

            var half_match: ?HalfMatchResult = null;
            if (half_match_1 == null and half_match_2 == null) {
                return null;
            } else if (half_match_2 == null) {
                half_match = half_match_1.?;
            } else if (half_match_1 == null) {
                half_match = half_match_2.?;
            } else {
                half_match = if (half_match_1.?.common_middle.len > half_match_2.?.common_middle.len)
                    half_match_1
                else
                    half_match_2;
            }

            if (before.len > after.len) {
                const hm = half_match.?;
                return .{
                    .prefix_before = hm.prefix_before,
                    .suffix_before = hm.suffix_before,
                    .prefix_after = hm.prefix_after,
                    .suffix_after = hm.suffix_after,
                    .common_middle = before[hm.prefix_before.len .. before.len - hm.suffix_before.len],
                };
            } else {
                const hm = half_match.?;
                return .{
                    .prefix_before = hm.prefix_after,
                    .suffix_before = hm.suffix_after,
                    .prefix_after = hm.prefix_before,
                    .suffix_after = hm.suffix_before,
                    .common_middle = before[hm.prefix_after.len .. before.len - hm.suffix_after.len],
                };
            }
        }

        /// Does a substring of `short_text` exist within `long_text` such that
        /// the substring is at least half the length of `long_text`?
        fn diffHalfMatchInternal(
            _: *Diff,
            long_text: []const u8,
            short_text: []const u8,
            i: usize,
        ) DiffError!?HalfMatchResult {
            const seed_start = fixSplitForward(long_text, i);
            const seed_end = fixSplitBackward(long_text, @min(long_text.len, seed_start + long_text.len / 4));
            if (seed_end <= seed_start) return null;
            const seed = long_text[seed_start..seed_end];
            var j: isize = -1;

            var best_common: []const u8 = "";
            var best_long_text_a: []const u8 = "";
            var best_long_text_b: []const u8 = "";
            var best_short_text_a: []const u8 = "";
            var best_short_text_b: []const u8 = "";

            while (j < short_text.len and b: {
                j = u2i(std.mem.indexOf(u8, short_text[i2u(j + 1)..], seed) orelse break :b false) + j + 1;
                break :b true;
            }) {
                const prefix_length = diffCommonPrefix(long_text[seed_start..], short_text[@as(usize, @intCast(j))..]);
                const suffix_length = diffCommonSuffix(long_text[0..seed_start], short_text[0..@as(usize, @intCast(j))]);
                if (best_common.len < suffix_length + prefix_length) {
                    best_common = short_text[i2u(j - u2i(suffix_length)) .. i2u(j) + prefix_length];
                    best_long_text_a = long_text[0 .. seed_start - suffix_length];
                    best_long_text_b = long_text[seed_start + prefix_length ..];
                    best_short_text_a = short_text[0..i2u(j - u2i(suffix_length))];
                    best_short_text_b = short_text[i2u(j + u2i(prefix_length))..];
                }
            }
            if (best_common.len * 2 >= long_text.len) {
                return .{
                    .prefix_before = best_long_text_a,
                    .suffix_before = best_long_text_b,
                    .prefix_after = best_short_text_a,
                    .suffix_after = best_short_text_b,
                    .common_middle = best_common,
                };
            }
            return null;
        }

        /// Myers bisect difference.
        fn diffBisect(
            difference: *Diff,
            allocator: Allocator,
            before: []const u8,
            after: []const u8,
            deadline: u64,
        ) DiffError!DiffList {
            const before_length: isize = @intCast(before.len);
            const after_length: isize = @intCast(after.len);
            const max_d: isize = @intCast((before.len + after.len + 1) / 2);
            const v_offset = max_d;
            const v_length = 2 * max_d;

            // TODO: just alloc here yeah?  The ArrayList is pointless..
            var v1 = try ArrayListUnmanaged(isize).initCapacity(allocator, i2u(v_length));
            defer v1.deinit(allocator);
            v1.items.len = @intCast(v_length);
            var v2 = try ArrayListUnmanaged(isize).initCapacity(allocator, i2u(v_length));
            defer v2.deinit(allocator);
            v2.items.len = @intCast(v_length);

            var x: usize = 0;
            // TODO: uhhhh @memset?
            while (x < v_length) : (x += 1) {
                v1.items[x] = -1;
                v2.items[x] = -1;
            }
            v1.items[i2u(v_offset + 1)] = 0;
            v2.items[i2u(v_offset + 1)] = 0;
            const delta = before_length - after_length;
            const front = (@mod(delta, 2) != 0);
            var k1start: isize = 0;
            var k1end: isize = 0;
            var k2start: isize = 0;
            var k2end: isize = 0;

            var d: isize = 0;
            while (d < max_d) : (d += 1) {
                if (deadline == 0) break;
                // Timeout clocking needs an explicit Zig 0.16 Io design.
                // if (@as(u64, @intCast(std.time.milliTimestamp())) > deadline) break;

                var k1 = -d + k1start;
                while (k1 <= d - k1end) : (k1 += 2) {
                    const k1_offset = v_offset + k1;
                    var x1: isize = 0;
                    if (k1 == -d or (k1 != d and v1.items[i2u(k1_offset - 1)] < v1.items[i2u(k1_offset + 1)])) {
                        x1 = v1.items[i2u(k1_offset + 1)];
                    } else {
                        x1 = v1.items[i2u(k1_offset - 1)] + 1;
                    }
                    var y1 = x1 - k1;
                    while (x1 < before_length and y1 < after_length) {
                        if (before[i2u(x1)] == after[i2u(y1)]) {
                            x1 += 1;
                            y1 += 1;
                        } else break;
                    }
                    v1.items[i2u(k1_offset)] = x1;
                    if (x1 > before_length) {
                        k1end += 2;
                    } else if (y1 > after_length) {
                        k1start += 2;
                    } else if (front) {
                        const k2_offset = v_offset + delta - k1;
                        if (k2_offset >= 0 and k2_offset < v_length and v2.items[i2u(k2_offset)] != -1) {
                            const x2 = before_length - v2.items[i2u(k2_offset)];
                            if (x1 >= x2) {
                                return difference.diffBisectSplit(allocator, before, after, x1, y1, deadline);
                            }
                        }
                    }
                }

                var k2: isize = -d + k2start;
                while (k2 <= d - k2end) : (k2 += 2) {
                    const k2_offset = v_offset + k2;
                    var x2: isize = 0;
                    if (k2 == -d or (k2 != d and v2.items[i2u(k2_offset - 1)] < v2.items[i2u(k2_offset + 1)])) {
                        x2 = v2.items[i2u(k2_offset + 1)];
                    } else {
                        x2 = v2.items[i2u(k2_offset - 1)] + 1;
                    }
                    var y2: isize = x2 - k2;
                    while (x2 < before_length and y2 < after_length) {
                        if (before[i2u(before_length - x2 - 1)] == after[i2u(after_length - y2 - 1)]) {
                            x2 += 1;
                            y2 += 1;
                        } else break;
                    }
                    v2.items[i2u(k2_offset)] = x2;
                    if (x2 > before_length) {
                        k2end += 2;
                    } else if (y2 > after_length) {
                        k2start += 2;
                    } else if (!front) {
                        const k1_offset = v_offset + delta - k2;
                        if (k1_offset >= 0 and k1_offset < v_length and v1.items[i2u(k1_offset)] != -1) {
                            const x1 = v1.items[i2u(k1_offset)];
                            const y1 = v_offset + x1 - k1_offset;
                            x2 = before_length - v2.items[i2u(k2_offset)];
                            if (x1 >= x2) {
                                return difference.diffBisectSplit(allocator, before, after, x1, y1, deadline);
                            }
                        }
                    }
                }
            }

            var diffs: DiffList = .empty;
            errdefer deinitDiffList(allocator, &diffs);
            try diffs.ensureUnusedCapacity(allocator, 2);
            diffs.appendAssumeCapacity(Edit.asBorrow(.delete, before));
            diffs.appendAssumeCapacity(Edit.asBorrow(.insert, after));
            return diffs;
        }

        /// Given the location of the middle snake, split the diff in two
        /// parts and recurse.
        fn diffBisectSplit(
            difference: *Diff,
            allocator: Allocator,
            text1: []const u8,
            text2: []const u8,
            x: isize,
            y: isize,
            deadline: u64,
        ) DiffError!DiffList {
            const x1 = fixSplitForward(text1, @intCast(x));
            const y1 = fixSplitBackward(text2, @intCast(y));
            const text1a = text1[0..x1];
            const text2a = text2[0..y1];
            const text1b = text1[x1..];
            const text2b = text2[y1..];

            if (text1a.len == 0 and text2a.len == 0) {
                var diffs: DiffList = .empty;
                errdefer deinitDiffList(allocator, &diffs);
                try diffs.ensureUnusedCapacity(allocator, 2);
                diffs.appendAssumeCapacity(Edit.asBorrow(.delete, text1b));
                diffs.appendAssumeCapacity(Edit.asBorrow(.insert, text2b));
                return diffs;
            } else if (text1b.len == 0 and text2b.len == 0) {
                var diffs: DiffList = .empty;
                errdefer deinitDiffList(allocator, &diffs);
                try diffs.ensureUnusedCapacity(allocator, 2);
                diffs.appendAssumeCapacity(Edit.asBorrow(.delete, text2b));
                diffs.appendAssumeCapacity(Edit.asBorrow(.insert, text2a));
                return diffs;
            }

            var text_mode = difference.copyForTextMode();
            var diffs = try text_mode.diffInternal(allocator, text1a, text2a, deadline);
            errdefer deinitDiffList(allocator, &diffs);
            var diffs_b = try text_mode.diffInternal(allocator, text1b, text2b, deadline);
            defer diffs_b.deinit(allocator);
            errdefer for (diffs_b.items) |*edit| edit.deinit(allocator);
            try diffs.appendSlice(allocator, diffs_b.items);
            return diffs;
        }

        /// Do a quick iterator-level diff on both strings, then rediff the
        /// changed parts for greater accuracy.
        fn diffLineMode(
            difference: *Diff,
            allocator: Allocator,
            text1_in: []const u8,
            text2_in: []const u8,
            deadline: u64,
        ) DiffError!DiffList {
            var diffs = try difference.diffLine(allocator, text1_in, text2_in, deadline);
            errdefer deinitDiffList(allocator, &diffs);
            return difference.diffLineCleanup(&diffs, allocator, text1_in, text2_in, deadline);
        }

        /// Perform only the iterator-based diff speedup, returning what we get.
        fn diffLine(
            difference: *Diff,
            allocator: Allocator,
            text1_in: []const u8,
            text2_in: []const u8,
            deadline: u64,
        ) DiffError!DiffList {
            var text_mode = difference.copyForTextMode();
            var a = try difference.diffLinesToChars(allocator, text1_in, text2_in);
            defer a.deinit(allocator);
            var diffs: DiffList = diff_munge: {
                var char_diffs = try text_mode.diffInternal(allocator, a.chars_1, a.chars_2, deadline);
                defer deinitDiffList(allocator, &char_diffs);
                break :diff_munge try diffCharsToLines(allocator, &char_diffs, a.line_array.items, text1_in, text2_in);
            };
            errdefer deinitDiffList(allocator, &diffs);
            try difference.cleanupSemanticImpl(allocator, &diffs);
            return diffs;
        }

        /// Rediff replacement blocks character-by-character after the
        /// iterator-level speedup.
        fn diffLineCleanup(
            difference: *Diff,
            diffs: *DiffList,
            allocator: Allocator,
            text1_in: []const u8,
            text2_in: []const u8,
            deadline: u64,
        ) DiffError!DiffList {
            var text_mode = difference.copyForTextMode();
            try diffs.append(allocator, Edit.asBorrow(.equal, ""));

            var pointer: usize = 0;
            var count_delete: usize = 0;
            var count_insert: usize = 0;
            var delete_run: []const u8 = "";
            var insert_run: []const u8 = "";
            while (pointer < diffs.items.len) : (pointer += 1) {
                switch (diffs.items[pointer].operation) {
                    .insert => {
                        count_insert += 1;
                        const text = diffs.items[pointer].text;
                        if (count_insert == 1) insert_run = text else {
                            dbgassert(insert_run.ptr + insert_run.len == text.ptr);
                            insert_run = insert_run.ptr[0 .. insert_run.len + text.len];
                        }
                    },
                    .delete => {
                        count_delete += 1;
                        const text = diffs.items[pointer].text;
                        if (count_delete == 1) delete_run = text else {
                            dbgassert(delete_run.ptr + delete_run.len == text.ptr);
                            delete_run = delete_run.ptr[0 .. delete_run.len + text.len];
                        }
                    },
                    .equal => {
                        if (count_delete >= 1 and count_insert >= 1) {
                            const run_start = pointer - count_delete - count_insert;
                            var before_cursor: usize = 0;
                            var after_cursor: usize = 0;
                            for (diffs.items[0..run_start]) |edit| {
                                if (edit.operation != .insert) before_cursor += edit.text.len;
                                if (edit.operation != .delete) after_cursor += edit.text.len;
                            }
                            var sub_diff = try text_mode.diffInternal(allocator, delete_run, insert_run, deadline);
                            {
                                errdefer deinitDiffList(allocator, &sub_diff);
                                try diffs.ensureUnusedCapacity(allocator, sub_diff.items.len);
                            }
                            try difference.diffRebindToSourceTexts(
                                allocator,
                                &sub_diff,
                                text1_in,
                                text2_in,
                                before_cursor,
                                after_cursor,
                            );
                            freeRangeDiffList(allocator, diffs, run_start, count_delete + count_insert);
                            try diffs.replaceRange(allocator, run_start, count_delete + count_insert, &.{});
                            pointer = run_start;
                            defer sub_diff.deinit(allocator);
                            const new_diff = diffs.addManyAtAssumeCapacity(pointer, sub_diff.items.len);
                            @memcpy(new_diff, sub_diff.items);
                            pointer += sub_diff.items.len;
                        }
                        count_insert = 0;
                        count_delete = 0;
                        delete_run = "";
                        insert_run = "";
                    },
                }
            }
            diffs.items.len -= 1;
            return diffs.*;
        }

        /// Rebind borrowed spans in a sub-diff back to the original texts.
        fn diffRebindToSourceTexts(
            _: *Diff,
            allocator: Allocator,
            diffs: *DiffList,
            before_text: []const u8,
            after_text: []const u8,
            before_cursor_start: usize,
            after_cursor_start: usize,
        ) OOM!void {
            var before_cursor = before_cursor_start;
            var after_cursor = after_cursor_start;
            for (diffs.items) |*edit| {
                const replacement = switch (edit.operation) {
                    .equal => replacement: {
                        const span = before_text[before_cursor..][0..edit.text.len];
                        dbgassert(std.mem.startsWith(u8, before_text[before_cursor..], edit.text));
                        dbgassert(std.mem.startsWith(u8, after_text[after_cursor..], edit.text));
                        dbgassert(std.mem.eql(u8, span, edit.text));
                        before_cursor += edit.text.len;
                        after_cursor += edit.text.len;
                        break :replacement Edit.asBorrow(.equal, span);
                    },
                    .delete => replacement: {
                        const span = before_text[before_cursor..][0..edit.text.len];
                        dbgassert(std.mem.startsWith(u8, before_text[before_cursor..], edit.text));
                        dbgassert(std.mem.eql(u8, span, edit.text));
                        before_cursor += edit.text.len;
                        break :replacement Edit.asBorrow(.delete, span);
                    },
                    .insert => replacement: {
                        const span = after_text[after_cursor..][0..edit.text.len];
                        dbgassert(std.mem.startsWith(u8, after_text[after_cursor..], edit.text));
                        dbgassert(std.mem.eql(u8, span, edit.text));
                        after_cursor += edit.text.len;
                        break :replacement Edit.asBorrow(.insert, span);
                    },
                };
                edit.deinit(allocator);
                edit.* = replacement;
            }
        }

        /// Split two texts into a list of unique segments and encode them as
        /// a string of Unicode code points.
        fn diffLinesToChars(
            difference: *Diff,
            allocator: Allocator,
            text1: []const u8,
            text2: []const u8,
        ) DiffError!LinesToCharsResult {
            var line_array: ArrayListUnmanaged([]const u8) = .empty;
            errdefer line_array.deinit(allocator);
            line_array.items.len = 0;
            var line_hash = std.StringHashMapUnmanaged(u31){};
            defer line_hash.deinit(allocator);

            const chars1 = try difference.diffLinesToCharsMunge(allocator, text1, &line_array, &line_hash);
            errdefer allocator.free(chars1);
            const chars2 = try difference.diffLinesToCharsMunge(allocator, text2, &line_array, &line_hash);
            return .{ .chars_1 = chars1, .chars_2 = chars2, .line_array = line_array };
        }

        /// Encode one text by iterating configured segments.
        fn diffLinesToCharsMunge(
            difference: *Diff,
            allocator: Allocator,
            text: []const u8,
            line_array: *ArrayListUnmanaged([]const u8),
            line_hash: *std.StringHashMapUnmanaged(u31),
        ) DiffError![]const u8 {
            var iter = makeIterator(text);
            return difference.diffIteratorToCharsMunge(allocator, line_array, line_hash, &iter);
        }

        /// Reduce a segment stream to Unicode code points representing each
        /// unique segment.
        fn diffIteratorToCharsMunge(
            _: *Diff,
            allocator: Allocator,
            segment_array: *ArrayListUnmanaged([]const u8),
            segment_hash: *std.StringHashMapUnmanaged(u31),
            iterator: anytype,
        ) DiffError![]const u8 {
            var chars: ArrayListUnmanaged(u8) = .empty;
            defer chars.deinit(allocator);
            var codepoint: u31 = cast(u31, segment_array.items.len) + CHAR_OFFSET;
            var char_buf: [6]u8 = undefined;
            while (iterator.next()) |line| {
                if (segment_hash.get(line)) |value| {
                    const nbytes = common.plan9Encode(value, &char_buf);
                    try chars.appendSlice(allocator, char_buf[0..nbytes]);
                } else {
                    if (codepoint == std.math.maxInt(u31) - CHAR_OFFSET) {
                        return error.TooManySegments;
                    }
                    try segment_array.append(allocator, line);
                    try segment_hash.put(allocator, line, codepoint);
                    const nbytes = common.plan9Encode(codepoint, &char_buf);
                    try chars.appendSlice(allocator, char_buf[0..nbytes]);
                    codepoint += 1;
                }
            }
            return chars.toOwnedSlice(allocator);
        }

        /// Reorder and merge like edit sections.  Merge equalities.
        fn cleanupMergeImpl(difference: *Diff, allocator: Allocator, diffs: *DiffList) OOM!void {
            try diffs.append(allocator, Edit.asBorrow(.equal, ""));
            var pointer: usize = 0;
            var count_delete: usize = 0;
            var count_insert: usize = 0;

            var delete_run: ArrayListUnmanaged(*const Edit) = .empty;
            defer delete_run.deinit(allocator);
            var insert_run: ArrayListUnmanaged(*const Edit) = .empty;
            defer insert_run.deinit(allocator);

            while (pointer < diffs.items.len) {
                switch (diffs.items[pointer].operation) {
                    .insert => {
                        count_insert += 1;
                        try insert_run.append(allocator, &diffs.items[pointer]);
                        pointer += 1;
                    },
                    .delete => {
                        count_delete += 1;
                        try delete_run.append(allocator, &diffs.items[pointer]);
                        pointer += 1;
                    },
                    .equal => {
                        if (count_delete + count_insert > 1) {
                            const all_borrowed = diffRunAllBorrowed(delete_run.items) and diffRunAllBorrowed(insert_run.items);
                            var owned_insert: ?[]u8 = null;
                            defer if (owned_insert) |text| allocator.free(text);
                            var owned_delete: ?[]u8 = null;
                            defer if (owned_delete) |text| allocator.free(text);
                            var text_insert = if (all_borrowed)
                                diffBorrowedRunSpan(insert_run.items) orelse blk: {
                                    owned_insert = try diffMaterializeRun(allocator, insert_run.items);
                                    break :blk owned_insert.?;
                                }
                            else blk: {
                                owned_insert = try diffMaterializeRun(allocator, insert_run.items);
                                break :blk owned_insert.?;
                            };
                            var text_delete = if (all_borrowed)
                                diffBorrowedRunSpan(delete_run.items) orelse blk: {
                                    owned_delete = try diffMaterializeRun(allocator, delete_run.items);
                                    break :blk owned_delete.?;
                                }
                            else blk: {
                                owned_delete = try diffMaterializeRun(allocator, delete_run.items);
                                break :blk owned_delete.?;
                            };
                            const must_own = owned_insert != null or owned_delete != null or diffs.items[pointer].owned or
                                ((pointer - count_delete - count_insert) > 0 and diffs.items[pointer - count_delete - count_insert - 1].owned);
                            if (count_delete != 0 and count_insert != 0) {
                                var common_length = diffCommonPrefix(text_insert, text_delete);
                                if (common_length != 0) {
                                    if ((pointer - count_delete - count_insert) > 0 and diffs.items[pointer - count_delete - count_insert - 1].operation == .equal) {
                                        const ii = pointer - count_delete - count_insert - 1;
                                        const old_equal = diffs.items[ii];
                                        if (!must_own and !old_equal.owned and old_equal.text.ptr + old_equal.text.len == text_delete.ptr) {
                                            diffs.items[ii] = Edit.asBorrow(.equal, old_equal.text.ptr[0 .. old_equal.text.len + common_length]);
                                        } else {
                                            diffs.items[ii] = try diffMakeOwnedConcat2(Edit, allocator, .equal, old_equal.text, text_delete[0..common_length]);
                                            var equal_to_deinit = old_equal;
                                            equal_to_deinit.deinit(allocator);
                                        }
                                    } else {
                                        try diffs.ensureUnusedCapacity(allocator, 1);
                                        diffs.insertAssumeCapacity(0, try Edit.asBool(allocator, .equal, must_own, text_delete[0..common_length]));
                                        pointer += 1;
                                    }
                                    text_insert = text_insert[common_length..];
                                    text_delete = text_delete[common_length..];
                                }
                                common_length = diffCommonSuffix(text_insert, text_delete);
                                if (common_length != 0) {
                                    const old_edit = diffs.items[pointer];
                                    if (!must_own and !old_edit.owned and text_delete.ptr + text_delete.len - common_length == old_edit.text.ptr) {
                                        unreachable;
                                    } else {
                                        diffs.items[pointer] = try diffMakeOwnedConcat2(
                                            Edit,
                                            allocator,
                                            old_edit.operation,
                                            text_delete[text_delete.len - common_length ..],
                                            old_edit.text,
                                        );
                                        var edit_to_deinit = old_edit;
                                        edit_to_deinit.deinit(allocator);
                                    }
                                    text_insert = text_insert[0 .. text_insert.len - common_length];
                                    text_delete = text_delete[0 .. text_delete.len - common_length];
                                }
                            }
                            pointer -= count_delete + count_insert;
                            if (count_delete + count_insert > 0) {
                                var remove_i: usize = 0;
                                while (remove_i < count_delete + count_insert) : (remove_i += 1) {
                                    var removed = diffs.orderedRemove(pointer);
                                    removed.deinit(allocator);
                                }
                            }

                            if (text_delete.len != 0) {
                                try diffs.ensureUnusedCapacity(allocator, 1);
                                diffs.insertAssumeCapacity(pointer, try Edit.asBool(allocator, .delete, must_own, text_delete));
                                pointer += 1;
                            }
                            if (text_insert.len != 0) {
                                try diffs.ensureUnusedCapacity(allocator, 1);
                                diffs.insertAssumeCapacity(pointer, try Edit.asBool(allocator, .insert, must_own, text_insert));
                                pointer += 1;
                            }
                            pointer += 1;
                        } else if (pointer != 0 and diffs.items[pointer - 1].operation == .equal) {
                            const old_prev = diffs.items[pointer - 1];
                            const old_curr = diffs.items[pointer];
                            if (!old_prev.owned and !old_curr.owned and old_prev.text.ptr + old_prev.text.len == old_curr.text.ptr) {
                                diffs.items[pointer - 1] = Edit.asBorrow(.equal, old_prev.text.ptr[0 .. old_prev.text.len + old_curr.text.len]);
                            } else {
                                diffs.items[pointer - 1] = try diffMakeOwnedConcat2(Edit, allocator, .equal, old_prev.text, old_curr.text);
                                var prev_to_deinit = old_prev;
                                prev_to_deinit.deinit(allocator);
                            }
                            var dead = diffs.orderedRemove(pointer);
                            dead.deinit(allocator);
                        } else {
                            pointer += 1;
                        }
                        count_insert = 0;
                        count_delete = 0;
                        delete_run.items.len = 0;
                        insert_run.items.len = 0;
                    },
                }
            }
            if (diffs.items[diffs.items.len - 1].text.len == 0) diffs.items.len -= 1;

            var changes = false;
            pointer = 1;
            while (pointer < (diffs.items.len - 1)) {
                if (diffs.items[pointer - 1].operation == .equal and diffs.items[pointer + 1].operation == .equal) {
                    if (std.mem.endsWith(u8, diffs.items[pointer].text, diffs.items[pointer - 1].text)) {
                        const old_edit = diffs.items[pointer];
                        const pt = try std.mem.concat(allocator, u8, &.{
                            diffs.items[pointer - 1].text,
                            diffs.items[pointer].text[0 .. diffs.items[pointer].text.len - diffs.items[pointer - 1].text.len],
                        });
                        diffs.items[pointer].text = pt;
                        diffs.items[pointer].owned = true;
                        var edit_to_deinit = old_edit;
                        edit_to_deinit.deinit(allocator);
                        const old_edit1 = diffs.items[pointer + 1];
                        const p1t = try std.mem.concat(allocator, u8, &.{ diffs.items[pointer - 1].text, diffs.items[pointer + 1].text });
                        diffs.items[pointer + 1].text = p1t;
                        diffs.items[pointer + 1].owned = true;
                        var edit1_to_deinit = old_edit1;
                        edit1_to_deinit.deinit(allocator);
                        freeRangeDiffList(allocator, diffs, pointer - 1, 1);
                        try diffs.replaceRange(allocator, pointer - 1, 1, &.{});
                        changes = true;
                    } else if (std.mem.startsWith(u8, diffs.items[pointer].text, diffs.items[pointer + 1].text)) {
                        const old_editm1 = diffs.items[pointer - 1];
                        const pm1t = try std.mem.concat(allocator, u8, &.{ diffs.items[pointer - 1].text, diffs.items[pointer + 1].text });
                        diffs.items[pointer - 1].text = pm1t;
                        diffs.items[pointer - 1].owned = true;
                        var editm1_to_deinit = old_editm1;
                        editm1_to_deinit.deinit(allocator);
                        const old_edit = diffs.items[pointer];
                        const pt = try std.mem.concat(allocator, u8, &.{
                            diffs.items[pointer].text[diffs.items[pointer + 1].text.len..],
                            diffs.items[pointer + 1].text,
                        });
                        diffs.items[pointer].text = pt;
                        diffs.items[pointer].owned = true;
                        var edit_to_deinit = old_edit;
                        edit_to_deinit.deinit(allocator);
                        freeRangeDiffList(allocator, diffs, pointer + 1, 1);
                        try diffs.replaceRange(allocator, pointer + 1, 1, &.{});
                        changes = true;
                    }
                }
                pointer += 1;
            }

            if (changes) try difference.cleanupMergeImpl(allocator, diffs);
        }

        /// Reduce the number of edits by eliminating semantically trivial
        /// equalities.
        fn cleanupSemanticImpl(difference: *Diff, allocator: Allocator, diffs: *DiffList) OOM!void {
            var changes = false;
            var equalities: ArrayListUnmanaged(usize) = .empty;
            defer equalities.deinit(allocator);
            var last_equality: ?Edit = null;
            var pointer: usize = 0;
            var length_insertions1: usize = 0;
            var length_deletions1: usize = 0;
            var length_insertions2: usize = 0;
            var length_deletions2: usize = 0;
            var reset_pointer = false;
            while (pointer < diffs.items.len) {
                if (diffs.items[pointer].operation == .equal) {
                    try equalities.append(allocator, pointer);
                    length_insertions1 = length_insertions2;
                    length_deletions1 = length_deletions2;
                    length_insertions2 = 0;
                    length_deletions2 = 0;
                    last_equality = diffs.items[pointer];
                } else {
                    if (diffs.items[pointer].operation == .insert) {
                        length_insertions2 += diffs.items[pointer].text.len;
                    } else {
                        length_deletions2 += diffs.items[pointer].text.len;
                    }
                    if (last_equality != null and
                        (last_equality.?.text.len <= @max(length_insertions1, length_deletions1)) and
                        (last_equality.?.text.len <= @max(length_insertions2, length_deletions2)))
                    {
                        const the_eq = last_equality.?;
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        diffs.insertAssumeCapacity(equalities.items[equalities.items.len - 1], try Edit.asBool(allocator, .delete, the_eq.owned, the_eq.text));
                        diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                        _ = equalities.pop();
                        if (equalities.items.len > 0) _ = equalities.pop();
                        if (equalities.items.len > 0) {
                            pointer = equalities.items[equalities.items.len - 1];
                        } else {
                            reset_pointer = true;
                        }
                        length_insertions1 = 0;
                        length_deletions1 = 0;
                        length_insertions2 = 0;
                        length_deletions2 = 0;
                        last_equality = null;
                        changes = true;
                    }
                }
                if (reset_pointer) {
                    pointer = 0;
                    reset_pointer = false;
                } else {
                    pointer += 1;
                }
            }

            if (changes) try difference.cleanupMergeImpl(allocator, diffs);
            try difference.cleanupSemanticLosslessImpl(allocator, diffs);

            pointer = 1;
            while (pointer < diffs.items.len) {
                if (diffs.items[pointer - 1].operation == .delete and diffs.items[pointer].operation == .insert) {
                    const delete_edit = diffs.items[pointer - 1];
                    const insert_edit = diffs.items[pointer];
                    const deletion = delete_edit.text;
                    const insertion = insert_edit.text;
                    const raw_overlap_length1 = diffCommonOverlap(deletion, insertion);
                    const overlap_length1 = @min(
                        deletion.len - fixSplitForward(deletion, deletion.len - raw_overlap_length1),
                        fixSplitBackward(insertion, raw_overlap_length1),
                    );
                    const raw_overlap_length2 = diffCommonOverlap(insertion, deletion);
                    const overlap_length2 = @min(
                        insertion.len - fixSplitForward(insertion, insertion.len - raw_overlap_length2),
                        fixSplitBackward(deletion, raw_overlap_length2),
                    );
                    if (overlap_length1 >= overlap_length2) {
                        if (@as(f32, @floatFromInt(overlap_length1)) >= @as(f32, @floatFromInt(deletion.len)) / 2.0 or
                            @as(f32, @floatFromInt(overlap_length1)) >= @as(f32, @floatFromInt(insertion.len)) / 2.0)
                        {
                            try diffs.ensureUnusedCapacity(allocator, 1);
                            diffs.insertAssumeCapacity(pointer, try Edit.asBool(allocator, .equal, delete_edit.owned, deletion[deletion.len - overlap_length1 ..]));
                            var new_minus = try Edit.asBool(allocator, .delete, delete_edit.owned, deletion[0 .. deletion.len - overlap_length1]);
                            errdefer new_minus.deinit(allocator);
                            const new_plus = try Edit.asBool(allocator, .insert, insert_edit.owned, insertion[overlap_length1..]);
                            var delete_to_deinit = delete_edit;
                            delete_to_deinit.deinit(allocator);
                            var insert_to_deinit = insert_edit;
                            insert_to_deinit.deinit(allocator);
                            diffs.items[pointer - 1] = new_minus;
                            diffs.items[pointer + 1] = new_plus;
                            pointer += 1;
                        }
                    } else if (@as(f32, @floatFromInt(overlap_length2)) >= @as(f32, @floatFromInt(deletion.len)) / 2.0 or
                        @as(f32, @floatFromInt(overlap_length2)) >= @as(f32, @floatFromInt(insertion.len)) / 2.0)
                    {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        diffs.insertAssumeCapacity(pointer, try Edit.asBool(allocator, .equal, delete_edit.owned, deletion[0..overlap_length2]));
                        var new_minus = try Edit.asBool(allocator, .insert, insert_edit.owned, insertion[0 .. insertion.len - overlap_length2]);
                        errdefer new_minus.deinit(allocator);
                        const new_plus = try Edit.asBool(allocator, .delete, delete_edit.owned, deletion[overlap_length2..]);
                        var delete_to_deinit = delete_edit;
                        delete_to_deinit.deinit(allocator);
                        var insert_to_deinit = insert_edit;
                        insert_to_deinit.deinit(allocator);
                        diffs.items[pointer - 1] = new_minus;
                        diffs.items[pointer + 1] = new_plus;
                        pointer += 1;
                    }
                    pointer += 1;
                }
                pointer += 1;
            }
        }

        /// Look for single edits surrounded on both sides by equalities
        /// which can be shifted sideways to align the edit to a word boundary.
        fn cleanupSemanticLosslessImpl(difference: *Diff, allocator: Allocator, diffs: *DiffList) OOM!void {
            if (diffs.items.len < 3) return;
            var pointer: usize = 1;
            while (pointer < diffs.items.len - 1) {
                if (diffs.items[pointer - 1].operation == .equal and diffs.items[pointer + 1].operation == .equal) {
                    if (diffCleanupSemanticLosslessWindow(diffs, pointer)) |window| {
                        difference.cleanupSemanticLosslessBorrowed(diffs, &pointer, window);
                    } else {
                        try difference.cleanupSemanticLosslessOwned(allocator, diffs, &pointer);
                    }
                }
                pointer += 1;
            }
        }

        /// Owned-path semantic lossless cleanup for windows that cannot be
        /// safely rewritten as borrows.
        fn cleanupSemanticLosslessOwned(
            difference: *Diff,
            allocator: Allocator,
            diffs: *DiffList,
            pointer: *usize,
        ) OOM!void {
            var equality_1: std.ArrayListUnmanaged(u8) = .empty;
            defer equality_1.deinit(allocator);
            try equality_1.appendSlice(allocator, diffs.items[pointer.* - 1].text);

            var edit: std.ArrayListUnmanaged(u8) = .empty;
            defer edit.deinit(allocator);
            try edit.appendSlice(allocator, diffs.items[pointer.*].text);

            var equality_2: std.ArrayListUnmanaged(u8) = .empty;
            defer equality_2.deinit(allocator);
            try equality_2.appendSlice(allocator, diffs.items[pointer.* + 1].text);

            const common_offset = diffCommonSuffix(equality_1.items, edit.items);
            if (common_offset > 0) {
                const common_string = try allocator.dupe(u8, edit.items[edit.items.len - common_offset ..]);
                defer allocator.free(common_string);
                equality_1.items.len -= common_offset;
                const not_common = try allocator.dupe(u8, edit.items[0 .. edit.items.len - common_offset]);
                defer allocator.free(not_common);
                edit.clearRetainingCapacity();
                try edit.appendSlice(allocator, common_string);
                try edit.appendSlice(allocator, not_common);
                try equality_2.insertSlice(allocator, 0, common_string);
            }

            var best_equality_1: ArrayListUnmanaged(u8) = .empty;
            defer best_equality_1.deinit(allocator);
            try best_equality_1.appendSlice(allocator, equality_1.items);
            var best_edit: ArrayListUnmanaged(u8) = .empty;
            defer best_edit.deinit(allocator);
            try best_edit.appendSlice(allocator, edit.items);
            var best_equality_2: ArrayListUnmanaged(u8) = .empty;
            defer best_equality_2.deinit(allocator);
            try best_equality_2.appendSlice(allocator, equality_2.items);

            var best_score = difference.cleanupSemanticScore(equality_1.items, edit.items) + difference.cleanupSemanticScore(edit.items, equality_2.items);

            while (hasSharedPrefixLen(edit.items, equality_2.items)) |cp_len| {
                var cp_buf: [4]u8 = undefined;
                @memcpy(cp_buf[0..cp_len], edit.items[0..cp_len]);
                try equality_1.appendSlice(allocator, cp_buf[0..cp_len]);

                std.mem.copyForwards(u8, edit.items[0 .. edit.items.len - cp_len], edit.items[cp_len..]);
                edit.items.len -= cp_len;
                try edit.appendSlice(allocator, equality_2.items[0..cp_len]);

                std.mem.copyForwards(u8, equality_2.items[0 .. equality_2.items.len - cp_len], equality_2.items[cp_len..]);
                equality_2.items.len -= cp_len;

                const score = difference.cleanupSemanticScore(equality_1.items, edit.items) + difference.cleanupSemanticScore(edit.items, equality_2.items);
                if (score >= best_score) {
                    best_score = score;
                    best_equality_1.items.len = 0;
                    try best_equality_1.appendSlice(allocator, equality_1.items);
                    best_edit.items.len = 0;
                    try best_edit.appendSlice(allocator, edit.items);
                    best_equality_2.items.len = 0;
                    try best_equality_2.appendSlice(allocator, equality_2.items);
                }
            }

            if (!std.mem.eql(u8, diffs.items[pointer.* - 1].text, best_equality_1.items)) {
                if (best_equality_1.items.len != 0) {
                    const new_diff = try Edit.asOwn(allocator, .equal, best_equality_1.items);
                    var old_diff = diffs.items[pointer.* - 1];
                    diffs.items[pointer.* - 1] = new_diff;
                    old_diff.deinit(allocator);
                } else {
                    var old_diff = diffs.orderedRemove(pointer.* - 1);
                    old_diff.deinit(allocator);
                    pointer.* -= 1;
                }
                {
                    const new_diff = try Edit.asOwn(allocator, diffs.items[pointer.*].operation, best_edit.items);
                    var old_diff = diffs.items[pointer.*];
                    diffs.items[pointer.*] = new_diff;
                    old_diff.deinit(allocator);
                }
                if (best_equality_2.items.len != 0) {
                    const new_diff = try Edit.asOwn(allocator, .equal, best_equality_2.items);
                    var old_diff = diffs.items[pointer.* + 1];
                    diffs.items[pointer.* + 1] = new_diff;
                    old_diff.deinit(allocator);
                } else {
                    var removed_diff = diffs.orderedRemove(pointer.* + 1);
                    removed_diff.deinit(allocator);
                    pointer.* -= 1;
                }
            }
        }

        /// Borrowed-path semantic lossless cleanup when the surrounding text
        /// is one contiguous span.
        fn cleanupSemanticLosslessBorrowed(difference: *Diff, diffs: *DiffList, pointer: *usize, window: BorrowedLosslessWindow) void {
            var equality_1 = window.equality_1;
            var edit = window.edit;
            var equality_2 = window.equality_2;
            std.debug.assert(canBorrowLosslessWindow(equality_1, edit, equality_2));

            const common_offset = diffCommonSuffix(equality_1, edit);
            if (common_offset > 0) {
                const old_equality_1 = equality_1;
                const old_edit = edit;
                equality_1 = old_equality_1[0 .. old_equality_1.len - common_offset];
                edit = old_equality_1[old_equality_1.len - common_offset ..].ptr[0..old_edit.len];
                equality_2 = old_edit[old_edit.len - common_offset ..].ptr[0 .. equality_2.len + common_offset];
            }

            var best_equality_1 = equality_1;
            var best_edit = edit;
            var best_equality_2 = equality_2;
            var best_score = difference.cleanupSemanticScore(equality_1, edit) + difference.cleanupSemanticScore(edit, equality_2);

            while (hasSharedPrefixLen(edit, equality_2)) |cp_len| {
                const old_edit = edit;
                equality_1 = equality_1.ptr[0 .. equality_1.len + cp_len];
                edit = old_edit[cp_len..].ptr[0..old_edit.len];
                equality_2 = equality_2[cp_len..];

                const score = difference.cleanupSemanticScore(equality_1, edit) + difference.cleanupSemanticScore(edit, equality_2);
                if (score >= best_score) {
                    best_score = score;
                    best_equality_1 = equality_1;
                    best_edit = edit;
                    best_equality_2 = equality_2;
                }
            }

            if (!std.mem.eql(u8, diffs.items[pointer.* - 1].text, best_equality_1)) {
                if (best_equality_1.len != 0) {
                    diffs.items[pointer.* - 1] = Edit.asBorrow(.equal, best_equality_1);
                } else {
                    _ = diffs.orderedRemove(pointer.* - 1);
                    pointer.* -= 1;
                }
                diffs.items[pointer.*] = Edit.asBorrow(diffs.items[pointer.*].operation, best_edit);
                if (best_equality_2.len != 0) {
                    diffs.items[pointer.* + 1] = Edit.asBorrow(.equal, best_equality_2);
                } else {
                    _ = diffs.orderedRemove(pointer.* + 1);
                    pointer.* -= 1;
                }
            }
        }

        /// Reduce the number of edits by eliminating operationally trivial
        /// equalities.
        fn cleanupEfficiencyImpl(difference: *Diff, allocator: Allocator, diffs: *DiffList) OOM!void {
            var changes = false;
            var equalities = ArrayList(usize).init(allocator);
            defer equalities.deinit();
            var last_equality: ?Edit = null;
            var ipointer: isize = 0;
            var pre_ins = false;
            var pre_del = false;
            var post_ins = false;
            var post_del = false;
            while (ipointer < diffs.items.len) {
                const pointer: usize = @intCast(ipointer);
                if (diffs.items[pointer].operation == .equal) {
                    if (diffs.items[pointer].text.len < difference.config.edit_cost and (post_ins or post_del)) {
                        try equalities.append(pointer);
                        pre_ins = post_ins;
                        pre_del = post_del;
                        last_equality = diffs.items[pointer];
                    } else {
                        equalities.items.len = 0;
                        last_equality = null;
                    }
                    post_ins = false;
                    post_del = false;
                } else {
                    if (diffs.items[pointer].operation == .delete) post_del = true else post_ins = true;
                    if ((last_equality != null) and
                        ((pre_ins and pre_del and post_ins and post_del) or
                            ((last_equality.?.text.len < difference.config.edit_cost / 2) and
                                (boolInt(pre_ins) + boolInt(pre_del) + boolInt(post_ins) + boolInt(post_del) == 3))))
                    {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        diffs.insertAssumeCapacity(
                            equalities.items[equalities.items.len - 1],
                            try Edit.asBool(allocator, .delete, last_equality.?.owned, last_equality.?.text),
                        );
                        diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                        _ = equalities.pop();
                        last_equality = null;
                        if (pre_ins and pre_del) {
                            post_ins = true;
                            post_del = true;
                            equalities.items.len = 0;
                        } else {
                            if (equalities.items.len > 0) _ = equalities.pop();
                            ipointer = if (equalities.items.len > 0) @intCast(equalities.items[equalities.items.len - 1]) else -1;
                            post_ins = false;
                            post_del = false;
                        }
                        changes = true;
                    }
                }
                ipointer += 1;
            }

            if (changes) try difference.cleanupMergeImpl(allocator, diffs);
        }

        /// Copy this specialization while forcing text-mode recursion.
        fn copyForTextMode(difference: *const Diff) Diff {
            var cfg = difference.config;
            cfg.check_lines = false;
            return .{
                .config = cfg,
                .context = difference.context,
                .edits = .empty,
            };
        }
    };
}

/// Rehydrate the text in a diff from a string of segment hashes to real text.
fn diffCharsToLines(
    allocator: Allocator,
    char_diffs: *DiffList,
    line_array: []const []const u8,
    before_text: []const u8,
    after_text: []const u8,
) OOM!DiffList {
    var text: ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    var diffs: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diffs);
    try diffs.ensureUnusedCapacity(allocator, char_diffs.items.len);
    var before_cursor: usize = 0;
    var after_cursor: usize = 0;
    for (char_diffs.items) |*edit| {
        var cursor: usize = 0;
        while (cursor < edit.text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(edit.text[cursor]) catch @panic("Internal decode error in diffCharsToLines");
            const cp = std.unicode.wtf8Decode(edit.text[cursor..][0..cp_len]) catch @panic("Internal decode error in diffCharsToLines");
            try text.appendSlice(allocator, line_array[cp - CHAR_OFFSET]);
            cursor += cp_len;
        }
        switch (edit.operation) {
            .equal => {
                const span = before_text[before_cursor..][0..text.items.len];
                dbgassert(std.mem.startsWith(u8, before_text[before_cursor..], text.items));
                dbgassert(std.mem.startsWith(u8, after_text[after_cursor..], text.items));
                dbgassert(std.mem.eql(u8, span, text.items));
                before_cursor += text.items.len;
                after_cursor += text.items.len;
                diffs.appendAssumeCapacity(Edit.asBorrow(.equal, span));
            },
            .delete => {
                const span = before_text[before_cursor..][0..text.items.len];
                dbgassert(std.mem.startsWith(u8, before_text[before_cursor..], text.items));
                dbgassert(std.mem.eql(u8, span, text.items));
                before_cursor += text.items.len;
                diffs.appendAssumeCapacity(Edit.asBorrow(.delete, span));
            },
            .insert => {
                const span = after_text[after_cursor..][0..text.items.len];
                dbgassert(std.mem.startsWith(u8, after_text[after_cursor..], text.items));
                dbgassert(std.mem.eql(u8, span, text.items));
                after_cursor += text.items.len;
                diffs.appendAssumeCapacity(Edit.asBorrow(.insert, span));
            },
        }
        text.items.len = 0;
    }
    return diffs;
}

/// Detect a fully borrowed three-edit window suitable for lossless cleanup.
fn diffCleanupSemanticLosslessWindow(diffs: *const DiffList, pointer: usize) ?BorrowedLosslessWindow {
    const equality_1 = diffs.items[pointer - 1];
    const edit = diffs.items[pointer];
    const equality_2 = diffs.items[pointer + 1];
    if (equality_1.owned or edit.owned or equality_2.owned) return null;
    return switch (edit.operation) {
        .insert, .delete => deriveBorrowedLosslessWindow(equality_1.text, edit.text, equality_2.text),
        .equal => null,
    };
}

/// Check whether three adjacent slices form one contiguous borrowed window.
fn canBorrowLosslessWindow(equality_1: []const u8, edit: []const u8, equality_2: []const u8) bool {
    return equality_1.ptr + equality_1.len == edit.ptr and edit.ptr + edit.len == equality_2.ptr;
}

/// Recover a contiguous borrowed window when the slices are equivalent views.
fn deriveBorrowedLosslessWindow(equality_1: []const u8, edit: []const u8, equality_2: []const u8) ?BorrowedLosslessWindow {
    if (canBorrowLosslessWindow(equality_1, edit, equality_2)) {
        return .{ .equality_1 = equality_1, .edit = edit, .equality_2 = equality_2 };
    }
    const derived_equality_1 = (edit.ptr - equality_1.len)[0..equality_1.len];
    const derived_equality_2 = (edit.ptr + edit.len)[0..equality_2.len];
    if (!std.mem.eql(u8, derived_equality_1, equality_1) or !std.mem.eql(u8, derived_equality_2, equality_2)) {
        return null;
    }
    return .{ .equality_1 = derived_equality_1, .edit = edit, .equality_2 = derived_equality_2 };
}

fn hasContextDefault(comptime Context: type) bool {
    if (!typeCanHaveDecls(Context)) return false;
    if (@hasDecl(Context, "default")) return true;
    if (@hasDecl(Context, "empty")) return true;
    return false;
}

fn defaultContext(comptime Context: type) Context {
    if (comptime typeCanHaveDecls(Context)) {
        if (@hasDecl(Context, "default")) return Context.default;
        if (@hasDecl(Context, "empty")) return Context.empty;
    }
    if (Context == void) return {};
    return undefined;
}

fn typeCanHaveDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

const DefaultDiff = DiffFn(.{});

fn expectEqualDiff(expected: []const Edit, actual: []const Edit) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.operation, a.operation);
        try testing.expectEqualStrings(e.text, a.text);
    }
}

fn diffFnListFromConfig(
    allocator: Allocator,
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
) !DiffList {
    var diff_obj = DefaultDiff.init(config);
    defer diff_obj.deinit(allocator);
    _ = try diff_obj.diff(allocator, before, after);
    const diffs = diff_obj.edits;
    diff_obj.edits = .empty;
    return diffs;
}

fn sliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !DiffList {
    var diff_list: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diff_list);
    try diff_list.ensureTotalCapacity(allocator, diff_slice.len);
    for (diff_slice) |edit| {
        diff_list.appendAssumeCapacity(try Edit.asOwn(
            allocator,
            edit.operation,
            edit.text,
        ));
    }
    return diff_list;
}

const TestHalfMatch = struct {
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
    expected: ?HalfMatchResult,
};

const TCharLines = struct {
    before: []const u8,
    after: []const u8,
    diffs: []const Edit,
    line_array: []const []const u8,
    expected: []const Edit,
};

const TestIO = struct {
    input: []const Edit,
    expected: []const Edit,
};

const TRebuild = struct {
    before: []const u8,
    after: []const u8,
};

const TBisect = struct {
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
    deadline: u64,
    expected: []const Edit,
};

const TDiff = struct {
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
    expected: []const Edit,
};

fn testDiffFnHalfMatch(
    allocator: Allocator,
    params: TestHalfMatch,
) !void {
    var difference = DefaultDiff.init(params.config);
    const maybe_result = try difference.diffHalfMatch(allocator, params.before, params.after);
    try testing.expectEqualDeep(params.expected, maybe_result);
}

fn testDiffFnHalfMatchLeak(allocator: Allocator) !void {
    const config = DiffConfig.default;
    const text1 = "The quick brown fox jumps over the lazy dog.";
    const text2 = "That quick brown fox jumped over a lazy dog.";
    var diffs = try diffFnListFromConfig(allocator, config, text2, text1);
    deinitDiffList(allocator, &diffs);
}

fn testDiffFnCharsToLines(
    allocator: Allocator,
    params: TCharLines,
) !void {
    var char_diffs = try DiffList.initCapacity(allocator, params.diffs.len);
    defer deinitDiffList(allocator, &char_diffs);

    for (params.diffs) |item| {
        char_diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }

    var diffs = try diffCharsToLines(allocator, &char_diffs, params.line_array, params.before, params.after);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnCleanupMerge(
    allocator: Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupMergeImpl(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnCleanupMergeBorrowed(params: TestIO) !void {
    var diffs = try DiffList.initCapacity(testing.allocator, params.input.len);
    defer deinitDiffList(testing.allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(Edit.asBorrow(item.operation, item.text));
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupMergeImpl(testing.allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnCleanupSemanticLossless(
    allocator: Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupSemanticLosslessImpl(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnCleanupSemanticLosslessBorrowed(params: TestIO) !void {
    var diffs = try DiffList.initCapacity(testing.allocator, params.input.len);
    defer deinitDiffList(testing.allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(Edit.asBorrow(item.operation, item.text));
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupSemanticLosslessImpl(testing.allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
    for (diffs.items) |item| {
        try testing.expect(!item.owned);
    }
}

fn testDiffFnCleanupSemanticLosslessBorrowedRoundTrip(
    input: []const Edit,
    expected_before: []const u8,
    expected_after: []const u8,
) !void {
    var diffs = try DiffList.initCapacity(testing.allocator, input.len);
    defer deinitDiffList(testing.allocator, &diffs);
    for (input) |item| {
        diffs.appendAssumeCapacity(Edit.asBorrow(item.operation, item.text));
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupSemanticLosslessImpl(testing.allocator, &diffs);
    const before = try diffBeforeText(testing.allocator, diffs);
    defer testing.allocator.free(before);
    const after = try diffAfterText(testing.allocator, diffs);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(expected_before, before);
    try testing.expectEqualStrings(expected_after, after);
    for (diffs.items) |item| {
        try testing.expect(!item.owned);
    }
}

fn testDiffFnCleanupSemantic(
    allocator: Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupSemanticImpl(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnCleanupSemanticRoundTrip(
    allocator: Allocator,
    input: []const Edit,
    expected_before: []const u8,
    expected_after: []const u8,
) !void {
    var diffs = try DiffList.initCapacity(allocator, input.len);
    defer deinitDiffList(allocator, &diffs);
    for (input) |item| {
        diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    var difference: DefaultDiff = .default;
    try difference.cleanupSemanticImpl(allocator, &diffs);
    const before = try diffBeforeText(allocator, diffs);
    defer allocator.free(before);
    const after = try diffAfterText(allocator, diffs);
    defer allocator.free(after);
    try testing.expectEqualStrings(expected_before, before);
    try testing.expectEqualStrings(expected_after, after);
}

fn testDiffFnCleanupEfficiency(
    allocator: Allocator,
    config: DiffConfig,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    var difference = DefaultDiff.init(config);
    try difference.cleanupEfficiencyImpl(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnCloneDiffList(allocator: Allocator, diff_slice: []const Edit) !void {
    var diffs = try sliceToDiffList(allocator, diff_slice);
    defer deinitDiffList(allocator, &diffs);
    var cloned = try cloneDiffList(allocator, &diffs);
    defer deinitDiffList(allocator, &cloned);
    try expectEqualDiff(diff_slice, cloned.items);
}

fn testDiffFnSliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !void {
    var diffs = try sliceToDiffList(allocator, diff_slice);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(diff_slice, diffs.items);
}

fn testDiffFnBisect(
    allocator: Allocator,
    params: TBisect,
) !void {
    var difference = DefaultDiff.init(params.config);
    var diffs = try difference.diffBisect(allocator, params.before, params.after, params.deadline);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnBisectSplitCase(
    allocator: Allocator,
    config: DiffConfig,
    text1: []const u8,
    text2: []const u8,
    x: isize,
    y: isize,
) !void {
    var difference = DefaultDiff.init(config);
    var diffs = try difference.diffBisectSplit(allocator, text1, text2, x, y, std.math.maxInt(i64));
    defer deinitDiffList(allocator, &diffs);
}

fn testDiffFn(
    allocator: Allocator,
    params: TDiff,
) !void {
    var diffs = try diffFnListFromConfig(allocator, params.config, params.before, params.after);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn testDiffFnLineMode(
    allocator: Allocator,
    threshold: u32,
    before: []const u8,
    after: []const u8,
) !void {
    const checked_config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 0;
        config.check_lines = true;
        config.check_line_threshold = threshold;
        break :blk config;
    };
    var diff_checked = try diffFnListFromConfig(allocator, checked_config, before, after);
    defer deinitDiffList(allocator, &diff_checked);

    var unchecked_config = checked_config;
    unchecked_config.check_lines = false;
    var diff_unchecked = try diffFnListFromConfig(allocator, unchecked_config, before, after);
    defer deinitDiffList(allocator, &diff_unchecked);

    try expectEqualDiff(diff_checked.items, diff_unchecked.items);
}

fn diffFnRoundTrip(allocator: Allocator, config: DiffConfig, diff_slice: []const Edit) !void {
    var diffs_before = try DiffList.initCapacity(allocator, diff_slice.len);
    defer deinitDiffList(allocator, &diffs_before);
    for (diff_slice) |item| {
        diffs_before.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    const text_before = try diffBeforeText(allocator, diffs_before);
    defer allocator.free(text_before);
    const text_after = try diffAfterText(allocator, diffs_before);
    defer allocator.free(text_after);
    var diffs_after = try diffFnListFromConfig(allocator, config, text_before, text_after);
    defer deinitDiffList(allocator, &diffs_after);
    var difference = DefaultDiff.init(config);
    try difference.cleanupSemanticImpl(allocator, &diffs_after);
    try expectEqualDiff(diffs_before.items, diffs_after.items);
}

fn rebuildtexts(allocator: Allocator, diffs: DiffList) ![2][]const u8 {
    var text = [2]ArrayList(u8){
        ArrayList(u8).init(allocator),
        ArrayList(u8).init(allocator),
    };
    errdefer {
        text[0].deinit();
        text[1].deinit();
    }
    for (diffs.items) |edit| {
        if (edit.operation != .insert) try text[0].appendSlice(edit.text);
        if (edit.operation != .delete) try text[1].appendSlice(edit.text);
    }
    const before = try text[0].toOwnedSlice();
    errdefer allocator.free(before);
    return .{ before, try text[1].toOwnedSlice() };
}

fn testDiffFnRebuildTexts(allocator: Allocator, diffs: DiffList, params: TRebuild) !void {
    const texts = try rebuildtexts(allocator, diffs);
    defer {
        allocator.free(texts[0]);
        allocator.free(texts[1]);
    }
    try testing.expectEqualStrings(params.before, texts[0]);
    try testing.expectEqualStrings(params.after, texts[1]);
}

test "DiffFn lifecycle" {
    const allocator = testing.allocator;

    {
        var diff_obj: DefaultDiff = .default;
        defer diff_obj.deinit(allocator);
        try testing.expectEqualDeep(DiffConfig.default, diff_obj.config);
        try testing.expectEqual(@as(usize, 0), diff_obj.edits.items.len);
    }

    {
        const options: DiffConfig = .{
            .timeout = 0,
            .edit_cost = 9,
            .check_lines = false,
            .check_line_threshold = 33,
        };
        var diff_obj = DefaultDiff.init(options);
        defer diff_obj.deinit(allocator);
        try testing.expectEqualDeep(options, diff_obj.config);
    }

    {
        var options: DiffConfig = .default;
        options.timeout = 0;
        var diff_obj = DefaultDiff.init(options);
        defer diff_obj.deinit(allocator);
        _ = try diff_obj.diff(allocator, "cat", "coat");
        var cloned = try diff_obj.clone(allocator);
        defer cloned.deinit(allocator);
        try testing.expectEqualDeep(diff_obj.config, cloned.config);
        try expectEqualDiff(diff_obj.edits.items, cloned.edits.items);
    }

    {
        var options: DiffConfig = .default;
        options.timeout = 0;
        var diff_obj = DefaultDiff.init(options);
        defer diff_obj.deinit(allocator);
        _ = try diff_obj.diff(allocator, "abc", "axc");
        var copied = try diff_obj.copy(allocator);
        defer copied.deinit(allocator);
        try testing.expectEqualDeep(diff_obj.config, copied.config);
        try expectEqualDiff(diff_obj.edits.items, copied.edits.items);
    }

    {
        var diff_obj: DefaultDiff = .default;
        defer diff_obj.deinit(allocator);
        try diff_obj.edits.append(allocator, Edit.asBorrow(.delete, "abc"));
        _ = try diff_obj.own(allocator);
        try testing.expect(diff_obj.edits.items[0].owned);
    }

    {
        var options: DiffConfig = .default;
        options.timeout = 0;
        var diff_obj = DefaultDiff.init(options);
        _ = try diff_obj.diff(allocator, "abc", "axc");
        try testing.expect(diff_obj.edits.items.len != 0);
        diff_obj.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), diff_obj.edits.items.len);
    }

    {
        var options: DiffConfig = .default;
        options.timeout = 0;
        var diff_obj = DefaultDiff.init(options);
        defer diff_obj.deinit(allocator);
        _ = try diff_obj.diff(allocator, "abc", "axc");
        const first_len = diff_obj.edits.items.len;
        _ = try diff_obj.diff(allocator, "abc", "abc");
        try testing.expect(first_len != diff_obj.edits.items.len);
        try expectEqualDiff(&.{Edit.asBorrow(.equal, "abc")}, diff_obj.edits.items);
        try testing.expectEqual(@as(isize, 0), diff_obj.changeInBytes());
    }
}

test "DiffFn diffCommonPrefix" {
    try testing.expectEqual(@as(usize, 0), diffCommonPrefix("abc", "xyz"));
    try testing.expectEqual(@as(usize, 4), diffCommonPrefix("1234abcdef", "1234xyz"));
    try testing.expectEqual(@as(usize, 4), diffCommonPrefix("1234", "1234xyz"));
}

test "DiffFn diffCommonSuffix" {
    try testing.expectEqual(@as(usize, 0), diffCommonSuffix("abc", "xyz"));
    try testing.expectEqual(@as(usize, 4), diffCommonSuffix("abcdef1234", "xyz1234"));
    try testing.expectEqual(@as(usize, 4), diffCommonSuffix("1234", "xyz1234"));
}

test "DiffFn diffCommonOverlap" {
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("", "abcd"));
    try testing.expectEqual(@as(usize, 3), diffCommonOverlap("abc", "abcd"));
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("123456", "abcd"));
    try testing.expectEqual(@as(usize, 3), diffCommonOverlap("123456xxx", "xxxabcd"));
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("fi", "\u{fb01}"));
}

test "DiffFn diffHalfMatch leak regression test" {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatchLeak, .{});
}

test "DiffFn diffHalfMatch" {
    const one_timeout: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 1;
        break :blk config;
    };

    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "1234567890", .after = "abcdef", .expected = null }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "12345", .after = "23", .expected = null }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "1234567890", .after = "a345678z", .expected = .{ .prefix_before = "12", .suffix_before = "90", .prefix_after = "a", .suffix_after = "z", .common_middle = "345678" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "a345678z", .after = "1234567890", .expected = .{ .prefix_before = "a", .suffix_before = "z", .prefix_after = "12", .suffix_after = "90", .common_middle = "345678" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "abc56789z", .after = "1234567890", .expected = .{ .prefix_before = "abc", .suffix_before = "z", .prefix_after = "1234", .suffix_after = "0", .common_middle = "56789" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "a23456xyz", .after = "1234567890", .expected = .{ .prefix_before = "a", .suffix_before = "xyz", .prefix_after = "1", .suffix_after = "7890", .common_middle = "23456" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "121231234123451234123121", .after = "a1234123451234z", .expected = .{ .prefix_before = "12123", .suffix_before = "123121", .prefix_after = "a", .suffix_after = "z", .common_middle = "1234123451234" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "x-=-=-=-=-=-=-=-=-=-=-=-=", .after = "xx-=-=-=-=-=-=-=", .expected = .{ .prefix_before = "", .suffix_before = "-=-=-=-=-=", .prefix_after = "x", .suffix_after = "", .common_middle = "x-=-=-=-=-=-=-=" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "-=-=-=-=-=-=-=-=-=-=-=-=y", .after = "-=-=-=-=-=-=-=yy", .expected = .{ .prefix_before = "-=-=-=-=-=", .suffix_before = "", .prefix_after = "", .suffix_after = "y", .common_middle = "-=-=-=-=-=-=-=y" } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{ .config = one_timeout, .before = "qHilloHelloHew", .after = "xHelloHeHulloy", .expected = .{ .prefix_before = "qHillo", .suffix_before = "w", .prefix_after = "x", .suffix_after = "Hulloy", .common_middle = "HelloHe" } }});
    try testDiffFnHalfMatch(testing.allocator, .{
        .config = one_timeout,
        .before = "\u{92b}\u{917}\u{914}\u{93b}\u{940}\u{907}",
        .after = "\u{92b}\u{997}\u{914}\u{93b}\u{940}\u{97d}",
        .expected = .{
            .prefix_before = "\u{92b}\u{917}",
            .suffix_before = "\u{907}",
            .prefix_after = "\u{92b}\u{997}",
            .suffix_after = "\u{97d}",
            .common_middle = "\u{914}\u{93b}\u{940}",
        },
    });
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnHalfMatch, .{TestHalfMatch{
        .config = blk: {
            var cfg: DiffConfig = .default;
            cfg.timeout = 0;
            break :blk cfg;
        },
        .before = "qHilloHelloHew",
        .after = "xHelloHeHulloy",
        .expected = null,
    }});
}

test "DiffFn diffLinesToChars" {
    const allocator = testing.allocator;
    var tmp_array_list = ArrayList([]const u8).init(allocator);
    defer tmp_array_list.deinit();
    try tmp_array_list.append("alpha\n");
    try tmp_array_list.append("beta\n");

    var difference: DefaultDiff = .default;
    var result = try difference.diffLinesToChars(allocator, "alpha\nbeta\nalpha\n", "beta\nalpha\nbeta\n");
    try testing.expectEqualStrings(" ! ", result.chars_1);
    try testing.expectEqualStrings("! !", result.chars_2);
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items);
    result.deinit(allocator);

    tmp_array_list.items.len = 0;
    try tmp_array_list.append("alpha\r\n");
    try tmp_array_list.append("beta\r\n");
    try tmp_array_list.append("\r\n");
    result = try difference.diffLinesToChars(allocator, "", "alpha\r\nbeta\r\n\r\n\r\n");
    try testing.expectEqualStrings("", result.chars_1);
    try testing.expectEqualStrings(" !\"\"", result.chars_2);
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items);
    result.deinit(allocator);

    tmp_array_list.items.len = 0;
    try tmp_array_list.append("a");
    try tmp_array_list.append("b");
    result = try difference.diffLinesToChars(allocator, "a", "b");
    try testing.expectEqualStrings(" ", result.chars_1);
    try testing.expectEqualStrings("!", result.chars_2);
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items);
    result.deinit(allocator);
}

test "DiffFn diffCharsToLines" {
    var diff_list: DiffList = .empty;
    defer deinitDiffList(testing.allocator, &diff_list);
    try diff_list.ensureTotalCapacity(testing.allocator, 2);
    diff_list.appendSliceAssumeCapacity(&.{
        .{ .operation = .equal, .owned = true, .text = try testing.allocator.dupe(u8, " ! ") },
        .{ .operation = .insert, .owned = true, .text = try testing.allocator.dupe(u8, "! !") },
    });
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCharsToLines, .{TCharLines{
        .before = "alpha\nbeta\nalpha\n",
        .after = "alpha\nbeta\nalpha\nbeta\nalpha\nbeta\n",
        .diffs = diff_list.items,
        .line_array = &[_][]const u8{ "alpha\n", "beta\n" },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "alpha\nbeta\nalpha\n" },
            .{ .operation = .insert, .owned = false, .text = "beta\nalpha\nbeta\n" },
        },
    }});
}

test "DiffFn diffCleanupMerge" {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupMerge, .{TestIO{ .input = &.{ .{ .operation = .equal, .owned = false, .text = "a" }, .{ .operation = .delete, .owned = false, .text = "b" }, .{ .operation = .insert, .owned = false, .text = "c" } }, .expected = &.{ .{ .operation = .equal, .owned = false, .text = "a" }, .{ .operation = .delete, .owned = false, .text = "b" }, .{ .operation = .insert, .owned = false, .text = "c" } } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupMerge, .{TestIO{ .input = &.{ .{ .operation = .equal, .owned = false, .text = "a" }, .{ .operation = .equal, .owned = false, .text = "b" }, .{ .operation = .equal, .owned = false, .text = "c" } }, .expected = &.{.{ .operation = .equal, .owned = false, .text = "abc" }} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupMerge, .{TestIO{ .input = &.{ .{ .operation = .delete, .owned = false, .text = "a" }, .{ .operation = .delete, .owned = false, .text = "b" }, .{ .operation = .delete, .owned = false, .text = "c" } }, .expected = &.{.{ .operation = .delete, .owned = false, .text = "abc" }} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupMerge, .{TestIO{ .input = &.{ .{ .operation = .insert, .owned = false, .text = "a" }, .{ .operation = .insert, .owned = false, .text = "b" }, .{ .operation = .insert, .owned = false, .text = "c" } }, .expected = &.{.{ .operation = .insert, .owned = false, .text = "abc" }} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupMerge, .{TestIO{ .input = &.{ .{ .operation = .delete, .owned = false, .text = "a" }, .{ .operation = .insert, .owned = false, .text = "abc" }, .{ .operation = .delete, .owned = false, .text = "dc" } }, .expected = &.{ .{ .operation = .equal, .owned = false, .text = "a" }, .{ .operation = .delete, .owned = false, .text = "d" }, .{ .operation = .insert, .owned = false, .text = "b" }, .{ .operation = .equal, .owned = false, .text = "c" } } }});

    {
        const text = "abcdef";
        try testDiffFnCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = text[0..1] },
                .{ .operation = .equal, .owned = false, .text = text[1..3] },
                .{ .operation = .equal, .owned = false, .text = text[3..] },
            },
            .expected = &.{.{ .operation = .equal, .owned = false, .text = "abcdef" }},
        });
    }
}

test "DiffFn diffCleanupSemanticLossless" {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupSemanticLossless, .{TestIO{ .input = &[_]Edit{}, .expected = &[_]Edit{} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupSemanticLossless, .{TestIO{ .input = &.{ .{ .operation = .equal, .owned = false, .text = "The c" }, .{ .operation = .insert, .owned = false, .text = "ow and the c" }, .{ .operation = .equal, .owned = false, .text = "at." } }, .expected = &.{ .{ .operation = .equal, .owned = false, .text = "The " }, .{ .operation = .insert, .owned = false, .text = "cow and the " }, .{ .operation = .equal, .owned = false, .text = "cat." } } }});

    {
        const after = "The cow and the cat.";
        try testDiffFnCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = after[0..5] },
                .{ .operation = .insert, .owned = false, .text = after[5..17] },
                .{ .operation = .equal, .owned = false, .text = after[17..] },
            },
            "The cat.",
            after,
        );
    }
}

test "DiffFn rebuildtexts" {
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .insert, .owned = false, .text = "abcabc" },
            .{ .operation = .equal, .owned = false, .text = "defdef" },
            .{ .operation = .delete, .owned = false, .text = "ghighi" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testDiffFnRebuildTexts, .{ diffs, TRebuild{ .before = "defdefghighi", .after = "abcabcdefdef" } });
    }
}

test "DiffFn diffBisect" {
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 0;
        break :blk config;
    };
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnBisect, .{TBisect{
        .config = config,
        .before = "cat",
        .after = "map",
        .deadline = std.math.maxInt(i64),
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "c" },
            .{ .operation = .insert, .owned = false, .text = "m" },
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "t" },
            .{ .operation = .insert, .owned = false, .text = "p" },
        },
    }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnBisect, .{TBisect{
        .config = config,
        .before = "cat",
        .after = "map",
        .deadline = 0,
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "cat" },
            .{ .operation = .insert, .owned = false, .text = "map" },
        },
    }});
}

test "DiffFn diffBisectSplit edge coverage" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        break :blk cfg;
    };
    {
        var difference = DefaultDiff.init(config);
        var diffs = try difference.diffBisectSplit(allocator, "cat", "map", 0, 0, std.math.maxInt(i64));
        defer deinitDiffList(allocator, &diffs);
        try expectEqualDiff(&.{ Edit.asBorrow(.delete, "cat"), Edit.asBorrow(.insert, "map") }, diffs.items);
    }
    {
        var difference = DefaultDiff.init(config);
        var diffs = try difference.diffBisectSplit(allocator, "cat", "map", 3, 3, std.math.maxInt(i64));
        defer deinitDiffList(allocator, &diffs);
        try expectEqualDiff(&.{ Edit.asBorrow(.delete, ""), Edit.asBorrow(.insert, "map") }, diffs.items);
    }
    try testing.checkAllAllocationFailures(allocator, testDiffFnCloneDiffList, .{&.{ Edit.asBorrow(.equal, "alpha"), Edit.asBorrow(.delete, "beta"), Edit.asBorrow(.insert, "gamma") }});
    try testing.checkAllAllocationFailures(allocator, testDiffFnSliceToDiffList, .{&.{ Edit.asBorrow(.equal, "alpha"), Edit.asBorrow(.delete, "beta"), Edit.asBorrow(.insert, "gamma") }});
    try testing.checkAllAllocationFailures(allocator, testDiffFnBisectSplitCase, .{ config, "cat", "map", 0, 0 });
    try testing.checkAllAllocationFailures(allocator, testDiffFnBisectSplitCase, .{ config, "cat", "map", 3, 3 });
    try testing.expectEqual(@as(u8, 0), boolInt(false));
    try testing.expectEqual(@as(u8, 1), boolInt(true));
}

test "DiffFn diff" {
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 0;
        config.check_lines = false;
        break :blk config;
    };
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFn, .{TDiff{ .config = config, .before = "", .after = "", .expected = &[_]Edit{} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFn, .{TDiff{ .config = config, .before = "abc", .after = "abc", .expected = &.{.{ .operation = .equal, .owned = false, .text = "abc" }} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFn, .{TDiff{ .config = config, .before = "abc", .after = "ab123c", .expected = &.{ .{ .operation = .equal, .owned = false, .text = "ab" }, .{ .operation = .insert, .owned = false, .text = "123" }, .{ .operation = .equal, .owned = false, .text = "c" } } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFn, .{TDiff{ .config = config, .before = "a123bc", .after = "abc", .expected = &.{ .{ .operation = .equal, .owned = false, .text = "a" }, .{ .operation = .delete, .owned = false, .text = "123" }, .{ .operation = .equal, .owned = false, .text = "bc" } } }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFn, .{TDiff{ .config = config, .before = "a", .after = "b", .expected = &.{ .{ .operation = .delete, .owned = false, .text = "a" }, .{ .operation = .insert, .owned = false, .text = "b" } } }});
}

test "DiffFn diffLineMode" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffFnLineMode,
        .{
            @as(u32, 20),
            "1234567890\n1234567890\n1234567890",
            "abcdefghij\nabcdefghij\nabcdefghij",
        },
    );
}

test "DiffFn check-line-mode" {
    try testDiffFnLineMode(
        testing.allocator,
        20,
        "alpha-1\nalpha-2\nshared-a\nbeta-1\nbeta-2\nshared-b\ngamma-1\ngamma-2\nshared-c\n",
        "omega-1\nomega-2\nshared-a\ntheta-1\ntheta-2\nshared-b\nsigma-1\nsigma-2\nshared-c\n",
    );
    try testDiffFnLineMode(
        testing.allocator,
        20,
        "red-1\nred-2\npivot-a\nblue-1\nblue-2\npivot-b\ngreen-1\ngreen-2\npivot-c\n",
        "cyan-1\ncyan-2\npivot-a\nyellow-1\nyellow-2\npivot-b\nmagenta-1\nmagenta-2\npivot-c\n",
    );
}

test "DiffFn Unicode diffs" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        cfg.check_lines = false;
        break :blk cfg;
    };
    {
        var greek_diff = try diffFnListFromConfig(allocator, config, "αβγ", "αβδ");
        defer deinitDiffList(allocator, &greek_diff);
        try expectEqualDiff(&.{
            Edit.asBorrow(.equal, "αβ"),
            Edit.asBorrow(.delete, "γ"),
            Edit.asBorrow(.insert, "δ"),
        }, greek_diff.items);
    }
    try testing.checkAllAllocationFailures(
        allocator,
        diffFnRoundTrip,
        .{ config, &[_]Edit{
            .{ .operation = .equal, .owned = false, .text = "😹💋" },
            .{ .operation = .delete, .owned = false, .text = "\xf0\x9f\xa5\xb9" },
            .{ .operation = .insert, .owned = false, .text = "\xf0\x9f\xa5\xb4" },
            .{ .operation = .equal, .owned = false, .text = "👀🫵" },
        } },
    );
}

test "DiffFn diffCleanupSemantic" {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupSemantic, .{TestIO{ .input = &[_]Edit{}, .expected = &[_]Edit{} }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupSemantic, .{TestIO{
        .input = &[_]Edit{
            Edit.asBorrow(.delete, "abcxxx"),
            Edit.asBorrow(.insert, "xxxdef"),
        },
        .expected = &[_]Edit{
            Edit.asBorrow(.delete, "abc"),
            Edit.asBorrow(.equal, "xxx"),
            Edit.asBorrow(.insert, "def"),
        },
    }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffFnCleanupSemantic, .{TestIO{
        .input = &[_]Edit{
            Edit.asBorrow(.delete, "xxxabc"),
            Edit.asBorrow(.insert, "defxxx"),
        },
        .expected = &[_]Edit{
            Edit.asBorrow(.insert, "def"),
            Edit.asBorrow(.equal, "xxx"),
            Edit.asBorrow(.delete, "abc"),
        },
    }});
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffFnCleanupSemanticRoundTrip,
        .{
            &[_]Edit{
                Edit.asBorrow(.delete, "ab"),
                Edit.asBorrow(.insert, "12"),
                Edit.asBorrow(.equal, "x"),
                Edit.asBorrow(.delete, "cd"),
                Edit.asBorrow(.insert, "34"),
                Edit.asBorrow(.equal, "y"),
                Edit.asBorrow(.delete, "ef"),
                Edit.asBorrow(.insert, "56"),
            },
            "abxcdyef",
            "12x34y56",
        },
    );
}

test "DiffFn diffCleanupEfficiency" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.edit_cost = 4;
        break :blk cfg;
    };
    var diffs: DiffList = .empty;
    var difference = DefaultDiff.init(config);
    try difference.cleanupEfficiencyImpl(allocator, &diffs);
    try testing.expectEqualDeep(DiffList.empty, diffs);
    try testing.checkAllAllocationFailures(
        allocator,
        testDiffFnCleanupEfficiency,
        .{
            config,
            TestIO{
                .input = &[_]Edit{
                    Edit.asBorrow(.delete, "ab"),
                    Edit.asBorrow(.insert, "12"),
                    Edit.asBorrow(.equal, "xyz"),
                    Edit.asBorrow(.delete, "cd"),
                    Edit.asBorrow(.insert, "34"),
                },
                .expected = &[_]Edit{
                    Edit.asBorrow(.delete, "abxyzcd"),
                    Edit.asBorrow(.insert, "12xyz34"),
                },
            },
        },
    );
}

test "DiffFn before and after text" {
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.check_lines = false;
        break :blk cfg;
    };
    const allocator = testing.allocator;
    const before = "The cat in the hat.";
    const after = "The bat in the belfry.";
    var difference = DefaultDiff.init(config);
    defer difference.deinit(allocator);
    _ = try difference.diff(allocator, before, after);
    const before1 = try difference.beforeText(allocator);
    defer allocator.free(before1);
    const after1 = try difference.afterText(allocator);
    defer allocator.free(after1);
    try testing.expectEqualStrings(before, before1);
    try testing.expectEqualStrings(after, after1);
}

test "DiffFn diffLineMode coverage runs" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        break :blk cfg;
    };
    var difference = DefaultDiff.init(config);
    var diffs = try difference.diffLineMode(
        allocator,
        "alpha\nbeta\ngamma\ndelta\n",
        "alpha\nBETA\nGAMMA\ndelta\n",
        std.math.maxInt(i64),
    );
    defer deinitDiffList(allocator, &diffs);
    const before = try diffBeforeText(allocator, diffs);
    defer allocator.free(before);
    const after = try diffAfterText(allocator, diffs);
    defer allocator.free(after);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\ndelta\n", before);
    try testing.expectEqualStrings("alpha\nBETA\nGAMMA\ndelta\n", after);
}

test "DiffFn diffIndex" {
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.check_lines = false;
        break :blk cfg;
    };
    var diffs = try diffFnListFromConfig(testing.allocator, config, "The midnight train", "The blue midnight train");
    defer deinitDiffList(testing.allocator, &diffs);
    try testing.expectEqual(0, diffIndex(diffs, 0));
    try testing.expectEqual(9, diffIndex(diffs, 4));

    var difference = DefaultDiff.init(config);
    defer difference.deinit(testing.allocator);
    _ = try difference.diff(testing.allocator, "The midnight train", "The blue midnight train");
    try testing.expectEqual(@as(usize, 9), difference.index(4));
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const testing = std.testing;

pub const DiffConfig = diff_mod.DiffConfig;
pub const Edit = diff_mod.Edit;
pub const DiffList = diff_mod.DiffList;

const common = @import("dmp/common.zig");
const diff_mod = @import("dmp/diff.zig");

const OOM = Allocator.Error;
const deinitDiffList = common.deinitDiffList;
const diffRunAllBorrowed = common.diffRunAllBorrowed;
const diffBorrowedRunSpan = common.diffBorrowedRunSpan;
const diffMaterializeRun = common.diffMaterializeRun;
const diffMakeOwnedConcat2 = common.diffMakeOwnedConcat2;
const cloneDiffList = common.cloneDiffList;
const copyDiffList = common.copyDiffList;
const hasSharedPrefixLen = common.hasSharedPrefixLen;
const defaultSemanticScore = common.diffCleanupSemanticScore;
const diffIndex = common.diffIndex;
const diffBeforeText = common.diffBeforeText;
const diffAfterText = common.diffAfterText;
const freeRangeDiffList = common.freeRangeDiffList;
const diffCommonPrefix = common.diffCommonPrefix;
const diffCommonSuffix = common.diffCommonSuffix;
const diffCommonOverlap = common.diffCommonOverlap;
const boolInt = common.boolInt;
const fixSplitForward = common.fixSplitForward;
const fixSplitBackward = common.fixSplitBackward;
const cast = common.cast;
const u2i = common.u2i;
const i2u = common.i2u;
const dbgassert = common.dbgassert;
