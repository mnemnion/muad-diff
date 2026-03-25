//! Diff represents the difference between two texts.
//!
//! A `Diff` owns a `DiffList` of `Edit` values and provides the diff-specific
//! operations over that list, including diff generation, cleanup passes, and
//! readback helpers such as pretty formatting and text reconstruction.
//!
//! `Diff` is unmanaged.  Use `.default` for the default configuration or
//! `initOptions()` to provide a custom `DiffConfig`, and later release any
//! owned storage with `deinit(allocator)`.
//!
//! `DiffConfig` controls how the diff is produced:
//! - `timeout` is the maximum number of milliseconds to spend computing a diff;
//!   `0` means no timeout.
//! - `edit_cost` tunes the efficiency cleanup heuristics.
//! - `check_lines` enables the initial line-mode speedup for large inputs.
//! - `check_line_threshold` sets the minimum input size for that speedup.
//!
//! The usual flow is to initialize a `Diff`, call `diff()`, and then optionally
//! chain cleanup methods on the result.  The diff object can be reused to diff
//! two more texts, in which case, the original diff's memory will be released.

/// The diff configuration, see `DiffConfig`
config: DiffConfig = .default,
/// An ArrayList of the individual `Edit`s in this diff.
edits: DiffList = .empty,

/// A single edit of a diff: insertion, deletion, or neither.
pub const Edit = struct {
    pub const Operation = enum {
        insert,
        delete,
        equal,
    };

    // TODO: The algorithm as a whole requires some text to be copied,
    // at least it does without some very heavyweight reimagination.
    // But not all.  Since this is aligned with a slice, it's three
    // usize, and our enum is tiny, so we can add a boolean recording
    // copy status 'for free' and use views for the great majority of
    // text.

    operation: Operation,
    owned: bool,
    text: []const u8,

    pub fn format(value: Edit, writer: anytype) !void {
        try writer.print("({s}, \"{s}\")", .{
            switch (value.operation) {
                .equal => "=",
                .insert => "+",
                .delete => "-",
            },
            value.text,
        });
    }

    pub fn deinit(edit: *Edit, allocator: Allocator) void {
        if (edit.owned) allocator.free(edit.text);
    }

    /// Create an Edit which owns its text.
    pub fn asOwn(allocator: Allocator, operation: Operation, text: []const u8) OOM!Edit {
        return .{
            .operation = operation,
            .owned = true,
            .text = try allocator.dupe(u8, text),
        };
    }

    /// Create an Edit which borrows its text.
    pub fn asBorrow(operation: Operation, text: []const u8) Edit {
        return .{
            .operation = operation,
            .owned = false,
            .text = text,
        };
    }

    /// Turn a borrowed Edit into an owned Edit.  If the Edit is
    /// already owned, this has no effect.
    pub fn own(edit: *Edit, allocator: Allocator) OOM!void {
        if (!edit.owned) {
            edit.* = try edit.clone(allocator);
        }
    }

    pub fn eql(a: Edit, b: Edit) bool {
        return a.operation == b.operation and std.mem.eql(u8, a.text, b.text);
    }

    pub fn clone(edit: Edit, allocator: Allocator) !Edit {
        return Edit{
            .operation = edit.operation,
            .owned = true,
            // ANN: dupe
            // Clone must own an independent copy of the edit text.
            .text = try allocator.dupe(u8, edit.text),
        };
    }
};

pub const DiffList = ArrayListUnmanaged(Edit);

pub const DiffConfig = struct {
    /// Number of milliseconds to map a diff before giving up (0 for infinity).
    timeout: u64,
    /// Cost of an empty edit operation in terms of edit characters.
    edit_cost: u16,
    /// If true, use the initial line-mode speedup when inputs are large enough.
    check_lines: bool,
    /// Number of bytes in each string needed to trigger a line-based diff.
    /// Ignored if check_lines is `false`.
    check_line_threshold: u32,

    pub const default: DiffConfig = .{
        .timeout = 1000,
        .edit_cost = 4,
        .check_lines = true,
        .check_line_threshold = 100,
    };
};

pub const HalfMatchResult = struct {
    prefix_before: []const u8,
    suffix_before: []const u8,
    prefix_after: []const u8,
    suffix_after: []const u8,
    common_middle: []const u8,

    // Free the HalfMatchResult's memory.
    pub fn deinit(hmr: HalfMatchResult, allocator: Allocator) void {
        _ = .{ hmr, allocator }; // no-op,      XXX: remove
        // allocator.free(hmr.prefix_before);
        // allocator.free(hmr.suffix_before);
        // allocator.free(hmr.prefix_after);
        // allocator.free(hmr.suffix_after);
        // allocator.free(hmr.common_middle);
    }
};

pub const CHAR_OFFSET = 32;

/// A struct holding bookends for `diffPrittyFormat(diffs)`.
///
/// May include a function taking an allocator and the Diff,
/// which shall return the text of the Diff, appropriately munged.
/// This allows for tasks like proper HTML escaping.  Note that if
/// the function is provided, all text returned will be freed, so
/// it should always return a copy whether or not edits are needed.
pub const DiffDecorations = struct {
    delete_start: []const u8 = "",
    delete_end: []const u8 = "",
    insert_start: []const u8 = "",
    insert_end: []const u8 = "",
    equals_start: []const u8 = "",
    equals_end: []const u8 = "",
    pre_process: ?fn (Allocator, Edit) OOM![]const u8 = null,

    /// Decorations for classic Xterm printing: red for delete and
    /// green for insert.
    pub const xterm_classic: DiffDecorations = .{
        .delete_start = "\x1b[91m",
        .delete_end = "\x1b[m",
        .insert_start = "\x1b[92m",
        .insert_end = "\x1b[m",
    };
};

pub const default: Diff = .{
    .config = .default,
    .edits = .empty,
};

/// Initialize an empty `Diff` with the provided `DiffConfig`.
pub fn init(config: DiffConfig) Diff {
    return .{ .config = config };
}

/// Clone this `Diff`, including its owned edits.
pub fn clone(difference: Diff, allocator: Allocator) !Diff {
    return .{
        .config = difference.config,
        .edits = try cloneDiffList(allocator, difference.edits),
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
/// @return self.
pub fn diff(
    difference: *Diff,
    allocator: Allocator,
    before: []const u8,
    after: []const u8,
) OOM!*Diff {
    if (difference.edits.items.len != 0) {
        deinitDiffList(allocator, &difference.edits);
        difference.edits = .empty;
    }
    difference.edits = try diffWithConfig(difference.config, allocator, before, after);
    return difference;
}

/// Reduce the number of edits by eliminating semantically trivial
/// equalities.
/// @return self.
pub fn cleanupSemantic(difference: *Diff, allocator: Allocator) OOM!*Diff {
    try diffCleanupSemantic(allocator, &difference.edits);
    return difference;
}

/// Look for single edits surrounded on both sides by equalities
/// which can be shifted sideways to align the edit to a word boundary.
/// e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
/// @return self.
pub fn cleanupSemanticLossless(difference: *Diff, allocator: Allocator) OOM!*Diff {
    try diffCleanupSemanticLossless(allocator, &difference.edits);
    return difference;
}

/// Reduce the number of edits by eliminating operationally trivial
/// equalities.
/// @return self.
pub fn cleanupEfficiency(difference: *Diff, allocator: Allocator) OOM!*Diff {
    try diffCleanupEfficiencyConfig(difference.config, allocator, &difference.edits);
    return difference;
}

/// Return text representing a pretty-formatted `Diff`.
/// See `DiffDecorations` for how to customize this output.
pub fn prettyFormat(difference: *const Diff, allocator: Allocator, deco: DiffDecorations) ![]const u8 {
    return try diffPrettyFormat(allocator, difference.edits, deco);
}

/// Return text representing a pretty-formatted `DiffList`, in Xterm format.
pub fn prettyFormatXTerm(difference: *const Diff, allocator: Allocator) ![]const u8 {
    return diffPrettyFormatXTerm(allocator, difference);
}

/// Write a pretty-formatted `Diff` to `writer`.  The `Allocator`
/// is only used if a custom text formatter is defined for
/// `DiffDecorations`.  Returns number of bytes written.
pub fn writePrettyFormat(
    difference: *const Diff,
    allocator: Allocator,
    writer: anytype,
    deco: DiffDecorations,
) !usize {
    return try writeDiffPrettyFormat(allocator, writer, difference.edits, deco);
}

///
/// Compute and return the source text (all equalities and deletions).
/// @return Source text.
///
pub fn beforeText(difference: Diff, allocator: Allocator) OOM![]const u8 {
    return try diffBeforeText(allocator, difference.edits);
}

///
/// Compute and return the destination text (all equalities and insertions).
/// @return Destination text.
///
pub fn afterText(difference: Diff, allocator: Allocator) OOM![]const u8 {
    return try diffAfterText(allocator, difference.edits);
}

/// loc is a location in text1, compute and return the equivalent location in
/// text2.
/// e.g. "The cat" vs "The big cat", 1->1, 5->8
/// @param loc Location within text1.
/// @return Location within text2.
///
pub fn index(difference: Diff, loc: usize) usize {
    return diffIndex(difference.edits, loc);
}

//| Private

/// Free all memory of the ArrayList of Edits in a Diff.
const deinitDiffList = common.deinitDiffList;

/// Clone a `DiffList`, including each edit's owned text.
fn cloneDiffList(allocator: Allocator, diffs: DiffList) !DiffList {
    var new_diffs: DiffList = .empty;
    try new_diffs.ensureTotalCapacity(allocator, diffs.items.len);
    errdefer deinitDiffList(allocator, &new_diffs);
    for (diffs.items) |d| {
        new_diffs.appendAssumeCapacity(try d.clone(allocator));
    }
    return new_diffs;
}

/// Test helper.
fn diffListFromConfig(
    allocator: Allocator,
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
) !DiffList {
    var diff_obj = Diff.init(config);
    defer diff_obj.deinit(allocator);
    _ = try diff_obj.diff(allocator, before, after);
    const diffs = diff_obj.edits;
    diff_obj.edits = .empty;
    return diffs;
}

/// Compute a `DiffList` using the provided `DiffConfig`.
fn diffWithConfig(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
) OOM!DiffList {
    const deadline = if (config.timeout == 0)
        std.math.maxInt(u64)
    else
        @as(u64, @intCast(std.time.milliTimestamp())) + config.timeout;
    return diffInternal(config, allocator, before, after, deadline);
}

/// Internal diff entrypoint which carries the computed deadline through the
/// recursive diff pipeline.
fn diffInternal(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    deadline: u64,
) OOM!DiffList {
    // Check for equality (speedup).
    if (std.mem.eql(u8, before, after)) {
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        if (before.len != 0) {
            try diffs.ensureUnusedCapacity(allocator, 1);
            diffs.appendAssumeCapacity(Edit.asBorrow(
                .equal,
                before,
            ));
        }
        return diffs;
    }

    // Trim off common prefix (speedup).
    var common_length = diffCommonPrefix(before, after);
    const common_prefix = before[0..common_length];
    var trimmed_before = before[common_length..];
    var trimmed_after = after[common_length..];

    // Trim off common suffix (speedup).
    common_length = diffCommonSuffix(trimmed_before, trimmed_after);
    const common_suffix = trimmed_before[trimmed_before.len - common_length ..];
    trimmed_before = trimmed_before[0 .. trimmed_before.len - common_length];
    trimmed_after = trimmed_after[0 .. trimmed_after.len - common_length];

    // Compute the diff on the middle block.
    var diffs = try diffCompute(config, allocator, trimmed_before, trimmed_after, deadline);
    errdefer deinitDiffList(allocator, &diffs);

    // Restore the prefix and suffix.
    if (common_prefix.len != 0) {
        try diffs.ensureUnusedCapacity(allocator, 1);
        // ANN: borrow
        diffs.insertAssumeCapacity(0, Edit.asBorrow(
            .equal,
            common_prefix,
        ));
    }
    if (common_suffix.len != 0) {
        try diffs.ensureUnusedCapacity(allocator, 1);
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .equal,
            common_suffix,
        ));
    }
    try diffCleanupMerge(allocator, &diffs);
    return diffs;
}

/// Find a common prefix which respects UTF-8 code point boundaries.
fn diffCommonPrefix(before: []const u8, after: []const u8) usize {
    const n = @min(before.len, after.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = before[i];
        const a = after[i];
        if (a != b) {
            return fixSplitBackward(before, i);
        }
    }

    return n;
}

/// Find a common suffix which respects UTF-8 code point boundaries
fn diffCommonSuffix(before: []const u8, after: []const u8) usize {
    const n = @min(before.len, after.len);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const b = before[before.len - i];
        const a = after[after.len - i];
        if (a != b) {
            return before.len - fixSplitForward(before, before.len - i + 1);
        }
    }

    return n;
}

/// Find the differences between two texts.  Assumes that the texts do not
/// have any common prefix or suffix.
/// @param before Old string to be diffed.
/// @param after New string to be diffed.
/// @param checklines Speedup flag.  If false, then don't run a
///     line-level diff first to identify the changed areas.
///     If true, then run a faster slightly less optimal diff.
/// @param deadline Time when the diff should be complete by.
/// @return List of Diff objects.
fn diffCompute(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    deadline: u64,
) OOM!DiffList {
    if (before.len == 0) {
        // Just add some text (speedup).
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 1);
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
            after,
        ));
        return diffs;
    }

    if (after.len == 0) {
        // Just delete some text (speedup).
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 1);
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .delete,
            before,
        ));
        return diffs;
    }

    const long_text = if (before.len > after.len) before else after;
    const short_text = if (before.len > after.len) after else before;

    if (std.mem.indexOf(u8, long_text, short_text)) |match_index| {
        // Shorter text is inside the longer text (speedup).
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        const op: Edit.Operation = if (before.len > after.len)
            .delete
        else
            .insert;
        try diffs.ensureUnusedCapacity(allocator, 3);
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            op,
            long_text[0..match_index],
        ));
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .equal,
            short_text,
        ));
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            op,
            long_text[match_index + short_text.len ..],
        ));
        return diffs;
    }

    if (short_text.len == 1) {
        // Single character string.
        // After the previous speedup, the character can't be an equality.
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 2);
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .delete,
            before,
        ));
        // ANN: borrow
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
            after,
        ));
        return diffs;
    }

    // Check to see if the problem can be split in two.
    var maybe_half_match = try diffHalfMatchConfig(config, allocator, before, after);
    defer if (maybe_half_match) |half_match| half_match.deinit(allocator);
    if (maybe_half_match) |*half_match| {
        // A half-match was found, sort out the return data.
        // Send both pairs off for separate processing.
        var diffs = try diffInternal(
            config,
            allocator,
            half_match.prefix_before,
            half_match.prefix_after,
            deadline,
        );
        errdefer deinitDiffList(allocator, &diffs);
        var diffs_b = try diffInternal(
            config,
            allocator,
            half_match.suffix_before,
            half_match.suffix_after,
            deadline,
        );
        defer diffs_b.deinit(allocator);
        // we have to deinit regardless, so deinitDiffList would be
        // a double free:
        errdefer {
            for (diffs_b.items) |*d| {
                d.deinit(allocator);
            }
        }

        // Merge the results.
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(
            // ANN: borrow
            Edit.asBorrow(.equal, half_match.common_middle),
        );
        half_match.common_middle = "";
        try diffs.appendSlice(allocator, diffs_b.items);
        return diffs;
    }

    if (config.check_lines and before.len > config.check_line_threshold and after.len > config.check_line_threshold) {
        return diffLineMode(config, allocator, before, after, deadline);
    }
    return diffBisectConfig(config, allocator, before, after, deadline);
}

fn diffHalfMatchConfig(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
) OOM!?HalfMatchResult {
    if (config.timeout == 0) {
        // Don't risk returning a non-optimal diff if we have unlimited time.
        return null;
    }
    const long_text = if (before.len > after.len) before else after;
    const short_text = if (before.len > after.len) after else before;

    if (long_text.len < 4 or short_text.len * 2 < long_text.len) {
        return null; // Pointless.
    }

    // First check if the second quarter is the seed for a half-match.
    const half_match_1 = try diffHalfMatchInternal(allocator, long_text, short_text, (long_text.len + 3) / 4);
    errdefer {
        if (half_match_1) |h_m| h_m.deinit(allocator);
    }
    // Check again based on the third quarter.
    const half_match_2 = try diffHalfMatchInternal(allocator, long_text, short_text, (long_text.len + 1) / 2);
    errdefer {
        if (half_match_2) |h_m| h_m.deinit(allocator);
    }

    var half_match: ?HalfMatchResult = null;
    if (half_match_1 == null and half_match_2 == null) {
        return null;
    } else if (half_match_2 == null) {
        half_match = half_match_1.?;
    } else if (half_match_1 == null) {
        half_match = half_match_2.?;
    } else {
        // Both matched. Select the longest.
        half_match = half: {
            if (half_match_1.?.common_middle.len > half_match_2.?.common_middle.len) {
                half_match_2.?.deinit(allocator);
                break :half half_match_1;
            } else {
                half_match_1.?.deinit(allocator);
                break :half half_match_2;
            }
        };
    }

    // A half-match was found, sort out the return data.
    if (before.len > after.len) {
        return half_match.?;
    } else {
        // Transfers ownership of all memory to new, permuted, half_match.
        const half_match_yes = half_match.?;
        return .{
            .prefix_before = half_match_yes.prefix_after,
            .suffix_before = half_match_yes.suffix_after,
            .prefix_after = half_match_yes.prefix_before,
            .suffix_after = half_match_yes.suffix_before,
            .common_middle = half_match_yes.common_middle,
        };
    }
}

/// Does a Substring of shorttext exist within longtext such that the
/// Substring is at least half the length of longtext?
/// @param longtext Longer string.
/// @param shorttext Shorter string.
/// @param i Start index of quarter length Substring within longtext.
/// @return Five element string array, containing the prefix of longtext, the
///     suffix of longtext, the prefix of shorttext, the suffix of shorttext
///     and the common middle.  Or null if there was no match.
fn diffHalfMatchInternal(
    allocator: std.mem.Allocator,
    long_text: []const u8,
    short_text: []const u8,
    i: usize,
) OOM!?HalfMatchResult {
    _ = allocator;
    // Start with a 1/4 length Substring at position i as a seed.
    const seed = long_text[i .. i + long_text.len / 4];
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
        const prefix_length = diffCommonPrefix(long_text[i..], short_text[@as(usize, @intCast(j))..]);
        const suffix_length = diffCommonSuffix(long_text[0..i], short_text[0..@as(usize, @intCast(j))]);
        if (best_common.len < suffix_length + prefix_length) {
            best_common = short_text[i2u(j - u2i(suffix_length)) .. i2u(j) + prefix_length];
            best_long_text_a = long_text[0 .. i - suffix_length];
            best_long_text_b = long_text[i + prefix_length ..];
            best_short_text_a = short_text[0..i2u(j - u2i(suffix_length))];
            best_short_text_b = short_text[i2u(j + u2i(prefix_length))..];
        }
    }
    if (best_common.len * 2 >= long_text.len) {
        return .{
            // ANN: borrow
            .prefix_before = best_long_text_a,
            // ANN: borrow
            .suffix_before = best_long_text_b,
            // ANN: borrow
            .prefix_after = best_short_text_a,
            // ANN: borrow
            .suffix_after = best_short_text_b,
            // ANN: borrow
            .common_middle = best_common,
        };
    } else {
        return null;
    }
}

fn diffBisectConfig(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    deadline: u64,
) OOM!DiffList {
    const before_length: isize = @intCast(before.len);
    const after_length: isize = @intCast(after.len);
    const max_d: isize = @intCast((before.len + after.len + 1) / 2);
    const v_offset = max_d;
    const v_length = 2 * max_d;

    var v1 = try ArrayListUnmanaged(isize).initCapacity(allocator, i2u(v_length));
    defer v1.deinit(allocator);
    v1.items.len = @intCast(v_length);
    var v2 = try ArrayListUnmanaged(isize).initCapacity(allocator, i2u(v_length));
    defer v2.deinit(allocator);
    v2.items.len = @intCast(v_length);

    var x: usize = 0;
    while (x < v_length) : (x += 1) {
        v1.items[x] = -1;
        v2.items[x] = -1;
    }
    v1.items[@intCast(v_offset + 1)] = 0;
    v2.items[@intCast(v_offset + 1)] = 0;
    const delta = before_length - after_length;
    // If the total number of characters is odd, then the front path will
    // collide with the reverse path.
    const front = (@mod(delta, 2) != 0);
    // Offsets for start and end of k loop.
    // Prevents mapping of space beyond the grid.
    var k1start: isize = 0;
    var k1end: isize = 0;
    var k2start: isize = 0;
    var k2end: isize = 0;

    var d: isize = 0;
    while (d < max_d) : (d += 1) {
        // Bail out if deadline is reached.
        if (@as(u64, @intCast(std.time.milliTimestamp())) > deadline) {
            break;
        }

        // Walk the front path one step.
        var k1 = -d + k1start;
        while (k1 <= d - k1end) : (k1 += 2) {
            const k1_offset = v_offset + k1;
            var x1: isize = 0;
            if (k1 == -d or (k1 != d and
                v1.items[@intCast(k1_offset - 1)] < v1.items[@intCast(k1_offset + 1)]))
            {
                x1 = v1.items[@intCast(k1_offset + 1)];
            } else {
                x1 = v1.items[@intCast(k1_offset - 1)] + 1;
            }
            var y1 = x1 - k1;
            while (x1 < before_length and y1 < after_length) {
                if (before[@intCast(x1)] == after[@intCast(y1)]) {
                    x1 += 1;
                    y1 += 1;
                } else {
                    break;
                }
            }
            v1.items[@intCast(k1_offset)] = x1;
            if (x1 > before_length) {
                // Ran off the right of the graph.
                k1end += 2;
            } else if (y1 > after_length) {
                // Ran off the bottom of the graph.
                k1start += 2;
            } else if (front) {
                const k2_offset = v_offset + delta - k1;
                if (k2_offset >= 0 and k2_offset < v_length and v2.items[@intCast(k2_offset)] != -1) {
                    // Mirror x2 onto top-left coordinate system.
                    const x2 = before_length - v2.items[@intCast(k2_offset)];
                    if (x1 >= x2) {
                        // Overlap detected.
                        return diffBisectSplit(config, allocator, before, after, x1, y1, deadline);
                    }
                }
            }
        }

        // Walk the reverse path one step.
        var k2: isize = -d + k2start;
        while (k2 <= d - k2end) : (k2 += 2) {
            const k2_offset = v_offset + k2;
            var x2: isize = 0;
            if (k2 == -d or (k2 != d and
                v2.items[@intCast(k2_offset - 1)] < v2.items[@intCast(k2_offset + 1)]))
            {
                x2 = v2.items[@intCast(k2_offset + 1)];
            } else {
                x2 = v2.items[@intCast(k2_offset - 1)] + 1;
            }
            var y2: isize = x2 - k2;
            while (x2 < before_length and y2 < after_length) {
                if (before[@intCast(before_length - x2 - 1)] == after[@intCast(after_length - y2 - 1)]) {
                    x2 += 1;
                    y2 += 1;
                } else {
                    break;
                }
            }
            v2.items[@intCast(k2_offset)] = x2;
            if (x2 > before_length) {
                // Ran off the left of the graph.
                k2end += 2;
            } else if (y2 > after_length) {
                // Ran off the top of the graph.
                k2start += 2;
            } else if (!front) {
                const k1_offset = v_offset + delta - k2;
                if (k1_offset >= 0 and k1_offset < v_length and v1.items[@intCast(k1_offset)] != -1) {
                    const x1 = v1.items[@intCast(k1_offset)];
                    const y1 = v_offset + x1 - k1_offset;
                    // Mirror x2 onto top-left coordinate system.
                    x2 = before_length - v2.items[@intCast(k2_offset)];
                    if (x1 >= x2) {
                        // Overlap detected.
                        return diffBisectSplit(config, allocator, before, after, x1, y1, deadline);
                    }
                }
            }
        }
    }
    // Diff took too long and hit the deadline or
    // number of diffs equals number of characters, no commonality at all.
    var diffs: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diffs);
    try diffs.ensureUnusedCapacity(allocator, 2);
    diffs.appendAssumeCapacity(Edit.asBorrow(
        .delete,
        // ANN: borrow
        before,
    ));
    diffs.appendAssumeCapacity(Edit.asBorrow(
        .insert,
        // ANN: borrow
        after,
    ));
    return diffs;
}

/// Given the location of the 'middle snake', split the diff in two parts
/// and recurse.
/// @param text1 Old string to be diffed.
/// @param text2 New string to be diffed.
/// @param x Index of split point in text1.
/// @param y Index of split point in text2.
/// @param deadline Time at which to bail if not yet complete.
/// @return LinkedList of Diff objects.
fn diffBisectSplit(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    text1: []const u8,
    text2: []const u8,
    x: isize,
    y: isize,
    deadline: u64,
) OOM!DiffList {
    const text_mode_config = text_mode: {
        var c = config;
        c.check_lines = false;
        break :text_mode c;
    };
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
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .delete,
            // ANN: borrow
            text1b,
        ));
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
            // ANN: borrow
            text2b,
        ));
        return diffs;
    } else if (text1b.len == 0 and text2b.len == 0) {
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 2);
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .delete,
            // ANN: borrow
            text2b,
        ));
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
            // ANN: borrow
            text2a,
        ));
        return diffs;
    }

    // Compute both diffs serially.
    var diffs = try diffInternal(text_mode_config, allocator, text1a, text2a, deadline);
    errdefer deinitDiffList(allocator, &diffs);
    var diffs_b = try diffInternal(text_mode_config, allocator, text1b, text2b, deadline);
    // Free the list, but not the contents:
    defer diffs_b.deinit(allocator);
    errdefer {
        for (diffs_b.items) |*d| {
            d.deinit(allocator);
        }
    }
    try diffs.appendSlice(allocator, diffs_b.items);
    return diffs;
}

/// Do a quick line-level diff on both strings, then rediff the parts for
/// greater accuracy.
/// This speedup can produce non-minimal diffs.
/// @param text1 Old string to be diffed.
/// @param text2 New string to be diffed.
/// @param deadline Time when the diff should be complete by.
/// @return List of Diff objects.
fn diffLineMode(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    text1_in: []const u8,
    text2_in: []const u8,
    deadline: u64,
) OOM!DiffList {
    const text_mode_config = text_mode: {
        var c = config;
        c.check_lines = false;
        break :text_mode c;
    };
    // Scan the text on a line-by-line basis first.
    var a = try diffLinesToChars(allocator, text1_in, text2_in);
    defer a.deinit(allocator);
    const text1 = a.chars_1;
    const text2 = a.chars_2;
    const line_array = a.line_array;
    var diffs: DiffList = diff_munge: {
        var char_diffs: DiffList = try diffInternal(text_mode_config, allocator, text1, text2, deadline);
        defer deinitDiffList(allocator, &char_diffs);
        // Convert the diff back to original text.
        break :diff_munge try diffCharsToLines(allocator, &char_diffs, line_array.items);
    };
    errdefer deinitDiffList(allocator, &diffs);
    // Eliminate freak matches (e.g. blank lines)
    try diffCleanupSemantic(allocator, &diffs);

    // Rediff any replacement blocks, this time character-by-character.
    // Add a dummy entry at the end.
    try diffs.append(allocator, Edit.asBorrow(.equal, ""));

    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;
    var text_delete = ArrayListUnmanaged(u8){};
    var text_insert = ArrayListUnmanaged(u8){};
    defer {
        text_delete.deinit(allocator);
        text_insert.deinit(allocator);
    }

    while (pointer < diffs.items.len) {
        switch (diffs.items[pointer].operation) {
            .insert => {
                count_insert += 1;
                try text_insert.appendSlice(allocator, diffs.items[pointer].text);
            },
            .delete => {
                count_delete += 1;
                try text_delete.appendSlice(allocator, diffs.items[pointer].text);
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete >= 1 and count_insert >= 1) {
                    // Delete the offending records and add the merged ones.
                    freeRangeDiffList(
                        allocator,
                        &diffs,
                        pointer - count_delete - count_insert,
                        count_delete + count_insert,
                    );
                    try diffs.replaceRange(
                        allocator,
                        pointer - count_delete - count_insert,
                        count_delete + count_insert,
                        &.{},
                    );
                    pointer = pointer - count_delete - count_insert;
                    var sub_diff = try diffInternal(
                        text_mode_config,
                        allocator,
                        text_delete.items,
                        text_insert.items,
                        deadline,
                    );
                    {
                        errdefer deinitDiffList(allocator, &sub_diff);
                        try diffs.ensureUnusedCapacity(allocator, sub_diff.items.len);
                    }
                    defer sub_diff.deinit(allocator);
                    const new_diff = diffs.addManyAtAssumeCapacity(pointer, sub_diff.items.len);
                    @memcpy(new_diff, sub_diff.items);
                    pointer = pointer + sub_diff.items.len;
                }
                count_insert = 0;
                count_delete = 0;
                text_delete.items.len = 0;
                text_insert.items.len = 0;
            },
        }
        pointer += 1;
    }
    diffs.items.len -= 1; // Remove the dummy entry at the end.

    return diffs;
}

// These numbers have a 32 point buffer, to avoid annoyance with
// c0 control characters.  The algorithm drops the bottom points,
// not the top, that is, it will use 0x10ffff given enough unique
// lines.
const UNICODE_MAX = 0x10ffdf;
const UNICODE_TWO_THIRDS = 742724;
const UNICODE_ONE_THIRD = 371355;
comptime {
    assert(UNICODE_TWO_THIRDS + UNICODE_ONE_THIRD == UNICODE_MAX);
    assert(UNICODE_TWO_THIRDS + UNICODE_ONE_THIRD + CHAR_OFFSET == 0x10ffff);
}

/// Split two texts into a list of strings.  Reduce the texts to a string of
/// hashes where each Unicode character represents one line.
/// @param text1 First string.
/// @param text2 Second string.
/// @return Three element Object array, containing the encoded text1, the
///     encoded text2 and the List of unique strings.  The zeroth element
///     of the List of unique strings is intentionally blank.
fn diffLinesToChars(
    allocator: std.mem.Allocator,
    text1: []const u8,
    text2: []const u8,
) OOM!LinesToCharsResult {
    var line_array = ArrayListUnmanaged([]const u8){};
    errdefer line_array.deinit(allocator);
    line_array.items.len = 0;
    var line_hash = std.StringHashMapUnmanaged(u21){};
    defer line_hash.deinit(allocator);
    // e.g. line_array[4] == "Hello\n"
    // e.g. line_hash.get("Hello\n") == 4

    // Allocate 2/3rds of the space for text1, the rest for text2.
    const chars1 = try diffLinesToCharsMunge(allocator, text1, &line_array, &line_hash, UNICODE_TWO_THIRDS);
    errdefer allocator.free(chars1);
    const chars2 = try diffLinesToCharsMunge(allocator, text2, &line_array, &line_hash, UNICODE_ONE_THIRD);
    return .{ .chars_1 = chars1, .chars_2 = chars2, .line_array = line_array };
}

const LinesToCharsResult = struct {
    chars_1: []const u8,
    chars_2: []const u8,
    line_array: ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *LinesToCharsResult, allocator: Allocator) void {
        allocator.free(self.chars_1);
        allocator.free(self.chars_2);
        self.line_array.deinit(allocator);
    }
};

/// Split a text into a list of strings.  Reduce the texts to a string of
/// hashes where each Unicode character represents one line.
/// @param text String to encode.
/// @param lineArray List of unique strings.
/// @param lineHash Map of strings to indices.
/// @param maxLines Maximum length of lineArray.
/// @return Encoded string.
fn diffLinesToCharsMunge(
    allocator: std.mem.Allocator,
    text: []const u8,
    line_array: *ArrayListUnmanaged([]const u8),
    line_hash: *std.StringHashMapUnmanaged(u21),
    max_lines: usize,
) OOM![]const u8 {
    var iter = LineIterator{ .text = text };
    return try diffIteratorToCharsMunge(
        allocator,
        line_array,
        line_hash,
        &iter,
        max_lines,
    );
}

/// Split a text into segments, yielded from an iterator.
/// Reduce the texts to a string of hashes where each Unicode character
/// represents one segment.
///
/// Iterators must provide: `next()`, which gives the next segment of
/// the test, and `short_circuit(usize)`, which is called when the
/// segment limit is reached, and returns the rest of the text.  The
/// parameter provided will be the length of the last segment provided
/// by `next()`, since the function will not process that segment, and
/// its text must be included in the remainder.
///
/// @param segment_array List of unique string segments.
/// @param line_hash Map of strings to indices into segment_array.
/// @param iterator Returns the next segment.  Must have functions
///        next(), returning the next segment, and short_circuit(),
///        called when max_segments is reached.
/// @param max_segments Maximum length of lineArray.  Limited to
///        0x10ffdf.
/// @return Encoded string.
fn diffIteratorToCharsMunge(
    allocator: std.mem.Allocator,
    segment_array: *ArrayListUnmanaged([]const u8),
    segment_hash: *std.StringHashMapUnmanaged(u21),
    iterator: anytype,
    max_segments: usize,
) OOM![]const u8 {
    // Because we rebase the codepoint off the already counted segments,
    // this makes the unreachables in the function legitimate:
    assert(max_segments <= UNICODE_MAX);
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    var codepoint: u21 = CHAR_OFFSET + cast(u21, segment_array.items.len);
    var char_buf: [4]u8 = undefined;
    while (iterator.next()) |line| {
        if (segment_hash.get(line)) |value| {
            const nbytes = std.unicode.wtf8Encode(value, &char_buf) catch unreachable;
            try chars.appendSlice(allocator, char_buf[0..nbytes]);
        } else {
            if (codepoint - CHAR_OFFSET == max_segments) {
                // Bail out
                const final_line = iterator.short_circuit(line.len);
                try segment_array.append(allocator, final_line);
                try segment_hash.put(allocator, final_line, codepoint);
                const nbytes = std.unicode.wtf8Encode(codepoint, &char_buf) catch unreachable;
                try chars.appendSlice(allocator, char_buf[0..nbytes]);
                break;
            }
            try segment_array.append(allocator, line);
            try segment_hash.put(allocator, line, codepoint);
            const nbytes = std.unicode.wtf8Encode(codepoint, &char_buf) catch unreachable;
            try chars.appendSlice(allocator, char_buf[0..nbytes]);
            codepoint += 1;
        }
    }
    return try chars.toOwnedSlice(allocator);
}

/// Rehydrate the text in a diff from a string of line hashes to real lines
/// of text.
/// @param diffs List of Diff objects.
/// @param lineArray List of unique strings.
fn diffCharsToLines(
    allocator: Allocator,
    char_diffs: *DiffList,
    line_array: []const []const u8,
) OOM!DiffList {
    var text = ArrayListUnmanaged(u8){};
    defer text.deinit(allocator);
    var diffs: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diffs);
    try diffs.ensureUnusedCapacity(allocator, char_diffs.items.len);
    for (char_diffs.items) |*d| {
        var cursor: usize = 0;
        while (cursor < d.text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(d.text[cursor]) catch {
                @panic("Internal decode error in diffsCharsToLines");
            };
            const cp = std.unicode.wtf8Decode(d.text[cursor..][0..cp_len]) catch {
                @panic("Internal decode error in diffCharsToLines");
            };
            try text.appendSlice(allocator, line_array[cp - CHAR_OFFSET]);
            cursor += cp_len;
        }
        diffs.appendAssumeCapacity(.{
            .operation = d.operation,
            .owned = true,
            .text = try text.toOwnedSlice(allocator),
        });
    }
    return diffs;
}

/// An iteration struct over lines, which includes the newline if present.
const LineIterator = struct {
    cursor: usize = 0,
    text: []const u8,

    /// Return the next line, including its newline, if one is present.
    pub fn next(iter: *LineIterator) ?[]const u8 {
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
    /// `back_out` parameter is how far before the cursor to slice from.
    pub fn short_circuit(iter: *LineIterator, back_out: usize) []const u8 {
        const from = iter.cursor - back_out;
        iter.cursor = iter.text.len;
        return iter.text[from..];
    }
};

/// Reorder and merge like edit sections.  Merge equalities.
/// Any edit section can move as long as it doesn't cross an equality.
/// @param diffs List of Diff objects.
fn diffCleanupMerge(allocator: std.mem.Allocator, diffs: *DiffList) OOM!void {
    // Add a dummy entry at the end.
    try diffs.append(allocator, Edit.asBorrow(.equal, ""));
    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;

    var text_delete = ArrayListUnmanaged(u8){};
    defer text_delete.deinit(allocator);

    var text_insert = ArrayListUnmanaged(u8){};
    defer text_insert.deinit(allocator);

    while (pointer < diffs.items.len) {
        switch (diffs.items[pointer].operation) {
            .insert => {
                count_insert += 1;
                assert(pointer < diffs.items.len);
                try text_insert.appendSlice(allocator, diffs.items[pointer].text);
                pointer += 1;
            },
            .delete => {
                count_delete += 1;
                try text_delete.appendSlice(allocator, diffs.items[pointer].text);
                pointer += 1;
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete + count_insert > 1) {
                    if (count_delete != 0 and count_insert != 0) {
                        // Factor out any common prefixes.
                        var common_length: usize = diffCommonPrefix(text_insert.items, text_delete.items);
                        if (common_length != 0) {
                            if ((pointer - count_delete - count_insert) > 0 and
                                diffs.items[pointer - count_delete - count_insert - 1].operation == .equal)
                            { // The prefix is not at the start of the diffs
                                const ii = pointer - count_delete - count_insert - 1;
                                var nt = try allocator.alloc(u8, diffs.items[ii].text.len + common_length);
                                const old_equal = diffs.items[ii];
                                @memcpy(nt[0..old_equal.text.len], old_equal.text);
                                @memcpy(nt[old_equal.text.len..], text_insert.items[0..common_length]);
                                diffs.items[ii].text = nt;
                                diffs.items[ii].owned = true;
                                var equal_to_deinit = old_equal;
                                equal_to_deinit.deinit(allocator);
                            } else {
                                try diffs.ensureUnusedCapacity(allocator, 1);
                                // ANN: dupe
                                // This equality is materialized from the scratch merge buffer.
                                diffs.insertAssumeCapacity(0, try Edit.asOwn(allocator, .equal, text_insert.items[0..common_length]));
                                pointer += 1;
                            }
                            try text_insert.replaceRange(allocator, 0, common_length, &.{});
                            try text_delete.replaceRange(allocator, 0, common_length, &.{});
                        }
                        // Factor out any common suffices.
                        // @ZigPort this seems very wrong
                        common_length = diffCommonSuffix(text_insert.items, text_delete.items);
                        if (common_length != 0) {
                            const old_edit = diffs.items[pointer];
                            const new_text = try std.mem.concat(allocator, u8, &.{
                                text_insert.items[text_insert.items.len - common_length ..],
                                old_edit.text,
                            });
                            diffs.items[pointer].text = new_text;
                            diffs.items[pointer].owned = true;
                            var edit_to_deinit = old_edit;
                            edit_to_deinit.deinit(allocator);
                            text_insert.items.len -= common_length;
                            text_delete.items.len -= common_length;
                        }
                    }
                    // Delete the offending records and add the merged ones.
                    pointer -= count_delete + count_insert;
                    if (count_delete + count_insert > 0) {
                        freeRangeDiffList(allocator, diffs, pointer, count_delete + count_insert);
                        try diffs.replaceRange(allocator, pointer, count_delete + count_insert, &.{});
                    }

                    if (text_delete.items.len != 0) {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        // ANN: dupe
                        // This delete block is synthesized from aggregated scratch text.
                        diffs.insertAssumeCapacity(pointer, try Edit.asOwn(allocator, .delete, text_delete.items));
                        pointer += 1;
                    }
                    if (text_insert.items.len != 0) {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        // ANN: dupe
                        // This insert block is synthesized from aggregated scratch text.
                        diffs.insertAssumeCapacity(pointer, try Edit.asOwn(allocator, .insert, text_insert.items));
                        pointer += 1;
                    }
                    pointer += 1;
                } else if (pointer != 0 and diffs.items[pointer - 1].operation == .equal) {
                    // Merge this equality with the previous one.
                    // Diff texts are []const u8 so a realloc isn't practical here
                    var nt = try allocator.alloc(u8, diffs.items[pointer - 1].text.len + diffs.items[pointer].text.len);
                    const old_prev = diffs.items[pointer - 1];
                    @memcpy(nt[0..old_prev.text.len], old_prev.text);
                    @memcpy(nt[old_prev.text.len..], diffs.items[pointer].text);
                    diffs.items[pointer - 1].text = nt;
                    diffs.items[pointer - 1].owned = true;
                    var prev_to_deinit = old_prev;
                    prev_to_deinit.deinit(allocator);
                    const dead_diff = diffs.orderedRemove(pointer);
                    var dead = dead_diff;
                    dead.deinit(allocator);
                } else {
                    pointer += 1;
                }
                count_insert = 0;
                count_delete = 0;
                text_delete.items.len = 0;
                text_insert.items.len = 0;
            },
        }
    }
    if (diffs.items[diffs.items.len - 1].text.len == 0) {
        diffs.items.len -= 1;
    }
    // Second pass: look for single edits surrounded on both sides by
    // equalities which can be shifted sideways to eliminate an equality.
    // e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
    var changes = false;
    pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < (diffs.items.len - 1)) {
        if (diffs.items[pointer - 1].operation == .equal and
            diffs.items[pointer + 1].operation == .equal)
        {
            // This is a single edit surrounded by equalities.
            if (std.mem.endsWith(u8, diffs.items[pointer].text, diffs.items[pointer - 1].text)) {
                const old_edit = diffs.items[pointer];
                const pt = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer - 1].text,
                    diffs.items[pointer].text[0 .. diffs.items[pointer].text.len -
                        diffs.items[pointer - 1].text.len],
                });
                diffs.items[pointer].text = pt;
                diffs.items[pointer].owned = true;
                var edit_to_deinit = old_edit;
                edit_to_deinit.deinit(allocator);
                const old_edit1 = diffs.items[pointer + 1];
                const p1t = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer - 1].text,
                    diffs.items[pointer + 1].text,
                });
                diffs.items[pointer + 1].text = p1t;
                diffs.items[pointer + 1].owned = true;
                var edit1_to_deinit = old_edit1;
                edit1_to_deinit.deinit(allocator);
                freeRangeDiffList(allocator, diffs, pointer - 1, 1);
                try diffs.replaceRange(allocator, pointer - 1, 1, &.{});
                changes = true;
            } else if (std.mem.startsWith(u8, diffs.items[pointer].text, diffs.items[pointer + 1].text)) {
                const old_editm1 = diffs.items[pointer - 1];
                const pm1t = try std.mem.concat(allocator, u8, &.{
                    diffs.items[pointer - 1].text,
                    diffs.items[pointer + 1].text,
                });
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
    // If shifts were made, the diff needs reordering and another shift sweep.
    if (changes) {
        try diffCleanupMerge(allocator, diffs);
    }
}

/// Reduce the number of edits by eliminating semantically trivial
/// equalities.
/// @param diffs List of Diff objects.
fn diffCleanupSemantic(allocator: std.mem.Allocator, diffs: *DiffList) OOM!void {
    var changes = false;
    // Stack of indices where equalities are found.
    var equalities = ArrayListUnmanaged(usize){};
    defer equalities.deinit(allocator);
    // Always equal to equalities[equalitiesLength-1][1]
    var last_equality: ?[]const u8 = null;
    var pointer: usize = 0; // Index of current position.
    // Number of characters that changed prior to the equality.
    var length_insertions1: usize = 0;
    var length_deletions1: usize = 0;
    // Number of characters that changed after the equality.
    var length_insertions2: usize = 0;
    var length_deletions2: usize = 0;
    var reset_pointer = false;
    while (pointer < diffs.items.len) {
        if (diffs.items[pointer].operation == .equal) { // Equality found.
            try equalities.append(allocator, pointer);
            length_insertions1 = length_insertions2;
            length_deletions1 = length_deletions2;
            length_insertions2 = 0;
            length_deletions2 = 0;
            last_equality = diffs.items[pointer].text;
        } else { // an insertion or deletion
            if (diffs.items[pointer].operation == .insert) {
                length_insertions2 += diffs.items[pointer].text.len;
            } else {
                length_deletions2 += diffs.items[pointer].text.len;
            }
            // Eliminate an equality that is smaller or equal to the edits on both
            // sides of it.
            if (last_equality != null and
                (last_equality.?.len <= @max(length_insertions1, length_deletions1)) and
                (last_equality.?.len <= @max(length_insertions2, length_deletions2)))
            {
                // Duplicate record.
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(
                    equalities.items[equalities.items.len - 1],
                    try Edit.asOwn(
                        allocator,
                        .delete,
                        // ANN: dupe
                        // This path needs a second live copy of the equality text.
                        // It's possible that this can be follow-original with
                        // the right changes to the logic.
                        last_equality.?,
                    ),
                );
                // Change second copy to insert.
                diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                // Throw away the equality we just deleted.
                _ = equalities.pop();
                if (equalities.items.len > 0) {
                    _ = equalities.pop();
                }
                if (equalities.items.len > 0) {
                    pointer = equalities.items[equalities.items.len - 1];
                } else {
                    reset_pointer = true;
                }
                length_insertions1 = 0; // Reset the counters.
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

    // Normalize the diff.
    if (changes) {
        try diffCleanupMerge(allocator, diffs);
    }
    try diffCleanupSemanticLossless(allocator, diffs);

    // Find any overlaps between deletions and insertions.
    // e.g: <del>abcxxx</del><ins>xxxdef</ins>
    //   -> <del>abc</del>xxx<ins>def</ins>
    // e.g: <del>xxxabc</del><ins>defxxx</ins>
    //   -> <ins>def</ins>xxx<del>abc</del>
    // Only extract an overlap if it is as big as the edit ahead or behind it.
    pointer = 1;
    while (pointer < diffs.items.len) {
        if (diffs.items[pointer - 1].operation == .delete and
            diffs.items[pointer].operation == .insert)
        {
            // ANN: NOTE: each of these comes from an Edit, which will either itself
            // be borrowed or owned.  Where it says follow-original, those have to be
            // either a borrow or another own, depending on which case applies.
            const deletion = diffs.items[pointer - 1].text;
            const insertion = diffs.items[pointer].text;
            const overlap_length1: usize = diffCommonOverlap(deletion, insertion);
            const overlap_length2: usize = diffCommonOverlap(insertion, deletion);
            if (overlap_length1 >= overlap_length2) {
                if (@as(f32, @floatFromInt(overlap_length1)) >= @as(f32, @floatFromInt(deletion.len)) / 2.0 or
                    @as(f32, @floatFromInt(overlap_length1)) >= @as(f32, @floatFromInt(insertion.len)) / 2.0)
                {
                    // Overlap found.
                    // Insert an equality and trim the surrounding edits.
                    try diffs.ensureUnusedCapacity(allocator, 1);
                    diffs.insertAssumeCapacity(
                        pointer,
                        try Edit.asOwn(
                            allocator,
                            .equal,
                            // ANN: follow-original
                            insertion[0..overlap_length1],
                        ),
                    );
                    diffs.items[pointer - 1].text =
                        // ANN: follow-original
                        try allocator.dupe(u8, deletion[0 .. deletion.len - overlap_length1]);
                    allocator.free(deletion);
                    diffs.items[pointer + 1].text =
                        // ANN: follow-original
                        try allocator.dupe(u8, insertion[overlap_length1..]);
                    allocator.free(insertion);
                    pointer += 1;
                }
            } else {
                if (@as(f32, @floatFromInt(overlap_length2)) >= @as(f32, @floatFromInt(deletion.len)) / 2.0 or
                    @as(f32, @floatFromInt(overlap_length2)) >= @as(f32, @floatFromInt(insertion.len)) / 2.0)
                {
                    // Reverse overlap found.
                    // Insert an equality and swap and trim the surrounding edits.
                    try diffs.ensureUnusedCapacity(allocator, 1);
                    diffs.insertAssumeCapacity(
                        pointer,
                        try Edit.asOwn(
                            allocator,
                            .equal,
                            // ANN: follow-original
                            deletion[0..overlap_length2],
                        ),
                    );
                    // ANN: follow-original
                    const new_minus = try allocator.dupe(u8, insertion[0 .. insertion.len - overlap_length2]);
                    errdefer allocator.free(new_minus); // necessary due to swap
                    // ANN: follow-original
                    const new_plus = try allocator.dupe(u8, deletion[overlap_length2..]);
                    allocator.free(deletion);
                    allocator.free(insertion);
                    diffs.items[pointer - 1].operation = .insert;
                    diffs.items[pointer - 1].text = new_minus;
                    diffs.items[pointer + 1].operation = .delete;
                    diffs.items[pointer + 1].text = new_plus;
                    pointer += 1;
                }
            }
            pointer += 1;
        }
        pointer += 1;
    }
}

/// Look for single edits surrounded on both sides by equalities
/// which can be shifted sideways to align the edit to a word boundary.
/// e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
fn diffCleanupSemanticLossless(
    allocator: std.mem.Allocator,
    diffs: *DiffList,
) OOM!void {
    var pointer: usize = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < @as(isize, @intCast(diffs.items.len)) - 1) {
        if (diffs.items[pointer - 1].operation == .equal and
            diffs.items[pointer + 1].operation == .equal)
        {
            // This is a single edit surrounded by equalities.
            var equality_1 = std.ArrayListUnmanaged(u8){};
            defer equality_1.deinit(allocator);
            try equality_1.appendSlice(allocator, diffs.items[pointer - 1].text);

            var edit = std.ArrayListUnmanaged(u8){};
            defer edit.deinit(allocator);
            try edit.appendSlice(allocator, diffs.items[pointer].text);

            var equality_2 = std.ArrayListUnmanaged(u8){};
            defer equality_2.deinit(allocator);
            try equality_2.appendSlice(allocator, diffs.items[pointer + 1].text);

            // First, shift the edit as far left as possible.
            const common_offset = diffCommonSuffix(equality_1.items, edit.items);
            if (common_offset > 0) {
                // ANN: dupe
                // This is scratch text used while reshaping the local window.
                const common_string = try allocator.dupe(u8, edit.items[edit.items.len - common_offset ..]);
                defer allocator.free(common_string);

                equality_1.items.len = equality_1.items.len - common_offset;

                // ANN: dupe
                // This is scratch text used while reshaping the local window.
                const not_common = try allocator.dupe(u8, edit.items[0 .. edit.items.len - common_offset]);
                defer allocator.free(not_common);

                edit.clearRetainingCapacity();
                try edit.appendSlice(allocator, common_string);
                try edit.appendSlice(allocator, not_common);

                try equality_2.insertSlice(allocator, 0, common_string);
            }

            // Second, step character by character right,
            // looking for the best fit.
            var best_equality_1 = ArrayListUnmanaged(u8){};
            defer best_equality_1.deinit(allocator);
            try best_equality_1.appendSlice(allocator, equality_1.items);

            var best_edit = ArrayListUnmanaged(u8){};
            defer best_edit.deinit(allocator);
            try best_edit.appendSlice(allocator, edit.items);

            var best_equality_2 = ArrayListUnmanaged(u8){};
            defer best_equality_2.deinit(allocator);
            try best_equality_2.appendSlice(allocator, equality_2.items);

            var best_score = diffCleanupSemanticScore(equality_1.items, edit.items) +
                diffCleanupSemanticScore(edit.items, equality_2.items);

            while (edit.items.len != 0 and equality_2.items.len != 0 and edit.items[0] == equality_2.items[0]) {
                try equality_1.append(allocator, edit.items[0]);

                _ = edit.orderedRemove(0);
                try edit.append(allocator, equality_2.items[0]);

                _ = equality_2.orderedRemove(0);

                const score = diffCleanupSemanticScore(equality_1.items, edit.items) +
                    diffCleanupSemanticScore(edit.items, equality_2.items);
                // The >= encourages trailing rather than leading whitespace on
                // edits.
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

            if (!std.mem.eql(u8, diffs.items[pointer - 1].text, best_equality_1.items)) {
                // We have an improvement, save it back to the diff.
                if (best_equality_1.items.len != 0) {
                    const old_text = diffs.items[pointer - 1].text;
                    // ANN: dupe
                    // The best-fit text comes from scratch buffers, not stable source slices.
                    diffs.items[pointer - 1].text = try allocator.dupe(u8, best_equality_1.items);
                    allocator.free(old_text);
                } else {
                    var old_diff = diffs.orderedRemove(pointer - 1);
                    old_diff.deinit(allocator);
                    pointer -= 1;
                }
                const old_text1 = diffs.items[pointer].text;
                // ANN: dupe
                // The best-fit text comes from scratch buffers, not stable source slices.
                diffs.items[pointer].text = try allocator.dupe(u8, best_edit.items);
                defer allocator.free(old_text1);
                if (best_equality_2.items.len != 0) {
                    const old_text2 = diffs.items[pointer + 1].text;
                    // ANN: dupe
                    // The best-fit text comes from scratch buffers, not stable source slices.
                    diffs.items[pointer + 1].text = try allocator.dupe(u8, best_equality_2.items);
                    allocator.free(old_text2);
                } else {
                    var old_diff = diffs.orderedRemove(pointer + 1);
                    old_diff.deinit(allocator);
                    pointer -= 1;
                }
            }
        }
        pointer += 1;
    }
}

/// Given two strings, compute a score representing whether the internal
/// boundary falls on logical boundaries.
/// Scores range from 6 (best) to 0 (worst).
/// @param one First string.
/// @param two Second string.
/// @return The score.
fn diffCleanupSemanticScore(one: []const u8, two: []const u8) usize {
    if (one.len == 0 or two.len == 0) {
        // Edges are the best.
        return 6;
    }

    // Each port of this function behaves slightly differently due to
    // subtle differences in each language's definition of things like
    // 'whitespace'.  Since this function's purpose is largely cosmetic,
    // the choice has been made to use each language's native features
    // rather than force total conformity.
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

    if (blankLine1 or blankLine2) {
        // Five points for blank lines.
        return 5;
    } else if (lineBreak1 or lineBreak2) {
        // Four points for line breaks.
        return 4;
    } else if (nonAlphaNumeric1 and !whitespace1 and whitespace2) {
        // Three points for end of sentences.
        return 3;
    } else if (whitespace1 or whitespace2) {
        // Two points for whitespace.
        return 2;
    } else if (nonAlphaNumeric1 or nonAlphaNumeric2) {
        // One point for non-alphanumeric.
        return 1;
    }
    return 0;
}

fn diffCleanupEfficiencyConfig(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    diffs: *DiffList,
) OOM!void {
    var changes = false;
    // Stack of indices where equalities are found.
    var equalities = ArrayList(usize).init(allocator);
    defer equalities.deinit();
    // Always equal to equalities[equalitiesLength-1][1]
    var last_equality: []const u8 = "";
    var ipointer: isize = 0; // Index of current position.
    // Is there an insertion operation before the last equality.
    var pre_ins = false;
    // Is there a deletion operation before the last equality.
    var pre_del = false;
    // Is there an insertion operation after the last equality.
    var post_ins = false;
    // Is there a deletion operation after the last equality.
    var post_del = false;
    while (ipointer < diffs.items.len) {
        const pointer: usize = @intCast(ipointer);
        if (diffs.items[pointer].operation == .equal) { // Equality found.
            if (diffs.items[pointer].text.len < config.edit_cost and (post_ins or post_del)) {
                // Candidate found.
                try equalities.append(pointer);
                pre_ins = post_ins;
                pre_del = post_del;
                last_equality = diffs.items[pointer].text;
            } else {
                // Not a candidate, and can never become one.
                equalities.items.len = 0;
                last_equality = "";
            }
            post_ins = false;
            post_del = false;
        } else { // An insertion or deletion.
            if (diffs.items[pointer].operation == .delete) {
                post_del = true;
            } else {
                post_ins = true;
            }
            // Five types to be split:
            // <ins>A</ins><del>B</del>XY<ins>C</ins><del>D</del>
            // <ins>A</ins>X<ins>C</ins><del>D</del>
            // <ins>A</ins><del>B</del>X<ins>C</ins>
            // <ins>A</del>X<ins>C</ins><del>D</del>
            // <ins>A</ins><del>B</del>X<del>C</del>
            if ((last_equality.len != 0) and
                ((pre_ins and pre_del and post_ins and post_del) or
                    ((last_equality.len < config.edit_cost / 2) and
                        (boolInt(pre_ins) + boolInt(pre_del) + boolInt(post_ins) + boolInt(post_del) == 3))))
            {
                // Duplicate record.
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(
                    equalities.items[equalities.items.len - 1],
                    try Edit.asOwn(
                        allocator,
                        .delete,
                        // ANN: dupe
                        // This path needs a second live copy of the equality text.
                        last_equality,
                    ),
                );
                // Change second copy to insert.
                diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                _ = equalities.pop(); // Throw away the equality we just deleted.
                last_equality = "";
                if (pre_ins and pre_del) {
                    // No changes made which could affect previous entry, keep going.
                    post_ins = true;
                    post_del = true;
                    equalities.items.len = 0;
                } else {
                    if (equalities.items.len > 0) {
                        _ = equalities.pop();
                    }

                    ipointer = if (equalities.items.len > 0) @intCast(equalities.items[equalities.items.len - 1]) else -1;
                    post_ins = false;
                    post_del = false;
                }
                changes = true;
            }
        }
        ipointer += 1;
    }

    if (changes) {
        try diffCleanupMerge(allocator, diffs);
    }
}

/// loc is a location in text1, compute and return the equivalent location in
/// text2.
/// e.g. "The cat" vs "The big cat", 1->1, 5->8
/// @param diffs List of Diff objects.
/// @param loc Location within text1.
/// @return Location within text2.
///
fn diffIndex(diffs: DiffList, u_loc: usize) usize {
    var chars1: isize = 0;
    var chars2: isize = 0;
    var last_chars1: isize = 0;
    var last_chars2: isize = 0;
    const loc: isize = @intCast(u_loc);
    //  Dummy diff
    var last_diff: Edit = .{ .operation = .equal, .owned = false, .text = "" };
    for (diffs.items) |a_diff| {
        if (a_diff.operation != .insert) {
            // Equality or deletion.
            chars1 += @intCast(a_diff.text.len);
        }
        if (a_diff.operation != .delete) {
            // Equality or insertion.
            chars2 += @intCast(a_diff.text.len);
        }
        if (chars1 > loc) {
            // Overshot the location.
            last_diff = a_diff;
            break;
        }
    }
    last_chars1 = chars1;
    last_chars2 = chars2;

    if (last_diff.text.len != 0 and last_diff.operation == .delete) {
        // The location was deleted.
        return @intCast(last_chars2);
    }
    // Add the remaining character length.
    return @intCast(last_chars2 + (loc - last_chars1));
}

/// Return text representing a pretty-formatted `DiffList`.
/// See `DiffDecorations` for how to customize this output.
fn diffPrettyFormat(
    allocator: Allocator,
    diffs: DiffList,
    deco: DiffDecorations,
) ![]const u8 {
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    const writer = out.writer();
    _ = try writeDiffPrettyFormat(allocator, writer, diffs, deco);
    return out.toOwnedSlice();
}

/// Pretty-print a diff for output to a terminal.
fn diffPrettyFormatXTerm(allocator: Allocator, diffs: DiffList) ![]const u8 {
    return try diffPrettyFormat(allocator, diffs, .xterm_classic);
}

/// Write a pretty-formatted `DiffList` to `writer`.  The `Allocator`
/// is only used if a custom text formatter is defined for
/// `DiffDecorations`.  Returns number of bytes written.
fn writeDiffPrettyFormat(
    allocator: Allocator,
    writer: anytype,
    diffs: DiffList,
    deco: DiffDecorations,
) !usize {
    var written: usize = 0;
    for (diffs.items) |d| {
        const text = if (deco.pre_process) |lambda|
            try lambda(allocator, d)
        else
            d.text;
        defer {
            if (deco.pre_process) |_|
                allocator.free(text);
        }
        switch (d.operation) {
            .delete => {
                //
                written += try writer.write(deco.delete_start);
                written += try writer.write(text);
                written += try writer.write(deco.delete_end);
            },
            .insert => {
                written += try writer.write(deco.insert_start);
                written += try writer.write(text);
                written += try writer.write(deco.insert_end);
            },
            .equal => {
                written += try writer.write(deco.equals_start);
                written += try writer.write(text);
                written += try writer.write(deco.equals_end);
            },
        }
    }
    return written;
}

///
/// Compute and return the source text (all equalities and deletions).
/// @param diffs List of `Diff` objects.
/// @return Source text.
///
fn diffBeforeText(allocator: Allocator, diffs: DiffList) OOM![]const u8 {
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    for (diffs.items) |d| {
        if (d.operation != .insert) {
            try chars.appendSlice(allocator, d.text);
        }
    }
    return chars.toOwnedSlice(allocator);
}

///
/// Compute and return the destination text (all equalities and insertions).
/// @param diffs List of `Diff` objects.
/// @return Destination text.
///
fn diffAfterText(allocator: Allocator, diffs: DiffList) OOM![]const u8 {
    var chars = ArrayListUnmanaged(u8){};
    defer chars.deinit(allocator);
    for (diffs.items) |d| {
        if (d.operation != .delete) {
            try chars.appendSlice(allocator, d.text);
        }
    }
    return chars.toOwnedSlice(allocator);
}

/// Free a range of Diffs inside a list.  Used during cleanups and
/// edits.
fn freeRangeDiffList(
    allocator: Allocator,
    diffs: *DiffList,
    start: usize,
    len: usize,
) void {
    const after_range = start + len;
    const range = diffs.items[start..after_range];
    for (range) |*d| {
        d.deinit(allocator);
    }
}

/// Determine if the suffix of one string is the prefix of another.
/// @param text1 First string.
/// @param text2 Second string.
/// @return The number of characters common to the end of the first
///     string and the start of the second string.
fn diffCommonOverlap(text1_in: []const u8, text2_in: []const u8) usize {
    var text1 = text1_in;
    var text2 = text2_in;

    // Cache the text lengths to prevent multiple calls.
    const text1_length = text1.len;
    const text2_length = text2.len;
    // Eliminate the null case.
    if (text1_length == 0 or text2_length == 0) {
        return 0;
    }
    // Truncate the longer string.
    if (text1_length > text2_length) {
        text1 = text1[text1_length - text2_length ..];
    } else if (text1_length < text2_length) {
        text2 = text2[0..text1_length];
    }
    const text_length = @min(text1_length, text2_length);
    // Quick check for the worst case.
    if (std.mem.eql(u8, text1, text2)) {
        return text_length;
    }

    // Start by looking for a single character match
    // and increase length until no match is found.
    // Performance analysis: https://neil.fraser.name/news/2010/11/04/
    var best: usize = 0;
    var length: usize = 1;
    const best_idx = idx: while (true) {
        const pattern = text1[text_length - length ..];
        const found = std.mem.indexOf(u8, text2, pattern) orelse
            break :idx best;

        length += found;

        if (found == 0 or std.mem.eql(u8, text1[text_length - length ..], text2[0..length])) {
            best = length;
            length += 1;
        }
    };
    if (best_idx == 0) return best_idx;
    // This would mean a truncation: lead or follow, followed by a follow
    // which differs (or it would be included in our overlap).
    // TODO this currently appears to be dead code, keep an eye on that.
    // Reasoning: we're looking for a suffix which matches a prefix, and
    // we've already assured that edits end with a follow byte, and begin
    // with a lead byte, ASCII being both for our purposes.  So a split
    // should not be possible.
    // I'm going to add a panic just so I know if test cases of any sort
    // trigger this code path.
    // XXX Remove this before merge if it can't be triggered.
    if (is_follow(text2[best_idx])) {
        // back out
        return fixSplitBackward(text2, best_idx);
    }
    return best_idx;
}

const Diff = @This();

inline fn boolInt(b: bool) u8 {
    return @intFromBool(b);
}

inline fn is_follow(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

inline fn fixSplitForward(text: []const u8, i: usize) usize {
    var idx = i;
    while (idx < text.len and is_follow(text[idx])) : (idx += 1) {}
    return idx;
}

inline fn fixSplitBackward(text: []const u8, i: usize) usize {
    var idx = i;
    if (idx < text.len) while (idx != 0 and is_follow(text[idx])) : (idx -= 1) {};
    return idx;
}

inline fn cast(as: type, val: anytype) as {
    return @as(as, @intCast(val));
}

inline fn u2i(val: usize) isize {
    return @intCast(val);
}

inline fn i2u(val: isize) usize {
    return @intCast(val);
}

//| Tests

fn expectEqualDiff(expected: []const Edit, actual: []const Edit) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.operation, a.operation);
        try testing.expectEqualStrings(e.text, a.text);
    }
}

test "Diff lifecycle" {
    const allocator = testing.allocator;

    {
        var diff_obj: Diff = .default;
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
        var diff_obj = Diff.init(options);
        defer diff_obj.deinit(allocator);
        try testing.expectEqualDeep(options, diff_obj.config);
    }

    {
        var options: DiffConfig = .default;
        options.timeout = 0;
        var diff_obj = Diff.init(options);
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
        var diff_obj = Diff.init(options);
        _ = try diff_obj.diff(allocator, "abc", "axc");
        try testing.expect(diff_obj.edits.items.len != 0);
        diff_obj.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), diff_obj.edits.items.len);
    }

    {
        var options: DiffConfig = .default;
        options.timeout = 0;
        var diff_obj = Diff.init(options);
        defer diff_obj.deinit(allocator);
        _ = try diff_obj.diff(allocator, "abc", "axc");
        const first_len = diff_obj.edits.items.len;
        _ = try diff_obj.diff(allocator, "abc", "abc");
        try testing.expect(first_len != diff_obj.edits.items.len);
        try expectEqualDiff(@as([]const Edit, &.{
            Edit.asBorrow(.equal, "abc"),
        }), diff_obj.edits.items);
    }
}

test diffCommonPrefix {
    try testing.expectEqual(@as(usize, 0), diffCommonPrefix("abc", "xyz"));
    try testing.expectEqual(@as(usize, 4), diffCommonPrefix("1234abcdef", "1234xyz"));
    try testing.expectEqual(@as(usize, 4), diffCommonPrefix("1234", "1234xyz"));
}

test diffCommonSuffix {
    try testing.expectEqual(@as(usize, 0), diffCommonSuffix("abc", "xyz"));
    try testing.expectEqual(@as(usize, 4), diffCommonSuffix("abcdef1234", "xyz1234"));
    try testing.expectEqual(@as(usize, 4), diffCommonSuffix("1234", "xyz1234"));
}

test diffCommonOverlap {
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("", "abcd"));
    try testing.expectEqual(@as(usize, 3), diffCommonOverlap("abc", "abcd"));
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("123456", "abcd"));
    try testing.expectEqual(@as(usize, 3), diffCommonOverlap("123456xxx", "xxxabcd"));
    try testing.expectEqual(@as(usize, 0), diffCommonOverlap("fi", "\u{fb01}"));
}

const TestHalfMatch = struct {
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
    expected: ?HalfMatchResult,
};

fn testDiffHalfMatch(
    allocator: std.mem.Allocator,
    params: TestHalfMatch,
) !void {
    const maybe_result = try diffHalfMatchConfig(params.config, allocator, params.before, params.after);
    defer if (maybe_result) |result| result.deinit(allocator);
    try testing.expectEqualDeep(params.expected, maybe_result);
}

fn testDiffHalfMatchLeak(allocator: Allocator) !void {
    const config = DiffConfig.default;
    const text1 = "The quick brown fox jumps over the lazy dog.";
    const text2 = "That quick brown fox jumped over a lazy dog.";
    var diffs = try diffListFromConfig(allocator, config, text2, text1);
    deinitDiffList(allocator, &diffs);
}

test "diffHalfMatch leak regression test" {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatchLeak, .{});
}

test "diffHalfMatch" {
    const one_timeout: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 1;
        break :blk config;
    };

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "1234567890",
        .after = "abcdef",
        .expected = null,
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "12345",
        .after = "23",
        .expected = null,
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "1234567890",
        .after = "a345678z",
        .expected = .{
            .prefix_before = "12",
            .suffix_before = "90",
            .prefix_after = "a",
            .suffix_after = "z",
            .common_middle = "345678",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "a345678z",
        .after = "1234567890",
        .expected = .{
            .prefix_before = "a",
            .suffix_before = "z",
            .prefix_after = "12",
            .suffix_after = "90",
            .common_middle = "345678",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "abc56789z",
        .after = "1234567890",
        .expected = .{
            .prefix_before = "abc",
            .suffix_before = "z",
            .prefix_after = "1234",
            .suffix_after = "0",
            .common_middle = "56789",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "a23456xyz",
        .after = "1234567890",
        .expected = .{
            .prefix_before = "a",
            .suffix_before = "xyz",
            .prefix_after = "1",
            .suffix_after = "7890",
            .common_middle = "23456",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "121231234123451234123121",
        .after = "a1234123451234z",
        .expected = .{
            .prefix_before = "12123",
            .suffix_before = "123121",
            .prefix_after = "a",
            .suffix_after = "z",
            .common_middle = "1234123451234",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "x-=-=-=-=-=-=-=-=-=-=-=-=",
        .after = "xx-=-=-=-=-=-=-=",
        .expected = .{
            .prefix_before = "",
            .suffix_before = "-=-=-=-=-=",
            .prefix_after = "x",
            .suffix_after = "",
            .common_middle = "x-=-=-=-=-=-=-=",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "-=-=-=-=-=-=-=-=-=-=-=-=y",
        .after = "-=-=-=-=-=-=-=yy",
        .expected = .{
            .prefix_before = "-=-=-=-=-=",
            .suffix_before = "",
            .prefix_after = "",
            .suffix_after = "y",
            .common_middle = "-=-=-=-=-=-=-=y",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
        .config = one_timeout,
        .before = "qHilloHelloHew",
        .after = "xHelloHeHulloy",
        .expected = .{
            .prefix_before = "qHillo",
            .suffix_before = "w",
            .prefix_after = "x",
            .suffix_after = "Hulloy",
            .common_middle = "HelloHe",
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffHalfMatch, .{TestHalfMatch{
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

test diffLinesToChars {
    const allocator = testing.allocator;
    var tmp_array_list = ArrayList([]const u8).init(allocator);
    defer tmp_array_list.deinit();
    try tmp_array_list.append("alpha\n");
    try tmp_array_list.append("beta\n");

    var result = try diffLinesToChars(allocator, "alpha\nbeta\nalpha\n", "beta\nalpha\nbeta\n");
    try testing.expectEqualStrings(" ! ", result.chars_1);
    try testing.expectEqualStrings("! !", result.chars_2);
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items);
    result.deinit(allocator);

    tmp_array_list.items.len = 0;
    try tmp_array_list.append("alpha\r\n");
    try tmp_array_list.append("beta\r\n");
    try tmp_array_list.append("\r\n");

    result = try diffLinesToChars(allocator, "", "alpha\r\nbeta\r\n\r\n\r\n");
    try testing.expectEqualStrings("", result.chars_1);
    try testing.expectEqualStrings(" !\"\"", result.chars_2);
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items);
    result.deinit(allocator);
    tmp_array_list.items.len = 0;
    try tmp_array_list.append("a");
    try tmp_array_list.append("b");

    result = try diffLinesToChars(allocator, "a", "b");
    try testing.expectEqualStrings(" ", result.chars_1);
    try testing.expectEqualStrings("!", result.chars_2);
    try testing.expectEqualDeep(tmp_array_list.items, result.line_array.items);
    result.deinit(allocator);

    {
        const n: u21 = 1024;

        var line_list = ArrayList(u8).init(allocator);
        defer line_list.deinit();
        var char_list = ArrayList(u8).init(allocator);
        defer char_list.deinit();

        var i: u21 = CHAR_OFFSET;
        var char_buf: [4]u8 = undefined;
        while (i < n) : (i += 1) {
            const nbytes = std.unicode.wtf8Encode(i, &char_buf) catch unreachable;
            try line_list.appendSlice(char_buf[0..nbytes]);
            try line_list.append('\n');
            try char_list.appendSlice(char_buf[0..nbytes]);
        }
        const codepoint_len = std.unicode.utf8CountCodepoints(char_list.items) catch unreachable;
        try testing.expectEqual(@as(usize, n - CHAR_OFFSET), codepoint_len);
        result = try diffLinesToChars(allocator, line_list.items, "");
        try testing.expectEqual(char_list.items.len, result.chars_1.len);
        try testing.expectEqualSlices(u8, char_list.items, result.chars_1);
        try testing.expectEqualStrings("", result.chars_2);
        result.deinit(allocator);

        var line_array = ArrayListUnmanaged([]const u8){};
        defer line_array.deinit(allocator);
        line_array.items.len = 0;
        var line_hash = std.StringHashMapUnmanaged(u21){};
        defer line_hash.deinit(allocator);
        const char_out = try diffLinesToCharsMunge(allocator, line_list.items, &line_array, &line_hash, 950);
        defer allocator.free(char_out);
        try testing.expectEqualStrings(
            "ϖ\nϗ\nϘ\nϙ\nϚ\nϛ\nϜ\nϝ\nϞ\nϟ\nϠ\nϡ\nϢ\nϣ\nϤ\nϥ\nϦ\nϧ\nϨ\nϩ\nϪ\nϫ\nϬ\nϭ\nϮ\nϯ\nϰ\nϱ\nϲ\nϳ\nϴ\nϵ\n϶\nϷ\nϸ\nϹ\nϺ\nϻ\nϼ\nϽ\nϾ\nϿ\n",
            line_array.getLast(),
        );
    }
}

const TCharLines = struct {
    diffs: []const Edit,
    line_array: []const []const u8,
    expected: []const Edit,
};

fn testDiffCharsToLines(
    allocator: std.mem.Allocator,
    params: TCharLines,
) !void {
    var char_diffs = try DiffList.initCapacity(allocator, params.diffs.len);
    defer deinitDiffList(allocator, &char_diffs);

    for (params.diffs) |item| {
        char_diffs.appendAssumeCapacity(.{ .operation = item.operation, .owned = true, .text = try allocator.dupe(u8, item.text) });
    }

    var diffs = try diffCharsToLines(allocator, &char_diffs, params.line_array);
    defer deinitDiffList(allocator, &diffs);

    try expectEqualDiff(params.expected, diffs.items);
}

test diffCharsToLines {
    var diff_list: DiffList = .empty;
    defer deinitDiffList(testing.allocator, &diff_list);
    try diff_list.ensureTotalCapacity(testing.allocator, 2);
    diff_list.appendSliceAssumeCapacity(&.{
        .{ .operation = .equal, .owned = true, .text = try testing.allocator.dupe(u8, " ! ") },
        .{ .operation = .insert, .owned = true, .text = try testing.allocator.dupe(u8, "! !") },
    });
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffCharsToLines,
        .{TCharLines{
            .diffs = diff_list.items,
            .line_array = &[_][]const u8{
                "alpha\n",
                "beta\n",
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "alpha\nbeta\nalpha\n" },
                .{ .operation = .insert, .owned = false, .text = "beta\nalpha\nbeta\n" },
            },
        }},
    );
}

const TestIO = struct {
    input: []const Edit,
    expected: []const Edit,
};

fn testDiffCleanupMerge(
    allocator: std.mem.Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .owned = true, .text = try allocator.dupe(u8, item.text) });
    }

    try diffCleanupMerge(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

test diffCleanupMerge {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "b" },
            .{ .operation = .insert, .owned = false, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "b" },
            .{ .operation = .insert, .owned = false, .text = "c" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "b" },
            .{ .operation = .equal, .owned = false, .text = "c" },
        },
        .expected = &.{.{ .operation = .equal, .owned = false, .text = "abc" }},
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "b" },
            .{ .operation = .delete, .owned = false, .text = "c" },
        },
        .expected = &.{.{ .operation = .delete, .owned = false, .text = "abc" }},
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .insert, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "b" },
            .{ .operation = .insert, .owned = false, .text = "c" },
        },
        .expected = &.{.{ .operation = .insert, .owned = false, .text = "abc" }},
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "b" },
            .{ .operation = .delete, .owned = false, .text = "c" },
            .{ .operation = .insert, .owned = false, .text = "d" },
            .{ .operation = .equal, .owned = false, .text = "e" },
            .{ .operation = .equal, .owned = false, .text = "f" },
        },
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "ac" },
            .{ .operation = .insert, .owned = false, .text = "bd" },
            .{ .operation = .equal, .owned = false, .text = "ef" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "abc" },
            .{ .operation = .delete, .owned = false, .text = "dc" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "d" },
            .{ .operation = .insert, .owned = false, .text = "b" },
            .{ .operation = .equal, .owned = false, .text = "c" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "x" },
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "abc" },
            .{ .operation = .delete, .owned = false, .text = "dc" },
            .{ .operation = .equal, .owned = false, .text = "y" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "xa" },
            .{ .operation = .delete, .owned = false, .text = "d" },
            .{ .operation = .insert, .owned = false, .text = "b" },
            .{ .operation = .equal, .owned = false, .text = "cy" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "ba" },
            .{ .operation = .equal, .owned = false, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .insert, .owned = false, .text = "ab" },
            .{ .operation = .equal, .owned = false, .text = "ac" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "c" },
            .{ .operation = .insert, .owned = false, .text = "ab" },
            .{ .operation = .equal, .owned = false, .text = "a" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "ca" },
            .{ .operation = .insert, .owned = false, .text = "ba" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "b" },
            .{ .operation = .equal, .owned = false, .text = "c" },
            .{ .operation = .delete, .owned = false, .text = "ac" },
            .{ .operation = .equal, .owned = false, .text = "x" },
        },
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "abc" },
            .{ .operation = .equal, .owned = false, .text = "acx" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "x" },
            .{ .operation = .delete, .owned = false, .text = "ca" },
            .{ .operation = .equal, .owned = false, .text = "c" },
            .{ .operation = .delete, .owned = false, .text = "b" },
            .{ .operation = .equal, .owned = false, .text = "a" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "xca" },
            .{ .operation = .delete, .owned = false, .text = "cba" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .delete, .owned = false, .text = "b" },
            .{ .operation = .insert, .owned = false, .text = "ab" },
            .{ .operation = .equal, .owned = false, .text = "c" },
        },
        .expected = &.{
            .{ .operation = .insert, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "bc" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupMerge, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "" },
            .{ .operation = .insert, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "b" },
        },
        .expected = &.{
            .{ .operation = .insert, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "b" },
        },
    }});
}

fn testDiffCleanupSemanticLossless(
    allocator: std.mem.Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .owned = true, .text = try allocator.dupe(u8, item.text) });
    }

    try diffCleanupSemanticLossless(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

fn sliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !DiffList {
    var diff_list: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diff_list);
    try diff_list.ensureTotalCapacity(allocator, diff_slice.len);
    for (diff_slice) |d| {
        diff_list.appendAssumeCapacity(try Edit.asOwn(
            allocator,
            d.operation,
            d.text,
        ));
    }
    return diff_list;
}

test diffCleanupSemanticLossless {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &[_]Edit{},
        .expected = &[_]Edit{},
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "AAA\r\n\r\nBBB" },
            .{ .operation = .insert, .owned = false, .text = "\r\nDDD\r\n\r\nBBB" },
            .{ .operation = .equal, .owned = false, .text = "\r\nEEE" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "AAA\r\n\r\n" },
            .{ .operation = .insert, .owned = false, .text = "BBB\r\nDDD\r\n\r\n" },
            .{ .operation = .equal, .owned = false, .text = "BBB\r\nEEE" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "AAA\r\nBBB" },
            .{ .operation = .insert, .owned = false, .text = " DDD\r\nBBB" },
            .{ .operation = .equal, .owned = false, .text = " EEE" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "AAA\r\n" },
            .{ .operation = .insert, .owned = false, .text = "BBB DDD\r\n" },
            .{ .operation = .equal, .owned = false, .text = "BBB EEE" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "The c" },
            .{ .operation = .insert, .owned = false, .text = "ow and the c" },
            .{ .operation = .equal, .owned = false, .text = "at." },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "The " },
            .{ .operation = .insert, .owned = false, .text = "cow and the " },
            .{ .operation = .equal, .owned = false, .text = "cat." },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "The-c" },
            .{ .operation = .insert, .owned = false, .text = "ow-and-the-c" },
            .{ .operation = .equal, .owned = false, .text = "at." },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "The-" },
            .{ .operation = .insert, .owned = false, .text = "cow-and-the-" },
            .{ .operation = .equal, .owned = false, .text = "cat." },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "ax" },
        },
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "aax" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "xa" },
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .equal, .owned = false, .text = "a" },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "xaa" },
            .{ .operation = .delete, .owned = false, .text = "a" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemanticLossless, .{TestIO{
        .input = &.{
            .{ .operation = .equal, .owned = false, .text = "The xxx. The " },
            .{ .operation = .insert, .owned = false, .text = "zzz. The " },
            .{ .operation = .equal, .owned = false, .text = "yyy." },
        },
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "The xxx." },
            .{ .operation = .insert, .owned = false, .text = " The zzz." },
            .{ .operation = .equal, .owned = false, .text = " The yyy." },
        },
    }});
}

fn rebuildtexts(allocator: std.mem.Allocator, diffs: DiffList) ![2][]const u8 {
    var text = [2]ArrayList(u8){
        ArrayList(u8).init(allocator),
        ArrayList(u8).init(allocator),
    };
    errdefer {
        text[0].deinit();
        text[1].deinit();
    }

    for (diffs.items) |a_diff| {
        if (a_diff.operation != .insert) try text[0].appendSlice(a_diff.text);
        if (a_diff.operation != .delete) try text[1].appendSlice(a_diff.text);
    }
    const before = try text[0].toOwnedSlice();
    errdefer allocator.free(before);
    return .{ before, try text[1].toOwnedSlice() };
}

const TRebuild = struct {
    before: []const u8,
    after: []const u8,
};

fn testRebuildTexts(allocator: Allocator, diffs: DiffList, params: TRebuild) !void {
    const texts = try rebuildtexts(allocator, diffs);
    defer {
        allocator.free(texts[0]);
        allocator.free(texts[1]);
    }
    try testing.expectEqualStrings(params.before, texts[0]);
    try testing.expectEqualStrings(params.after, texts[1]);
}

test rebuildtexts {
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .insert, .owned = false, .text = "abcabc" },
            .{ .operation = .equal, .owned = false, .text = "defdef" },
            .{ .operation = .delete, .owned = false, .text = "ghighi" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testRebuildTexts, .{
            diffs,
            TRebuild{ .before = "defdefghighi", .after = "abcabcdefdef" },
        });
    }
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .insert, .owned = false, .text = "xxx" },
            .{ .operation = .delete, .owned = false, .text = "yyy" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testRebuildTexts, .{
            diffs,
            TRebuild{ .before = "yyy", .after = "xxx" },
        });
    }
    {
        var diffs = try sliceToDiffList(testing.allocator, &.{
            .{ .operation = .equal, .owned = false, .text = "xyz" },
            .{ .operation = .equal, .owned = false, .text = "pdq" },
        });
        defer deinitDiffList(testing.allocator, &diffs);
        try testing.checkAllAllocationFailures(testing.allocator, testRebuildTexts, .{
            diffs,
            TRebuild{ .before = "xyzpdq", .after = "xyzpdq" },
        });
    }
}

const TBisect = struct {
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
    deadline: u64,
    expected: []const Edit,
};

fn testDiffBisect(
    allocator: std.mem.Allocator,
    params: TBisect,
) !void {
    var diffs = try diffBisectConfig(params.config, allocator, params.before, params.after, params.deadline);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

test "diffBisect" {
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 0;
        break :blk config;
    };
    try testing.checkAllAllocationFailures(testing.allocator, testDiffBisect, .{TBisect{
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
    try testing.checkAllAllocationFailures(testing.allocator, testDiffBisect, .{TBisect{
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

const TDiff = struct {
    config: DiffConfig,
    before: []const u8,
    after: []const u8,
    expected: []const Edit,
};

fn testDiff(
    allocator: std.mem.Allocator,
    params: TDiff,
) !void {
    var diffs = try diffListFromConfig(allocator, params.config, params.before, params.after);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

test "diff" {
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.timeout = 0;
        config.check_lines = false;
        break :blk config;
    };

    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .config = config,
        .before = "",
        .after = "",
        .expected = &[_]Edit{},
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .config = config,
        .before = "abc",
        .after = "abc",
        .expected = &.{.{ .operation = .equal, .owned = false, .text = "abc" }},
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .config = config,
        .before = "abc",
        .after = "ab123c",
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "ab" },
            .{ .operation = .insert, .owned = false, .text = "123" },
            .{ .operation = .equal, .owned = false, .text = "c" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .config = config,
        .before = "a123bc",
        .after = "abc",
        .expected = &.{
            .{ .operation = .equal, .owned = false, .text = "a" },
            .{ .operation = .delete, .owned = false, .text = "123" },
            .{ .operation = .equal, .owned = false, .text = "bc" },
        },
    }});

    try testing.checkAllAllocationFailures(testing.allocator, testDiff, .{TDiff{
        .config = config,
        .before = "a",
        .after = "b",
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "b" },
        },
    }});
}

fn testDiffLineMode(
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
    var diff_checked = try diffListFromConfig(allocator, checked_config, before, after);
    defer deinitDiffList(allocator, &diff_checked);

    var unchecked_config = checked_config;
    unchecked_config.check_lines = false;
    var diff_unchecked = try diffListFromConfig(allocator, unchecked_config, before, after);
    defer deinitDiffList(allocator, &diff_unchecked);

    try testing.expectEqualDeep(diff_checked.items, diff_unchecked.items);
}

test "diffLineMode" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffLineMode,
        .{
            @as(u32, 20),
            "1234567890\n1234567890\n1234567890",
            "abcdefghij\nabcdefghij\nabcdefghij",
        },
    );
}

fn diffRoundTrip(allocator: Allocator, config: DiffConfig, diff_slice: []const Edit) !void {
    var diffs_before = try DiffList.initCapacity(allocator, diff_slice.len);
    defer deinitDiffList(allocator, &diffs_before);
    for (diff_slice) |item| {
        diffs_before.appendAssumeCapacity(.{ .operation = item.operation, .owned = true, .text = try allocator.dupe(u8, item.text) });
    }
    const text_before = try diffBeforeText(allocator, diffs_before);
    defer allocator.free(text_before);
    const text_after = try diffAfterText(allocator, diffs_before);
    defer allocator.free(text_after);
    var diffs_after = try diffListFromConfig(allocator, config, text_before, text_after);
    defer deinitDiffList(allocator, &diffs_after);
    try diffCleanupSemantic(allocator, &diffs_after);
    try expectEqualDiff(diffs_before.items, diffs_after.items);
}

test "Unicode diffs" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        cfg.check_lines = false;
        break :blk cfg;
    };
    const roundtrip_config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        cfg.check_lines = false;
        break :blk cfg;
    };
    {
        var greek_diff = try diffListFromConfig(allocator, config, "αβγ", "αβδ");
        defer deinitDiffList(allocator, &greek_diff);
        try expectEqualDiff(@as([]const Edit, &.{
            Edit.asBorrow(.equal, "αβ"),
            Edit.asBorrow(.delete, "γ"),
            Edit.asBorrow(.insert, "δ"),
        }), greek_diff.items);
    }
    try testing.checkAllAllocationFailures(
        allocator,
        diffRoundTrip,
        .{ roundtrip_config, &[_]Edit{
            .{ .operation = .equal, .owned = false, .text = "😹💋" },
            .{ .operation = .delete, .owned = false, .text = "\xf0\x9f\xa5\xb9" },
            .{ .operation = .insert, .owned = false, .text = "\xf0\x9f\xa5\xb4" },
            .{ .operation = .equal, .owned = false, .text = "👀🫵" },
        } },
    );
}

test "Diff format" {
    const a_diff: Edit = .{ .operation = .insert, .owned = false, .text = "add me" };
    const expect = "(+, \"add me\")";
    var out_buf: [13]u8 = undefined;
    const out_string = try std.fmt.bufPrint(&out_buf, "{f}", .{a_diff});
    try testing.expectEqualStrings(expect, out_string);
}

fn testDiffCleanupSemantic(
    allocator: std.mem.Allocator,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .owned = true, .text = try allocator.dupe(u8, item.text) });
    }

    try diffCleanupSemantic(allocator, &diffs);
    try testing.expectEqualDeep(params.expected, diffs.items);
}

test diffCleanupSemantic {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{},
        .expected = &[_]Edit{},
    }});
}

fn testDiffCleanupEfficiency(
    allocator: Allocator,
    config: DiffConfig,
    params: TestIO,
) !void {
    var diffs = try DiffList.initCapacity(allocator, params.input.len);
    defer deinitDiffList(allocator, &diffs);
    for (params.input) |item| {
        diffs.appendAssumeCapacity(.{ .operation = item.operation, .text = try allocator.dupe(u8, item.text) });
    }
    try diffCleanupEfficiencyConfig(config, allocator, &diffs);
    try testing.expectEqualDeep(params.expected, diffs.items);
}

test "diffCleanupEfficiency" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.edit_cost = 4;
        break :blk config;
    };
    var diffs: DiffList = .empty;
    try diffCleanupEfficiencyConfig(config, allocator, &diffs);
    try testing.expectEqualDeep(DiffList.empty, diffs);
}

test "diff before and after text" {
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.check_lines = false;
        break :blk config;
    };
    const allocator = testing.allocator;
    const before = "The cat in the hat.";
    const after = "The bat in the belfry.";
    var diffs = try diffListFromConfig(allocator, config, before, after);
    defer deinitDiffList(allocator, &diffs);
    const before1 = try diffBeforeText(allocator, diffs);
    defer allocator.free(before1);
    const after1 = try diffAfterText(allocator, diffs);
    defer allocator.free(after1);
    try testing.expectEqualStrings(before, before1);
    try testing.expectEqualStrings(after, after1);
}

test diffIndex {
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.check_lines = false;
        break :blk config;
    };
    var diffs = try diffListFromConfig(testing.allocator, config, "The midnight train", "The blue midnight train");
    defer deinitDiffList(testing.allocator, &diffs);
    try testing.expectEqual(0, diffIndex(diffs, 0));
    try testing.expectEqual(9, diffIndex(diffs, 4));
}

test diffPrettyFormat {
    const test_deco = DiffDecorations{
        .delete_start = "<+>",
        .delete_end = "</+>",
        .insert_start = "<->",
        .insert_end = "</->",
        .equals_start = "<=>",
        .equals_end = "</=>",
    };
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.check_lines = false;
        break :blk config;
    };
    const allocator = testing.allocator;
    var diffs = try diffListFromConfig(allocator, config, "A thing of beauty is a joy forever", "Singular beauty is enjoyed forever");
    defer deinitDiffList(allocator, &diffs);
    try diffCleanupSemantic(allocator, &diffs);
    const out_text = try diffPrettyFormat(allocator, diffs, test_deco);
    defer allocator.free(out_text);
    try testing.expectEqualStrings(
        "<+>A thing of</+><->Singular</-><=> beauty is </=><+>a </+><->en</-><=>joy</=><->ed</-><=> forever</=>",
        out_text,
    );
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.array_list.Managed;
const assert = std.debug.assert;
const testing = std.testing;

const dmp = @import("../dmp.zig");
const common = @import("common.zig");
