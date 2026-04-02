//! Diff represents the difference between two texts.
//!
//! A `Diff` owns a `DiffList` of `Edit` values and provides the diff-specific
//! operations over that list, including diff generation, cleanup passes, and
//! readback helpers such as pretty formatting and text reconstruction.
//!
//! `Diff` has several configurable parameters.  Use `.default` for the default
//! configuration, or `.init(cfg)` to provide a custom `DiffConfig`. Release
//! when finished with `diff.deinit(allocator)`.
//!
//! `DiffConfig` controls how the diff is produced:
//! - `timeout` is the maximum number of milliseconds to spend computing a diff;
//!   `0` means no timeout.
//! - `edit_cost` tunes the efficiency cleanup heuristics.
//! - `check_lines` enables the initial line-mode speedup for large inputs.
//! - `check_line_threshold` sets the minimum input size for that speedup.
//!
//! The diff object starts empty.  To populate it with a diff:
//!
//!     try diff.diff(allocator, before, after);
//!
//! The diffing algorithm only allocates memory when it has to, so most of a
//! typical diff will consist of views into the compared strings.  These must
//! therefore stay in memory, or at your option, you may call `.own(allocator)`
//! to own that memory.
//!

/// The configurable parameters for a Diff object.
pub const DiffConfig = struct {
    /// Number of milliseconds to map a diff before giving up (0 for infinity).
    timeout: u64,
    /// Cost of an empty edit operation in terms of edit characters.  Higher
    /// values lead to fewer, larger edit chunks.
    edit_cost: u16,
    /// If true, use the initial line-mode speedup when inputs are large enough.
    /// This is generally faster, but can result in non-minimal diffs.
    check_lines: bool,
    /// Number of bytes in each string needed to trigger a line-based diff.
    /// Ignored if check_lines is `false`.
    check_line_threshold: u32,

    /// Reasonable defaults for diffing: a five second timeout, use of
    /// line mode in most cases (4K strings), an edit cost which prevents
    /// most chaff.
    pub const default: DiffConfig = .{
        .timeout = 5000,
        .edit_cost = 4,
        .check_lines = true,
        .check_line_threshold = 4096,
    };
};

const ZDeltaVersion = zdelta_mod.ZDeltaVersion;
pub const ZDeltaError = zdelta_mod.ZDeltaError;

/// A single edit of a diff: insertion, deletion, or neither.
pub const Edit = struct {
    operation: Operation,
    owned: bool,
    text: []const u8,

    pub const Operation = enum(u2) {
        insert,
        delete,
        equal,
    };

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

    /// Create an Edit with the provided ownership status
    pub fn asBool(allocator: Allocator, operation: Operation, owned: bool, text: []const u8) OOM!Edit {
        if (owned)
            return Edit.asOwn(allocator, operation, text)
        else
            return Edit.asBorrow(operation, text);
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

    /// Copy the Edit.  An owned Edit will copy its text, a borrowed
    /// Edit will continue to be borrowed.
    pub fn copy(edit: *const Edit, allocator: Allocator) !Edit {
        if (edit.owned) {
            return edit.clone(allocator);
        } else {
            return edit.*;
        }
    }

    /// Clone the edit.  The returned edit will always own a copy
    /// of the text.
    pub fn clone(edit: *const Edit, allocator: Allocator) !Edit {
        return Edit{
            .operation = edit.operation,
            .owned = true,
            // Clone must own an independent copy of the edit text.
            .text = try allocator.dupe(u8, edit.text),
        };
    }

    /// Format the Edit in a debug-and-test useful fashion.
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
};

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
    d_ws_start: []const u8 = "",
    d_ws_end: []const u8 = "",
    insert_start: []const u8 = "",
    i_ws_start: []const u8 = "",
    i_ws_end: []const u8 = "",
    insert_end: []const u8 = "",
    equals_start: []const u8 = "",
    equals_end: []const u8 = "",
    pre_process: ?fn (Allocator, Edit) OOM![]const u8 = null,

    /// Decorations for classic Xterm printing: red for delete and
    /// green for insert.
    pub const xterm_classic: DiffDecorations = .{
        .delete_start = "\x1b[91m",
        .delete_end = "\x1b[m",
        .d_ws_start = "\x1b[48;2;64;28;28m",
        .d_ws_end = "\x1b[49m",
        .insert_start = "\x1b[92m",
        .i_ws_start = "\x1b[48;2;28;64;28m",
        .i_ws_end = "\x1b[49m",
        .insert_end = "\x1b[m",
    };
};

pub const Diff = struct {
    /// The diff configuration, see `DiffConfig`
    config: DiffConfig = .default,
    /// An ArrayList of the individual `Edit`s in this diff.
    edits: DiffList = .empty,

    pub const default: Diff = .{
        .config = .default,
        .edits = .empty,
    };

    /// Initialize an empty `Diff` with the provided `DiffConfig`.
    pub fn init(config: DiffConfig) Diff {
        return .{ .config = config };
    }

    /// Own all edits in the Diff.  After this operation it is safe
    /// to dispose of the original strings.
    pub fn own(difference: *Diff, allocator: Allocator) OOM!Diff {
        for (difference.edits.items) |*e| {
            try e.own(allocator);
        }
    }

    /// Clone this `Diff`, including its owned edits.  The clone is
    /// fully-owned, the ownership in the original does not change.
    pub fn clone(difference: *const Diff, allocator: Allocator) OOM!Diff {
        return .{
            .config = difference.config,
            .edits = try cloneDiffList(allocator, &difference.edits),
        };
    }

    /// Make a copy of the Diff.  Each Edit in the new copy will have the
    /// same ownership status as that of the original.
    pub fn copy(difference: *const Diff, allocator: Allocator) OOM!Diff {
        return .{
            .config = difference.config,
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
        difference.edits = try diffImpl(difference.config, allocator, before, after);
        return difference;
    }

    pub fn diffLines(
        difference: *Diff,
        allocator: Allocator,
        before: []const u8,
        after: []const u8,
    ) OOM!*Diff {
        if (difference.edits.items.len != 0) {
            deinitDiffList(allocator, &difference.edits);
            difference.edits = .empty;
        }
        difference.edits = try diffLine(difference.config, allocator, before, after, std.math.maxInit(u64));
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
        try diffCleanupEfficiency(difference.config, allocator, &difference.edits);
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

    /// Create a Patch from the Diff with the default PatchOptions.
    pub fn toPatch(difference: *const Diff, allocator: Allocator) OOM!Patch {
        var the_patch: Patch = .default;
        return the_patch.fromDiff(allocator, difference);
    }

    /// Create a Patch from the Diff with the provided PatchOptions.
    pub fn toPatchConfig(
        difference: *const Diff,
        allocator: Allocator,
        cfg: PatchConfig,
    ) OOM!Patch {
        var the_patch: Patch = .init(cfg);
        return the_patch.fromDiff(allocator, difference);
    }

    /// Write a Diff in a zDelta format.  Currently supported are
    /// formats `.a` and `.b`, see documentation for more details.
    pub fn toZDelta(
        difference: *const Diff,
        allocator: Allocator,
        version: ZDeltaVersion,
    ) ZDeltaError![]const u8 {
        return zdelta_mod.encode(allocator, difference.edits, version);
    }

    /// Populate a Diff from a zDelta string and the before text.
    pub fn fromZDelta(
        difference: *Diff,
        allocator: Allocator,
        before: []const u8,
        zdelta: []const u8,
    ) ZDeltaError!*Diff {
        var edits = try zdelta_mod.toDiffList(Edit, DiffList, allocator, before, zdelta);
        errdefer deinitDiffList(allocator, &edits);
        if (difference.edits.items.len != 0) {
            deinitDiffList(allocator, &difference.edits);
        }
        difference.edits = edits;
        return difference;
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

    /// Answers the number of bytes total be added or removed by
    /// applying this diff, in other words, the difference in length
    /// between the before and after texts.
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
};

/// File-public, not module-public.  Just a synonym in any case.
pub const DiffList = ArrayListUnmanaged(Edit);

//| Private

const HalfMatchResult = struct {
    prefix_before: []const u8,
    suffix_before: []const u8,
    prefix_after: []const u8,
    suffix_after: []const u8,
    common_middle: []const u8,
};

/// Used to not choose control codes in line-mode diffing.  This is of
/// some minor use during debugging, but really not a big deal one way
/// or the other.
const CHAR_OFFSET = 32;

/// Free all memory of the ArrayList of Edits in a Diff.
const deinitDiffList = common.deinitDiffList;

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
fn diffImpl(
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
        diffs.insertAssumeCapacity(0, Edit.asBorrow(
            .equal,
            common_prefix,
        ));
    }
    if (common_suffix.len != 0) {
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .equal,
            common_suffix,
        ));
    }
    try diffCleanupMerge(allocator, &diffs);
    return diffs;
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
        const op: Edit.Operation = if (before.len > after.len)
            .delete
        else
            .insert;
        const equal_text = if (before.len > after.len)
            before[match_index..][0..short_text.len]
        else
            short_text;
        try diffs.ensureUnusedCapacity(allocator, 3);
        diffs.appendAssumeCapacity(Edit.asBorrow(
            op,
            long_text[0..match_index],
        ));
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .equal,
            equal_text,
        ));
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
        try diffs.ensureUnusedCapacity(allocator, 2);
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .delete,
            before,
        ));
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
            after,
        ));
        return diffs;
    }

    // Check to see if the problem can be split in two.
    var maybe_half_match = try diffHalfMatch(config, allocator, before, after);
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
            for (diffs_b.items) |*edit| {
                edit.deinit(allocator);
            }
        }

        // Merge the results.
        try diffs.ensureUnusedCapacity(allocator, 1);
        diffs.appendAssumeCapacity(
            Edit.asBorrow(.equal, half_match.common_middle),
        );
        half_match.common_middle = "";
        try diffs.appendSlice(allocator, diffs_b.items);
        return diffs;
    }

    if (config.check_lines and before.len > config.check_line_threshold and after.len > config.check_line_threshold) {
        return diffLineMode(config, allocator, before, after, deadline);
    }
    return diffBisect(config, allocator, before, after, deadline);
}

fn diffHalfMatch(
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
    // Check again based on the third quarter.
    const half_match_2 = try diffHalfMatchInternal(allocator, long_text, short_text, (long_text.len + 1) / 2);

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
                break :half half_match_1;
            } else {
                break :half half_match_2;
            }
        };
    }

    // A half-match was found, sort out the return data.
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
        // Transfers ownership of all memory to new, permuted, half_match.
        const half_match_yes = half_match.?;
        return .{
            .prefix_before = half_match_yes.prefix_after,
            .suffix_before = half_match_yes.suffix_after,
            .prefix_after = half_match_yes.prefix_before,
            .suffix_after = half_match_yes.suffix_before,
            .common_middle = before[half_match_yes.prefix_after.len .. before.len - half_match_yes.suffix_after.len],
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
            .prefix_before = best_long_text_a,
            .suffix_before = best_long_text_b,
            .prefix_after = best_short_text_a,
            .suffix_after = best_short_text_b,
            .common_middle = best_common,
        };
    } else {
        return null;
    }
}

fn diffBisect(
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
        before,
    ));
    diffs.appendAssumeCapacity(Edit.asBorrow(
        .insert,
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
            text1b,
        ));
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
            text2b,
        ));
        return diffs;
    } else if (text1b.len == 0 and text2b.len == 0) {
        var diffs: DiffList = .empty;
        errdefer deinitDiffList(allocator, &diffs);
        try diffs.ensureUnusedCapacity(allocator, 2);
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .delete,
            text1a,
        ));
        diffs.appendAssumeCapacity(Edit.asBorrow(
            .insert,
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
        for (diffs_b.items) |*edit| {
            edit.deinit(allocator);
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
    var diffs = try diffLine(config, allocator, text1_in, text2_in, deadline);
    errdefer deinitDiffList(allocator, &diffs);
    return diffLineCleanup(&diffs, config, allocator, text1_in, text2_in, deadline);
}

/// Perform only the line-based diff speedup, returning what we get.
fn diffLine(
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
        break :diff_munge try diffCharsToLines(allocator, &char_diffs, line_array.items, text1_in, text2_in);
    };
    errdefer deinitDiffList(allocator, &diffs);
    // Eliminate freak matches (e.g. blank lines)
    // TODO: This happens to pass the tests without triggering any
    // assertions, but that seems very brittle.  More investigation
    // is needed.
    try diffCleanupSemantic(allocator, &diffs);
    return diffs;
}

fn diffLineCleanup(
    diffs: *DiffList,
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
    // Rediff any replacement blocks, this time character-by-character.
    // Add a dummy entry at the end, to trigger a final sub-diff if needed.
    try diffs.append(allocator, Edit.asBorrow(.equal, ""));

    // Here we collect deletes and inserts, and stop after any .equal to
    // run a character diff on the lines.  Any two deletes are contiguous
    // unless separated by an equal, and likewise with inserts, so here
    // again we just add lengths to a base pointer.
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
                if (count_insert == 1) {
                    insert_run = text;
                } else {
                    dbgassert(insert_run.ptr + insert_run.len == text.ptr); // kcov-miss
                    insert_run = insert_run.ptr[0 .. insert_run.len + text.len];
                }
            },
            .delete => {
                count_delete += 1;
                const text = diffs.items[pointer].text;
                if (count_delete == 1) {
                    delete_run = text;
                } else {
                    dbgassert(delete_run.ptr + delete_run.len == text.ptr); // kcov-miss
                    delete_run = delete_run.ptr[0 .. delete_run.len + text.len];
                }
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete >= 1 and count_insert >= 1) {
                    // Delete the offending records and add the merged ones.
                    const run_start = pointer - count_delete - count_insert;
                    var before_cursor: usize = 0;
                    var after_cursor: usize = 0;
                    for (diffs.items[0..run_start]) |edit| {
                        if (edit.operation != .insert) before_cursor += edit.text.len;
                        if (edit.operation != .delete) after_cursor += edit.text.len;
                    }
                    var sub_diff = try diffInternal(
                        text_mode_config,
                        allocator,
                        delete_run,
                        insert_run,
                        deadline,
                    );
                    {
                        errdefer deinitDiffList(allocator, &sub_diff);
                        try diffs.ensureUnusedCapacity(allocator, sub_diff.items.len);
                    }
                    try diffRebindToSourceTexts(
                        allocator,
                        &sub_diff,
                        text1_in,
                        text2_in,
                        before_cursor,
                        after_cursor,
                    );
                    freeRangeDiffList(
                        allocator,
                        diffs,
                        run_start,
                        count_delete + count_insert,
                    );
                    try diffs.replaceRange(
                        allocator,
                        run_start,
                        count_delete + count_insert,
                        &.{},
                    );
                    pointer = run_start;
                    defer sub_diff.deinit(allocator);
                    const new_diff = diffs.addManyAtAssumeCapacity(pointer, sub_diff.items.len);
                    @memcpy(new_diff, sub_diff.items);
                    pointer = pointer + sub_diff.items.len;
                }
                count_insert = 0;
                count_delete = 0;
                delete_run = "";
                insert_run = "";
            },
        }
    }
    diffs.items.len -= 1; // Remove the dummy entry at the end.

    // TODO: calling this, here, breaks things.  This is itself a problem.
    // try diffCleanupSemantic(allocator, &diffs);
    return diffs.*;
}

fn diffRebindToSourceTexts(
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
    dbgassert(max_segments <= UNICODE_MAX);
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
/// of text.  The line_array deduplicates lines, by the nature of a hash map,
/// and we want to stick to borrows, so we coalesce the lines we find as views
/// into the original text.  The identity is asserted in debug mode, in
/// production code it's simply arithmetic.
fn diffCharsToLines(
    allocator: Allocator,
    char_diffs: *DiffList,
    line_array: []const []const u8,
    before_text: []const u8,
    after_text: []const u8,
) OOM!DiffList {
    var text = ArrayListUnmanaged(u8){};
    defer text.deinit(allocator);
    var diffs: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diffs);
    try diffs.ensureUnusedCapacity(allocator, char_diffs.items.len);
    var before_cursor: usize = 0;
    var after_cursor: usize = 0;
    for (char_diffs.items) |*edit| {
        var cursor: usize = 0;
        while (cursor < edit.text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(edit.text[cursor]) catch {
                @panic("Internal decode error in diffsCharsToLines");
            };
            const cp = std.unicode.wtf8Decode(edit.text[cursor..][0..cp_len]) catch {
                @panic("Internal decode error in diffCharsToLines");
            };
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

fn diffCleanupMerge(allocator: std.mem.Allocator, diffs: *DiffList) OOM!void {
    // Add a dummy entry at the end.
    try diffs.append(allocator, Edit.asBorrow(.equal, ""));
    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;

    var delete_run = ArrayListUnmanaged(*const Edit){};
    defer delete_run.deinit(allocator);

    var insert_run = ArrayListUnmanaged(*const Edit){};
    defer insert_run.deinit(allocator);

    while (pointer < diffs.items.len) {
        switch (diffs.items[pointer].operation) {
            .insert => {
                count_insert += 1;
                dbgassert(pointer < diffs.items.len);
                try insert_run.append(allocator, &diffs.items[pointer]);
                pointer += 1;
            },
            .delete => {
                count_delete += 1;
                try delete_run.append(allocator, &diffs.items[pointer]);
                pointer += 1;
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete + count_insert > 1) {
                    const all_borrowed = diffRunAllBorrowed(delete_run.items) and
                        diffRunAllBorrowed(insert_run.items);
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
                    const must_own = owned_insert != null or
                        owned_delete != null or
                        diffs.items[pointer].owned or
                        ((pointer - count_delete - count_insert) > 0 and
                            diffs.items[pointer - count_delete - count_insert - 1].owned);
                    if (count_delete != 0 and count_insert != 0) {
                        // Factor out any common prefixes.
                        var common_length: usize = diffCommonPrefix(text_insert, text_delete);
                        if (common_length != 0) {
                            if ((pointer - count_delete - count_insert) > 0 and
                                diffs.items[pointer - count_delete - count_insert - 1].operation == .equal)
                            { // The prefix is not at the start of the diffs
                                const ii = pointer - count_delete - count_insert - 1;
                                const old_equal = diffs.items[ii];
                                if (!must_own and
                                    !old_equal.owned and
                                    old_equal.text.ptr + old_equal.text.len == text_delete.ptr)
                                {
                                    diffs.items[ii] = Edit.asBorrow(
                                        .equal,
                                        old_equal.text.ptr[0 .. old_equal.text.len + common_length],
                                    );
                                } else {
                                    diffs.items[ii] = try diffMakeOwnedConcat2(
                                        Edit,
                                        allocator,
                                        .equal,
                                        old_equal.text,
                                        text_delete[0..common_length],
                                    );
                                    var equal_to_deinit = old_equal;
                                    equal_to_deinit.deinit(allocator);
                                }
                            } else {
                                try diffs.ensureUnusedCapacity(allocator, 1);
                                diffs.insertAssumeCapacity(
                                    0,
                                    try Edit.asBool(allocator, .equal, must_own, text_delete[0..common_length]),
                                );
                                pointer += 1;
                            }
                            text_insert = text_insert[common_length..];
                            text_delete = text_delete[common_length..];
                        }
                        // Factor out any common suffices.
                        // @ZigPort this seems very wrong
                        common_length = diffCommonSuffix(text_insert, text_delete);
                        if (common_length != 0) {
                            const old_edit = diffs.items[pointer];
                            if (!must_own and
                                !old_edit.owned and
                                text_delete.ptr + text_delete.len - common_length == old_edit.text.ptr)
                            {
                                unreachable; // This should be structurally impossible. If it isn't? I want that input!
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
                    // Delete the offending records and add the merged ones.
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
                        diffs.insertAssumeCapacity(
                            pointer,
                            try Edit.asBool(allocator, .delete, must_own, text_delete),
                        );
                        pointer += 1;
                    }
                    if (text_insert.len != 0) {
                        try diffs.ensureUnusedCapacity(allocator, 1);
                        diffs.insertAssumeCapacity(
                            pointer,
                            try Edit.asBool(allocator, .insert, must_own, text_insert),
                        );
                        pointer += 1;
                    }
                    pointer += 1;
                } else if (pointer != 0 and diffs.items[pointer - 1].operation == .equal) {
                    // Merge this equality with the previous one.
                    const old_prev = diffs.items[pointer - 1];
                    const old_curr = diffs.items[pointer];
                    if (!old_prev.owned and
                        !old_curr.owned and
                        old_prev.text.ptr + old_prev.text.len == old_curr.text.ptr)
                    {
                        diffs.items[pointer - 1] = Edit.asBorrow(
                            .equal,
                            old_prev.text.ptr[0 .. old_prev.text.len + old_curr.text.len],
                        );
                    } else {
                        diffs.items[pointer - 1] = try diffMakeOwnedConcat2(
                            Edit,
                            allocator,
                            .equal,
                            old_prev.text,
                            old_curr.text,
                        );
                        var prev_to_deinit = old_prev;
                        prev_to_deinit.deinit(allocator);
                    }
                    const dead_diff = diffs.orderedRemove(pointer);
                    var dead = dead_diff;
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
    var last_equality: ?Edit = null;
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
            last_equality = diffs.items[pointer];
        } else { // an insertion or deletion
            if (diffs.items[pointer].operation == .insert) {
                length_insertions2 += diffs.items[pointer].text.len;
            } else {
                length_deletions2 += diffs.items[pointer].text.len;
            }
            // Eliminate an equality that is smaller or equal to the edits on both
            // sides of it.
            if (last_equality != null and
                (last_equality.?.text.len <= @max(length_insertions1, length_deletions1)) and
                (last_equality.?.text.len <= @max(length_insertions2, length_deletions2)))
            {
                // Duplicate record.
                const the_eq = last_equality.?;
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(
                    equalities.items[equalities.items.len - 1],
                    try Edit.asBool(allocator, .delete, the_eq.owned, the_eq.text),
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
                    // Overlap found.
                    // Insert an equality and trim the surrounding edits.
                    try diffs.ensureUnusedCapacity(allocator, 1);
                    diffs.insertAssumeCapacity(
                        pointer,
                        try Edit.asBool(
                            allocator,
                            .equal,
                            delete_edit.owned,
                            deletion[deletion.len - overlap_length1 ..],
                        ),
                    );
                    var new_minus = try Edit.asBool(
                        allocator,
                        .delete,
                        delete_edit.owned,
                        deletion[0 .. deletion.len - overlap_length1],
                    );
                    errdefer new_minus.deinit(allocator);
                    const new_plus = try Edit.asBool(
                        allocator,
                        .insert,
                        insert_edit.owned,
                        insertion[overlap_length1..],
                    );
                    var delete_to_deinit = delete_edit;
                    delete_to_deinit.deinit(allocator);
                    var insert_to_deinit = insert_edit;
                    insert_to_deinit.deinit(allocator);
                    diffs.items[pointer - 1] = new_minus;
                    diffs.items[pointer + 1] = new_plus;
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
                        try Edit.asBool(allocator, .equal, delete_edit.owned, deletion[0..overlap_length2]),
                    );
                    var new_minus = try Edit.asBool(
                        allocator,
                        .insert,
                        insert_edit.owned,
                        insertion[0 .. insertion.len - overlap_length2],
                    );
                    errdefer new_minus.deinit(allocator);
                    const new_plus = try Edit.asBool(
                        allocator,
                        .delete,
                        delete_edit.owned,
                        deletion[overlap_length2..],
                    );
                    var delete_to_deinit = delete_edit;
                    delete_to_deinit.deinit(allocator);
                    var insert_to_deinit = insert_edit;
                    insert_to_deinit.deinit(allocator);
                    diffs.items[pointer - 1] = new_minus;
                    diffs.items[pointer + 1] = new_plus;
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
    while (pointer < u2i(diffs.items.len) - 1) {
        if (diffs.items[pointer - 1].operation == .equal and
            diffs.items[pointer + 1].operation == .equal)
        {
            if (diffCleanupSemanticLosslessWindow(diffs, pointer)) |window| {
                diffCleanupSemanticLosslessBorrowed(diffs, &pointer, window);
            } else {
                try diffCleanupSemanticLosslessOwned(allocator, diffs, &pointer);
            }
        }
        pointer += 1;
    }
}

const BorrowedLosslessWindow = struct {
    equality_1: []const u8,
    edit: []const u8,
    equality_2: []const u8,
};

fn canBorrowLosslessWindow(
    equality_1: []const u8,
    edit: []const u8,
    equality_2: []const u8,
) bool {
    return equality_1.ptr + equality_1.len == edit.ptr and
        edit.ptr + edit.len == equality_2.ptr;
}

fn deriveBorrowedLosslessWindow(
    equality_1: []const u8,
    edit: []const u8,
    equality_2: []const u8,
) ?BorrowedLosslessWindow {
    if (canBorrowLosslessWindow(equality_1, edit, equality_2)) {
        return .{
            .equality_1 = equality_1,
            .edit = edit,
            .equality_2 = equality_2,
        };
    }

    const derived_equality_1 = (edit.ptr - equality_1.len)[0..equality_1.len];
    const derived_equality_2 = (edit.ptr + edit.len)[0..equality_2.len];
    if (!std.mem.eql(u8, derived_equality_1, equality_1) or
        !std.mem.eql(u8, derived_equality_2, equality_2))
    {
        return null;
    }

    return .{
        .equality_1 = derived_equality_1,
        .edit = edit,
        .equality_2 = derived_equality_2,
    };
}

fn diffCleanupSemanticLosslessWindow(
    diffs: *const DiffList,
    pointer: usize,
) ?BorrowedLosslessWindow {
    const equality_1 = diffs.items[pointer - 1];
    const edit = diffs.items[pointer];
    const equality_2 = diffs.items[pointer + 1];
    if (equality_1.owned or edit.owned or equality_2.owned) return null;

    return switch (edit.operation) {
        .insert, .delete => deriveBorrowedLosslessWindow(
            equality_1.text,
            edit.text,
            equality_2.text,
        ),
        .equal => null,
    };
}

fn diffCleanupSemanticLosslessOwned(
    allocator: std.mem.Allocator,
    diffs: *DiffList,
    pointer: *usize,
) OOM!void {
    // This is a single edit surrounded by equalities.
    var equality_1 = std.ArrayListUnmanaged(u8){};
    defer equality_1.deinit(allocator);
    try equality_1.appendSlice(allocator, diffs.items[pointer.* - 1].text);

    var edit = std.ArrayListUnmanaged(u8){};
    defer edit.deinit(allocator);
    try edit.appendSlice(allocator, diffs.items[pointer.*].text);

    var equality_2 = std.ArrayListUnmanaged(u8){};
    defer equality_2.deinit(allocator);
    try equality_2.appendSlice(allocator, diffs.items[pointer.* + 1].text);

    // First, shift the edit as far left as possible.
    const common_offset = diffCommonSuffix(equality_1.items, edit.items);
    if (common_offset > 0) {
        const common_string = try allocator.dupe(u8, edit.items[edit.items.len - common_offset ..]);
        defer allocator.free(common_string);

        equality_1.items.len = equality_1.items.len - common_offset;

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

    while (hasSharedPrefixLen(edit.items, equality_2.items)) |cp_len| {
        var cp_buf: [4]u8 = undefined;
        @memcpy(cp_buf[0..cp_len], edit.items[0..cp_len]);
        try equality_1.appendSlice(allocator, cp_buf[0..cp_len]);

        std.mem.copyForwards(u8, edit.items[0 .. edit.items.len - cp_len], edit.items[cp_len..]);
        edit.items.len -= cp_len;
        try edit.appendSlice(allocator, equality_2.items[0..cp_len]);

        std.mem.copyForwards(u8, equality_2.items[0 .. equality_2.items.len - cp_len], equality_2.items[cp_len..]);
        equality_2.items.len -= cp_len;

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

    if (!std.mem.eql(u8, diffs.items[pointer.* - 1].text, best_equality_1.items)) {
        // We have an improvement, save it back to the diff.
        if (best_equality_1.items.len != 0) {
            const new_diff = try Edit.asOwn(allocator, .equal, best_equality_1.items);
            errdefer comptime unreachable;
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
            errdefer comptime unreachable;
            var old_diff = diffs.items[pointer.*];
            diffs.items[pointer.*] = new_diff;
            old_diff.deinit(allocator);
        }
        if (best_equality_2.items.len != 0) {
            const new_diff = try Edit.asOwn(allocator, .equal, best_equality_2.items);
            errdefer comptime unreachable;
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

fn diffCleanupSemanticLosslessBorrowed(
    diffs: *DiffList,
    pointer: *usize,
    window: BorrowedLosslessWindow,
) void {
    var equality_1 = window.equality_1;
    var edit = window.edit;
    var equality_2 = window.equality_2;

    std.debug.assert(canBorrowLosslessWindow(equality_1, edit, equality_2));

    // First, shift the edit as far left as possible.
    const common_offset = diffCommonSuffix(equality_1, edit);
    if (common_offset > 0) {
        const old_equality_1 = equality_1;
        const old_edit = edit;
        equality_1 = old_equality_1[0 .. old_equality_1.len - common_offset];
        edit = old_equality_1[old_equality_1.len - common_offset ..].ptr[0..old_edit.len];
        equality_2 = old_edit[old_edit.len - common_offset ..].ptr[0 .. equality_2.len + common_offset];
    }

    // Second, step character by character right,
    // looking for the best fit.
    var best_equality_1 = equality_1;
    var best_edit = edit;
    var best_equality_2 = equality_2;

    var best_score = diffCleanupSemanticScore(equality_1, edit) +
        diffCleanupSemanticScore(edit, equality_2);

    while (hasSharedPrefixLen(edit, equality_2)) |cp_len| {
        const old_edit = edit;
        equality_1 = equality_1.ptr[0 .. equality_1.len + cp_len];
        edit = old_edit[cp_len..].ptr[0..old_edit.len];
        equality_2 = equality_2[cp_len..];

        const score = diffCleanupSemanticScore(equality_1, edit) +
            diffCleanupSemanticScore(edit, equality_2);
        // The >= encourages trailing rather than leading whitespace on
        // edits.
        if (score >= best_score) {
            best_score = score;
            best_equality_1 = equality_1;
            best_edit = edit;
            best_equality_2 = equality_2;
        }
    }

    if (!std.mem.eql(u8, diffs.items[pointer.* - 1].text, best_equality_1)) {
        // We have an improvement, save it back to the diff.
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

fn diffCleanupEfficiency(
    config: DiffConfig,
    allocator: std.mem.Allocator,
    diffs: *DiffList,
) OOM!void {
    var changes = false;
    // Stack of indices where equalities are found.
    var equalities = ArrayList(usize).init(allocator);
    defer equalities.deinit();
    // Always equal to equalities[equalitiesLength-1][1]
    var last_equality: ?Edit = null;
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
                last_equality = diffs.items[pointer];
            } else {
                // Not a candidate, and can never become one.
                equalities.items.len = 0;
                last_equality = null;
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
            if ((last_equality != null) and
                ((pre_ins and pre_del and post_ins and post_del) or
                    ((last_equality.?.text.len < config.edit_cost / 2) and
                        (boolInt(pre_ins) + boolInt(pre_del) + boolInt(post_ins) + boolInt(post_del) == 3))))
            {
                // Duplicate record.
                try diffs.ensureUnusedCapacity(allocator, 1);
                diffs.insertAssumeCapacity(
                    equalities.items[equalities.items.len - 1],
                    try Edit.asBool(
                        allocator,
                        .delete,
                        last_equality.?.owned,
                        last_equality.?.text,
                    ),
                );
                // Change second copy to insert.
                diffs.items[equalities.items[equalities.items.len - 1] + 1].operation = .insert;
                _ = equalities.pop(); // Throw away the equality we just deleted.
                last_equality = null;
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
    for (diffs.items) |edit| {
        written += try writeDecoratedEdit(allocator, writer, deco, edit);
    }
    try flushWriter(writer);
    return written;
}

pub fn writeDecoratedEdit(
    allocator: Allocator,
    writer: anytype,
    deco: DiffDecorations,
    edit: Edit,
) !usize {
    const text = if (deco.pre_process) |lambda|
        try lambda(allocator, edit)
    else
        edit.text;
    defer {
        if (deco.pre_process) |_|
            allocator.free(text);
    }

    const markers: struct {
        start: []const u8,
        end: []const u8,
        ws_start: []const u8,
        ws_end: []const u8,
    } = switch (edit.operation) {
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
    written += try writer.write(markers.start);

    if (markers.ws_start.len == 0 or edit.operation == .equal) {
        written += try writer.write(text);
        written += try writer.write(markers.end);
        return written;
    }

    const left_trimmed = std.mem.trimLeft(u8, text, &std.ascii.whitespace);
    const leading_len = text.len - left_trimmed.len;
    if (leading_len != 0) {
        written += try writer.write(markers.ws_start);
        written += try writer.write(text[0..leading_len]);
        written += try writer.write(markers.ws_end);
    }

    const fully_trimmed = std.mem.trimRight(u8, left_trimmed, &std.ascii.whitespace);
    written += try writer.write(fully_trimmed);

    const trailing_len = left_trimmed.len - fully_trimmed.len;
    if (trailing_len != 0) {
        written += try writer.write(markers.ws_start);
        written += try writer.write(left_trimmed[fully_trimmed.len .. fully_trimmed.len + trailing_len]);
        written += try writer.write(markers.ws_end);
    }

    written += try writer.write(markers.end);
    return written;
}

fn flushWriter(writer: anytype) !void {
    if (@hasDecl(@TypeOf(writer), "flush")) {
        var w = writer;
        try w.flush();
    }
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
    const maybe_result = try diffHalfMatch(params.config, allocator, params.before, params.after);
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
    before: []const u8,
    after: []const u8,
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

    var diffs = try diffCharsToLines(allocator, &char_diffs, params.line_array, params.before, params.after);
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
            .before = "alpha\nbeta\nalpha\n",
            .after = "alpha\nbeta\nalpha\nbeta\nalpha\nbeta\n",
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

fn testDiffCleanupMergeBorrowed(params: TestIO) !void {
    var diffs = try DiffList.initCapacity(testing.allocator, params.input.len);
    defer deinitDiffList(testing.allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(Edit.asBorrow(item.operation, item.text));
    }

    try diffCleanupMerge(testing.allocator, &diffs);
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

    {
        const text = "abcdef";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = text[0..1] },
                .{ .operation = .equal, .owned = false, .text = text[1..3] },
                .{ .operation = .equal, .owned = false, .text = text[3..] },
            },
            .expected = &.{.{ .operation = .equal, .owned = false, .text = "abcdef" }},
        });
    }

    {
        const text = "abdc";
        var diffs = try DiffList.initCapacity(testing.allocator, 4);
        defer deinitDiffList(testing.allocator, &diffs);
        diffs.appendAssumeCapacity(Edit.asBorrow(.delete, text[0..1]));
        diffs.appendAssumeCapacity(try Edit.asOwn(testing.allocator, .insert, text[1..2]));
        diffs.appendAssumeCapacity(Edit.asBorrow(.delete, text[2..3]));
        diffs.appendAssumeCapacity(Edit.asBorrow(.equal, text[3..4]));

        try diffCleanupMerge(testing.allocator, &diffs);
        try expectEqualDiff(&.{
            .{ .operation = .delete, .owned = false, .text = "ad" },
            .{ .operation = .insert, .owned = false, .text = "b" },
            .{ .operation = .equal, .owned = false, .text = "c" },
        }, diffs.items);
        try testing.expect(diffs.items[0].owned);
        try testing.expect(diffs.items[1].owned);
    }

    {
        var diffs = try DiffList.initCapacity(testing.allocator, 3);
        defer deinitDiffList(testing.allocator, &diffs);
        diffs.appendAssumeCapacity(Edit.asBorrow(.equal, "a"));
        diffs.appendAssumeCapacity(Edit.asBorrow(.equal, "b"));
        diffs.appendAssumeCapacity(Edit.asBorrow(.equal, "c"));

        try diffCleanupMerge(testing.allocator, &diffs);
        try expectEqualDiff(&.{.{ .operation = .equal, .owned = false, .text = "abc" }}, diffs.items);
        try testing.expect(diffs.items[0].owned);
    }

    {
        const equal_text = "xabcy";
        const delete_text = "adc";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = equal_text[0..1] },
                .{ .operation = .delete, .owned = false, .text = delete_text[0..1] },
                .{ .operation = .insert, .owned = false, .text = equal_text[1..4] },
                .{ .operation = .delete, .owned = false, .text = delete_text[1..] },
                .{ .operation = .equal, .owned = false, .text = equal_text[4..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "xa" },
                .{ .operation = .delete, .owned = false, .text = "d" },
                .{ .operation = .insert, .owned = false, .text = "b" },
                .{ .operation = .equal, .owned = false, .text = "cy" },
            },
        });
    }

    {
        const text = "caba";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = text[0..1] },
                .{ .operation = .insert, .owned = false, .text = text[1..3] },
                .{ .operation = .equal, .owned = false, .text = text[3..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "ca" },
                .{ .operation = .insert, .owned = false, .text = "ba" },
            },
        });
    }

    {
        const text = "xabcy";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = text[0..1] },
                .{ .operation = .delete, .owned = false, .text = "ac" },
                .{ .operation = .insert, .owned = false, .text = text[1..4] },
                .{ .operation = .equal, .owned = false, .text = text[4..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "xa" },
                .{ .operation = .insert, .owned = false, .text = "b" },
                .{ .operation = .equal, .owned = false, .text = "cy" },
            },
        });
    }

    {
        const before = "xadcy";
        const after = "xabcy";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = before[0..1] },
                .{ .operation = .delete, .owned = false, .text = before[1..2] },
                .{ .operation = .insert, .owned = false, .text = after[1..4] },
                .{ .operation = .delete, .owned = false, .text = before[2..4] },
                .{ .operation = .equal, .owned = false, .text = before[4..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "xa" },
                .{ .operation = .delete, .owned = false, .text = "d" },
                .{ .operation = .insert, .owned = false, .text = "b" },
                .{ .operation = .equal, .owned = false, .text = "cy" },
            },
        });
    }

    {
        const before = "xady";
        const after = "xaby";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = before[0..1] },
                .{ .operation = .delete, .owned = false, .text = before[1..3] },
                .{ .operation = .insert, .owned = false, .text = after[1..3] },
                .{ .operation = .equal, .owned = false, .text = before[3..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "xa" },
                .{ .operation = .delete, .owned = false, .text = "d" },
                .{ .operation = .insert, .owned = false, .text = "b" },
                .{ .operation = .equal, .owned = false, .text = "y" },
            },
        });
    }

    {
        const before = "xcay";
        const after = "xbay";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = before[0..1] },
                .{ .operation = .delete, .owned = false, .text = before[1..3] },
                .{ .operation = .insert, .owned = false, .text = after[1..3] },
                .{ .operation = .equal, .owned = false, .text = before[3..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "x" },
                .{ .operation = .delete, .owned = false, .text = "c" },
                .{ .operation = .insert, .owned = false, .text = "b" },
                .{ .operation = .equal, .owned = false, .text = "ay" },
            },
        });
    }

    {
        const before = "xcdabz";
        const after = "xyabz";
        try testDiffCleanupMergeBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = before[0..1] },
                .{ .operation = .delete, .owned = false, .text = before[1..5] },
                .{ .operation = .insert, .owned = false, .text = after[1..4] },
                .{ .operation = .equal, .owned = false, .text = before[5..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "x" },
                .{ .operation = .delete, .owned = false, .text = "cd" },
                .{ .operation = .insert, .owned = false, .text = "y" },
                .{ .operation = .equal, .owned = false, .text = "abz" },
            },
        });
    }

    try testDiffCleanupMergeBorrowed(.{
        .input = &.{
            .{ .operation = .delete, .owned = false, .text = "a" },
            .{ .operation = .insert, .owned = false, .text = "b" },
            .{ .operation = .delete, .owned = false, .text = "c" },
            .{ .operation = .insert, .owned = false, .text = "d" },
            .{ .operation = .equal, .owned = false, .text = "ef" },
        },
        .expected = &.{
            .{ .operation = .delete, .owned = false, .text = "ac" },
            .{ .operation = .insert, .owned = false, .text = "bd" },
            .{ .operation = .equal, .owned = false, .text = "ef" },
        },
    });
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

fn testDiffCleanupSemanticLosslessBorrowed(params: TestIO) !void {
    var diffs = try DiffList.initCapacity(testing.allocator, params.input.len);
    defer deinitDiffList(testing.allocator, &diffs);

    for (params.input) |item| {
        diffs.appendAssumeCapacity(Edit.asBorrow(item.operation, item.text));
    }

    try diffCleanupSemanticLossless(testing.allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
    for (diffs.items) |item| {
        try testing.expect(!item.owned);
    }
}

fn testDiffCleanupSemanticLosslessBorrowedRoundTrip(
    input: []const Edit,
    expected_before: []const u8,
    expected_after: []const u8,
) !void {
    var diffs = try DiffList.initCapacity(testing.allocator, input.len);
    defer deinitDiffList(testing.allocator, &diffs);
    for (input) |item| {
        diffs.appendAssumeCapacity(Edit.asBorrow(item.operation, item.text));
    }
    try diffCleanupSemanticLossless(testing.allocator, &diffs);
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

fn testDiffCleanupSemanticRoundTrip(
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
    try diffCleanupSemantic(allocator, &diffs);
    const before = try diffBeforeText(allocator, diffs);
    defer allocator.free(before);
    const after = try diffAfterText(allocator, diffs);
    defer allocator.free(after);
    try testing.expectEqualStrings(expected_before, before);
    try testing.expectEqualStrings(expected_after, after);
}

fn testCloneDiffList(allocator: Allocator, diff_slice: []const Edit) !void {
    var diffs = try sliceToDiffList(allocator, diff_slice);
    defer deinitDiffList(allocator, &diffs);
    var cloned = try cloneDiffList(allocator, &diffs);
    defer deinitDiffList(allocator, &cloned);
    try expectEqualDiff(diff_slice, cloned.items);
}

fn testSliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !void {
    var diffs = try sliceToDiffList(allocator, diff_slice);
    defer deinitDiffList(allocator, &diffs);
    try expectEqualDiff(diff_slice, diffs.items);
}

fn testDiffBisectSplitCase(
    allocator: Allocator,
    config: DiffConfig,
    text1: []const u8,
    text2: []const u8,
    x: isize,
    y: isize,
) !void {
    var diffs = try diffBisectSplit(config, allocator, text1, text2, x, y, std.math.maxInt(i64));
    defer deinitDiffList(allocator, &diffs);
}

fn sliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !DiffList {
    var diff_list: DiffList = .empty;
    errdefer {
        // coverage: errdefer
        deinitDiffList(allocator, &diff_list);
    }
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

    {
        const after = "The cow and the cat.";
        try testDiffCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = after[0..5] },
                .{ .operation = .insert, .owned = false, .text = after[5..17] },
                .{ .operation = .equal, .owned = false, .text = after[17..] },
            },
            "The cat.",
            after,
        );
    }

    {
        const after = "The-cow-and-the-cat.";
        try testDiffCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = after[0..4] },
                .{ .operation = .insert, .owned = false, .text = after[4..16] },
                .{ .operation = .equal, .owned = false, .text = after[16..] },
            },
            "The-cat.",
            after,
        );
    }

    {
        const before = "That cartoon.";
        const after = "That cat artoon.";
        try testDiffCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = before[0..6] },
                .{ .operation = .insert, .owned = false, .text = after[6..9] },
                .{ .operation = .equal, .owned = false, .text = before[6..] },
            },
            before,
            after,
        );
    }

    {
        const before = "That cat artoon.";
        const after = "That cartoon.";
        try testDiffCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = after[0..6] },
                .{ .operation = .delete, .owned = false, .text = before[6..9] },
                .{ .operation = .equal, .owned = false, .text = after[6..] },
            },
            before,
            after,
        );
    }

    {
        const before = "aax";
        const after = "ax";
        try testDiffCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = before[0..1] },
                .{ .operation = .delete, .owned = false, .text = before[1..2] },
                .{ .operation = .equal, .owned = false, .text = before[2..] },
            },
            before,
            after,
        );
    }

    {
        const before = "xaa";
        const after = "xa";
        try testDiffCleanupSemanticLosslessBorrowedRoundTrip(
            &.{
                .{ .operation = .equal, .owned = false, .text = before[0..1] },
                .{ .operation = .delete, .owned = false, .text = before[1..2] },
                .{ .operation = .equal, .owned = false, .text = before[2..] },
            },
            before,
            after,
        );
    }

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

    {
        const after = "The cow and the cat.";
        try testDiffCleanupSemanticLosslessBorrowed(.{
            .input = &.{
                .{ .operation = .equal, .owned = false, .text = after[0..5] },
                .{ .operation = .insert, .owned = false, .text = after[5..17] },
                .{ .operation = .equal, .owned = false, .text = after[17..] },
            },
            .expected = &.{
                .{ .operation = .equal, .owned = false, .text = "The " },
                .{ .operation = .insert, .owned = false, .text = "cow and the " },
                .{ .operation = .equal, .owned = false, .text = "cat." },
            },
        });
    }

    {
        const after = "The cow and the cat.";
        var diffs = try DiffList.initCapacity(testing.allocator, 3);
        defer deinitDiffList(testing.allocator, &diffs);
        diffs.appendAssumeCapacity(Edit.asBorrow(.equal, after[0..5]));
        diffs.appendAssumeCapacity(try Edit.asOwn(testing.allocator, .insert, after[5..17]));
        diffs.appendAssumeCapacity(Edit.asBorrow(.equal, after[17..]));

        try diffCleanupSemanticLossless(testing.allocator, &diffs);
        try expectEqualDiff(&.{
            .{ .operation = .equal, .owned = false, .text = "The " },
            .{ .operation = .insert, .owned = false, .text = "cow and the " },
            .{ .operation = .equal, .owned = false, .text = "cat." },
        }, diffs.items);
        for (diffs.items) |item| {
            try testing.expect(item.owned);
        }
    }
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

    for (diffs.items) |edit| {
        if (edit.operation != .insert) try text[0].appendSlice(edit.text);
        if (edit.operation != .delete) try text[1].appendSlice(edit.text);
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
    var diffs = try diffBisect(params.config, allocator, params.before, params.after, params.deadline);
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

test "diffBisectSplit edge coverage" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        break :blk cfg;
    };

    {
        var diffs = try diffBisectSplit(config, allocator, "cat", "map", 0, 0, std.math.maxInt(i64));
        defer deinitDiffList(allocator, &diffs);
        try expectEqualDiff(&.{
            Edit.asBorrow(.delete, "cat"),
            Edit.asBorrow(.insert, "map"),
        }, diffs.items);
    }

    {
        var diffs = try diffBisectSplit(config, allocator, "cat", "map", 3, 3, std.math.maxInt(i64));
        defer deinitDiffList(allocator, &diffs);
        try expectEqualDiff(&.{
            Edit.asBorrow(.delete, "cat"),
            Edit.asBorrow(.insert, "map"),
        }, diffs.items);
    }

    {
        var diffs = try diffBisectSplit(config, allocator, ".\n−", "}.", 3, 2, std.math.maxInt(i64));
        defer deinitDiffList(allocator, &diffs);
        try expectEqualDiff(&.{
            Edit.asBorrow(.delete, ".\n−"),
            Edit.asBorrow(.insert, "}."),
        }, diffs.items);
    }

    try testing.checkAllAllocationFailures(
        allocator,
        testCloneDiffList,
        .{&.{
            Edit.asBorrow(.equal, "alpha"),
            Edit.asBorrow(.delete, "beta"),
            Edit.asBorrow(.insert, "gamma"),
        }},
    );
    try testing.checkAllAllocationFailures(
        allocator,
        testSliceToDiffList,
        .{&.{
            Edit.asBorrow(.equal, "alpha"),
            Edit.asBorrow(.delete, "beta"),
            Edit.asBorrow(.insert, "gamma"),
        }},
    );
    try testing.checkAllAllocationFailures(
        allocator,
        testDiffBisectSplitCase,
        .{ config, "cat", "map", 0, 0 },
    );
    try testing.checkAllAllocationFailures(
        allocator,
        testDiffBisectSplitCase,
        .{ config, "cat", "map", 3, 3 },
    );
    try testing.checkAllAllocationFailures(
        allocator,
        testDiffBisectSplitCase,
        .{ config, ".\n−", "}.", 3, 2 },
    );

    try testing.expectEqual(@as(u8, 0), boolInt(false));
    try testing.expectEqual(@as(u8, 1), boolInt(true));
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

    try expectEqualDiff(diff_checked.items, diff_unchecked.items);
}

test diffLineMode {
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

test "check-line-mode" {
    try testDiffLineMode(
        testing.allocator,
        20,
        "alpha-1\nalpha-2\nshared-a\nbeta-1\nbeta-2\nshared-b\ngamma-1\ngamma-2\nshared-c\n",
        "omega-1\nomega-2\nshared-a\ntheta-1\ntheta-2\nshared-b\nsigma-1\nsigma-2\nshared-c\n",
    );
    try testDiffLineMode(
        testing.allocator,
        20,
        "red-1\nred-2\npivot-a\nblue-1\nblue-2\npivot-b\ngreen-1\ngreen-2\npivot-c\n",
        "cyan-1\ncyan-2\npivot-a\nyellow-1\nyellow-2\npivot-b\nmagenta-1\nmagenta-2\npivot-c\n",
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
    try expectEqualDiff(params.expected, diffs.items);
}

test diffCleanupSemantic {
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{},
        .expected = &[_]Edit{},
    }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
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
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
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
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{
            Edit.asBorrow(.delete, "ab"),
            Edit.asBorrow(.insert, "12"),
            Edit.asBorrow(.equal, "x"),
            Edit.asBorrow(.insert, "34"),
        },
        .expected = &[_]Edit{
            Edit.asBorrow(.delete, "abx"),
            Edit.asBorrow(.insert, "12x34"),
        },
    }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{
            Edit.asBorrow(.delete, "ab"),
            Edit.asBorrow(.insert, "12"),
            Edit.asBorrow(.equal, "xy"),
            Edit.asBorrow(.insert, "34"),
            Edit.asBorrow(.equal, "z"),
            Edit.asBorrow(.delete, "cd"),
            Edit.asBorrow(.insert, "56"),
        },
        .expected = &[_]Edit{
            Edit.asBorrow(.delete, "abxyzcd"),
            Edit.asBorrow(.insert, "12xy34z56"),
        },
    }});
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{
            Edit.asBorrow(.delete, "12"),
            Edit.asBorrow(.insert, "ab"),
            Edit.asBorrow(.equal, "WXYZ"),
            Edit.asBorrow(.delete, "34"),
            Edit.asBorrow(.insert, "cd"),
            Edit.asBorrow(.equal, "QRST"),
            Edit.asBorrow(.delete, "5"),
            Edit.asBorrow(.insert, "e"),
            Edit.asBorrow(.equal, "x"),
            Edit.asBorrow(.delete, "67"),
            Edit.asBorrow(.insert, "fg"),
        },
        .expected = &[_]Edit{
            Edit.asBorrow(.delete, "12"),
            Edit.asBorrow(.insert, "ab"),
            Edit.asBorrow(.equal, "WXYZ"),
            Edit.asBorrow(.delete, "34"),
            Edit.asBorrow(.insert, "cd"),
            Edit.asBorrow(.equal, "QRST"),
            Edit.asBorrow(.delete, "5x67"),
            Edit.asBorrow(.insert, "exfg"),
        },
    }});

    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDiffCleanupSemanticRoundTrip,
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
    try testing.checkAllAllocationFailures(testing.allocator, testDiffCleanupSemantic, .{TestIO{
        .input = &[_]Edit{
            Edit.asBorrow(.delete, "ab"),
            Edit.asBorrow(.insert, "12"),
            Edit.asBorrow(.equal, "x"),
            Edit.asBorrow(.delete, "cd"),
            Edit.asBorrow(.insert, "34"),
            Edit.asBorrow(.equal, "y"),
            Edit.asBorrow(.delete, "ef"),
            Edit.asBorrow(.insert, "56"),
            Edit.asBorrow(.equal, "z"),
            Edit.asBorrow(.delete, "gh"),
            Edit.asBorrow(.insert, "78"),
        },
        .expected = &[_]Edit{
            Edit.asBorrow(.delete, "abxcdyefzgh"),
            Edit.asBorrow(.insert, "12x34y56z78"),
        },
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
        diffs.appendAssumeCapacity(.{
            .operation = item.operation,
            .owned = true,
            .text = try allocator.dupe(u8, item.text),
        });
    }
    try diffCleanupEfficiency(config, allocator, &diffs);
    try expectEqualDiff(params.expected, diffs.items);
}

test "diffCleanupEfficiency" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var config: DiffConfig = .default;
        config.edit_cost = 4;
        break :blk config;
    };
    var diffs: DiffList = .empty;
    try diffCleanupEfficiency(config, allocator, &diffs);
    try testing.expectEqualDeep(DiffList.empty, diffs);
    try testing.checkAllAllocationFailures(
        allocator,
        testDiffCleanupEfficiency,
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
    try testing.checkAllAllocationFailures(
        allocator,
        testDiffCleanupEfficiency,
        .{
            config,
            TestIO{
                .input = &[_]Edit{
                    Edit.asBorrow(.delete, "ab"),
                    Edit.asBorrow(.insert, "12"),
                    Edit.asBorrow(.equal, "xy"),
                    Edit.asBorrow(.insert, "34"),
                    Edit.asBorrow(.equal, "z"),
                    Edit.asBorrow(.delete, "cd"),
                    Edit.asBorrow(.insert, "56"),
                },
                .expected = &[_]Edit{
                    Edit.asBorrow(.delete, "abxyzcd"),
                    Edit.asBorrow(.insert, "12xy34z56"),
                },
            },
        },
    );
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

test "diff beforeText regression for wikipedia ed script snippet" {
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.check_lines = false;
        cfg.check_line_threshold = 1024 * 1024;
        cfg.timeout = 0;
        break :blk cfg;
    };
    const allocator = testing.allocator;
    const before =
        "An [[Ed (text editor)|ed script]] can still be generated by modern versions of diff with the <code>- option. The resulting edit script for this example is as follows:\n" ++ "\n" ++ " 24'''a'''\n" ++ " \n" ++ " ''This paragraph contains''\n" ++ " ''important new additions''\n" ++ " ''to this document.''\n" ++ " .\n" ++ " 17'''c'''\n" ++ " ''check this document. On''\n" ++ " .\n" ++ " 11,15'''d'''\n" ++ " 0'''a'''\n" ++ " ''This is an important''\n" ++ " ''notice! It should''\n" ++ " ''therefore be located at''\n" ++ " ''the beginning of this''\n" ++ " ''document!''\n" ++ " \n" ++ " .\n" ++ "\n" ++ "In order to transform the content of file ''original'' into the content of file ''new'' using {{Mono|ed}}, we should append two lines to this diff file, one line containing a <code>w</code> (write) command, and one containing a <code>q</code> (quit) command (e.g. by {{code|lang=bash|printf \"w\\nq\\n\" >> mydiff}}). Here we gave the diff file the name ''mydiff'' and the transformation will then happen when we run {{code|lang=bash|ed -s original.\n" ++ "−\n" ++ "\n";
    const after =
        "An [[Ed (text editor)|ed script]] can still be generated by modern versions of diff with the <code>-e</code> option. The resulting edit script for this example is as follows:\n" ++ "\n" ++ " 24'''a'''\n" ++ " \n" ++ " ''This paragraph contains''\n" ++ " ''important new additions''\n" ++ " ''to this document.''\n" ++ " .\n" ++ " 17'''c'''\n" ++ " ''check this document. On''\n" ++ " .\n" ++ " 11,15'''d'''\n" ++ " 0'''a'''\n" ++ " ''This is an important''\n" ++ " ''notice! It should''\n" ++ " ''therefore be located at''\n" ++ " ''the beginning of this''\n" ++ " ''document!''\n" ++ " \n" ++ " .\n" ++ "\n" ++ "In order to transform the content of file ''original'' into the content of file ''new'' using {{Mono|ed}}, we should append two lines to this diff file, one line containing a <code>w</code> (write) command, and one containing a <code>q</code> (quit) command (e.g. by {{code|lang=bash|printf \"w\\nq\\n\" >> mydiff}}). Here we gave the diff file the name ''mydiff'' and the transformation will then happen when we run {{code|lang=bash|ed -s original < mydiff}}.\n" ++ "\n";

    var diffs = try diffListFromConfig(allocator, config, before, after);
    defer deinitDiffList(allocator, &diffs);

    const rebuilt_before = try diffBeforeText(allocator, diffs);
    defer allocator.free(rebuilt_before);
    const rebuilt_after = try diffAfterText(allocator, diffs);
    defer allocator.free(rebuilt_after);

    try testing.expectEqualStrings(before, rebuilt_before);
    try testing.expectEqualStrings(after, rebuilt_after);
}

test "fromZDelta replaces existing edits" {
    const allocator = testing.allocator;
    var difference = Diff.init(.default);
    defer difference.deinit(allocator);

    difference.edits = try sliceToDiffList(allocator, &.{
        Edit.asBorrow(.delete, "stale"),
    });

    _ = try difference.fromZDelta(allocator, "abc", "zΔ⚡b|=3|");
    try expectEqualDiff(&.{Edit.asBorrow(.equal, "abc")}, difference.edits.items);
}

test "diffLineMode coverage runs" {
    const allocator = testing.allocator;
    const config: DiffConfig = blk: {
        var cfg: DiffConfig = .default;
        cfg.timeout = 0;
        break :blk cfg;
    };
    var diffs = try diffLineMode(
        config,
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

test "diffPrettyFormat decorates leading and trailing whitespace in edits" {
    const allocator = testing.allocator;
    var diffs: DiffList = .empty;
    defer deinitDiffList(allocator, &diffs);

    try diffs.append(allocator, Edit.asBorrow(.delete, "  gone\t"));
    try diffs.append(allocator, Edit.asBorrow(.insert, "\tnew  "));

    const out_text = try diffPrettyFormat(allocator, diffs, .{
        .delete_start = "<d>",
        .delete_end = "</d>",
        .d_ws_start = "<dw>",
        .d_ws_end = "</dw>",
        .insert_start = "<i>",
        .insert_end = "</i>",
        .i_ws_start = "<iw>",
        .i_ws_end = "</iw>",
    });
    defer allocator.free(out_text);

    try testing.expectEqualStrings(
        "<d><dw>  </dw>gone<dw>\t</dw></d><i><iw>\t</iw>new<iw>  </iw></i>",
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

const builtin = @import("builtin");
const is_debug = builtin.mode == .Debug;

const Patch = @import("Patch.zig");
const PatchConfig = Patch.PatchConfig;
const dmp = @import("../dmp.zig");
const common = @import("common.zig");
const zdelta_mod = @import("../zdelta.zig");
const cloneDiffList = common.cloneDiffList;
const copyDiffList = common.copyDiffList;
const diffRunAllBorrowed = common.diffRunAllBorrowed;
const diffBorrowedRunSpan = common.diffBorrowedRunSpan;
const diffMaterializeRun = common.diffMaterializeRun;
const diffMakeOwnedConcat2 = common.diffMakeOwnedConcat2;
const diffCommonPrefix = common.diffCommonPrefix;
const diffCommonSuffix = common.diffCommonSuffix;
const hasSharedPrefixLen = common.hasSharedPrefixLen;
const diffCleanupSemanticScore = common.diffCleanupSemanticScore;
const diffIndex = common.diffIndex;
const diffBeforeText = common.diffBeforeText;
const diffAfterText = common.diffAfterText;
const freeRangeDiffList = common.freeRangeDiffList;
const diffCommonOverlap = common.diffCommonOverlap;
const boolInt = common.boolInt;
const is_follow = common.isFollow;
const fixSplitForward = common.fixSplitForward;
const fixSplitBackward = common.fixSplitBackward;
const cast = common.cast;
const u2i = common.u2i;
const i2u = common.i2u;
const dbgassert = common.dbgassert;
