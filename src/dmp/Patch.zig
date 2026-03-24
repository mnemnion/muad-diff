//! Patch represents a collection of hunks which can be serialized, parsed, and
//! applied to text.
//!
//! This file is the `Patch` type itself.  A `Patch` owns a `PatchList` of
//! `Hunk` values and provides the patch-specific operations over that list,
//! including construction from diffs or text, textual formatting, and patch
//! application.
//!
//! `Patch` is unmanaged.  Use `init()` for the default configuration or
//! `initOptions()` to provide a custom `PatchConfig`, and later release any
//! owned storage with `deinit(allocator)`.
//!
//! `PatchConfig` controls patch construction and application:
//! - `margin` is the amount of context carried around each hunk.
//! - `delete_threshold` controls how closely large deletions must match.
//! - `match_threshold` sets how strict matching is during application.
//! - `match_distance` sets how far from the expected location matching will
//!   search.
//! - `match_max_bits` sets the maximum pattern size used by the internal match
//!   logic and patch splitting.
//!
//! The usual flow is to initialize a `Patch`, populate it with `make()`,
//! `makeFromDiffs()`, `diffAndMake()`, or `fromText()`, and then call `apply()`
//! or one of the text formatting helpers.

/// Configuration controlling patch construction and application behavior.
config: PatchConfig = .{},

/// Owned collection of hunks making up this patch.
hunks: PatchList = .empty,

pub const PatchList = ArrayListUnmanaged(Hunk);

pub const PatchConfig = struct {
    /// Chunk size for context length.
    margin: u8 = 4,
    /// When deleting a large block of text (over ~64 characters), how close
    /// do the contents have to be to match the expected contents. (0.0 =
    /// perfection, 1.0 = very loose).  Note that `match_threshold` controls
    /// how closely the end points of a delete need to match.
    delete_threshold: f32 = 0.5,
    /// At what point is no match declared (0.0 = perfection, 1.0 = very loose).
    /// This defaults to 0.05, on the premise that the library will mostly be
    /// used in cases where failure is better than a bad patch application.
    match_threshold: f64 = 0.05,
    /// How far to search for a match (0 = exact location, 1000+ = broad match).
    /// A match this many characters away from the expected location will add
    /// 1.0 to the score (0.0 is a perfect match).
    match_distance: u32 = 1000,
    /// The number of bits in a usize.
    match_max_bits: u8 = @bitSizeOf(usize),
};

pub fn init() Patch {
    return .{};
}

pub fn initOptions(config: PatchConfig) Patch {
    return .{ .config = config };
}

pub fn clone(self: Patch, allocator: Allocator) !Patch {
    return .{
        .config = self.config,
        .hunks = try clonePatchList(allocator, self.hunks),
    };
}

pub fn deinit(self: *Patch, allocator: Allocator) void {
    deinitPatchList(allocator, &self.hunks);
    self.hunks = .empty;
}

/// Compute a list of patches to turn text1 into text2.
/// text2 is not provided, diffs are the delta between text1 and text2.
///
/// @param text1 Old text.
/// @param diffs Array of Diff objects for text1 to text2.
/// @return self.
pub fn make(
    self: *Patch,
    allocator: Allocator,
    text: []const u8,
    diffs: DiffList,
) error{OutOfMemory}!*Patch {
    self.deinit(allocator);
    self.hunks = try makePatchWithConfig(self.config, allocator, text, diffs);
    return self;
}

/// @return self.
pub fn makeFromDiffs(
    self: *Patch,
    allocator: Allocator,
    diffs: DiffList,
) error{OutOfMemory}!*Patch {
    self.deinit(allocator);
    self.hunks = try makePatchFromDiffsWithConfig(self.config, allocator, diffs);
    return self;
}

/// @return self.
pub fn diffAndMake(
    self: *Patch,
    allocator: Allocator,
    text1: []const u8,
    text2: []const u8,
) error{OutOfMemory}!*Patch {
    self.deinit(allocator);
    self.hunks = try diffAndMakePatchWithConfig(self.config, allocator, text1, text2);
    return self;
}

/// Parse a textual representation of patches and return a List of Patch
/// objects.
/// @param textline Text representation of patches.
/// @return self.
/// @throws ArgumentException If invalid input.
pub fn fromText(
    self: *Patch,
    allocator: Allocator,
    text: []const u8,
) DiffError!*Patch {
    self.deinit(allocator);
    self.hunks = try patchListFromText(allocator, text);
    return self;
}

/// Merge a set of patches onto the text.  Returns a tuple: the first of which
/// is the patched text, the second of which is...
///
/// TODO I'm just going to return a boolean saying whether all patches
/// were successful.  Rethink this at some point.  Possibility: build up a
/// patch string with all unsuccessful patches, it's a legible plain-text
/// format containing the failed edits, which could be converted into a patch
/// again, or used directly in an error message, or the slop turned up on the
/// dmp object and the patch reattempted. The delta allows us to adjust any
/// failed patches so they "fit" the next text.
///
/// @param text Old text.
/// @return Two element Object array, containing the new text and an array of
///      bool values.
pub fn apply(
    self: Patch,
    allocator: Allocator,
    og_text: []const u8,
) error{OutOfMemory}!struct { []const u8, bool } {
    return try patchApplyWithConfig(self.config, allocator, self.hunks, og_text);
}

/// Take a list of patches and return a textual representation.
/// @return Text representation of patches.
pub fn toText(self: Patch, allocator: Allocator) error{OutOfMemory}![]const u8 {
    return try patchListToText(allocator, self.hunks);
}

/// Stream a `PatchList` to the provided Writer.
pub fn writeText(self: Patch, writer: anytype) !void {
    try writePatch(writer, self.hunks);
}

pub fn deinitPatchList(allocator: Allocator, patches: *PatchList) void {
    defer patches.deinit(allocator);
    for (patches.items) |*a_patch| {
        deinitDiffList(allocator, &a_patch.diffs);
    }
}

pub fn clonePatchList(allocator: Allocator, patches: PatchList) !PatchList {
    var new_patches: PatchList = .empty;
    errdefer deinitPatchList(allocator, &new_patches);
    try new_patches.ensureTotalCapacity(allocator, patches.items.len);
    for (patches.items) |patch| {
        new_patches.appendAssumeCapacity(try patch.clone(allocator));
    }
    return new_patches;
}

/// Represents a single edit operation.
/// Represents a single operation in a Patch.
pub const Hunk = struct {
    /// Diff to be applied
    diffs: DiffList = .empty,
    /// Start of patch in before text
    start1: usize = 0,
    length1: usize = 0,
    /// Start of patch in after text
    start2: usize = 0,
    length2: usize = 0,

    pub const empty: Hunk = .{};

    /// Make a clone of the Hunk, including the Diff.
    pub fn clone(patch: Hunk, allocator: Allocator) !Hunk {
        var new_diffs: DiffList = .empty;
        try new_diffs.ensureTotalCapacity(allocator, patch.diffs.items.len);
        errdefer {
            deinitDiffList(allocator, &new_diffs);
        }
        for (patch.diffs.items) |a_diff| {
            new_diffs.appendAssumeCapacity(try a_diff.clone(allocator));
        }
        return Hunk{
            .diffs = new_diffs,
            .start1 = patch.start1,
            .length1 = patch.length1,
            .start2 = patch.start2,
            .length2 = patch.length2,
        };
    }

    pub fn deinit(patch: *Hunk, allocator: Allocator) void {
        deinitDiffList(allocator, &patch.diffs);
    }

    /// Emit patch hunk in Unidiff format, as specifified here:
    /// https://github.com/google/diff-match-patch/wiki/Unidiff
    /// This is similar to GNU Unidiff format, but not identical.
    /// Header: @@ -382,8 +481,9 @@
    /// Indices are printed as 1-based, not 0-based.
    /// @return The GNU diff string.
    pub fn asText(patch: Hunk, allocator: Allocator) ![]const u8 {
        var text_array = ArrayList(u8).init(allocator);
        defer text_array.deinit();
        const writer = text_array.writer();
        try patch.writeText(writer);
        return text_array.toOwnedSlice();
    }

    const format = std.fmt.format;

    /// Stream textual patch representation to Writer.  See `asText`
    /// for more information.
    pub fn writeText(patch: Hunk, writer: anytype) !void {
        // Write header.
        _ = try writer.write(PATCH_HEAD);
        // Stream coordinates
        if (patch.length1 == 0) {
            try format(writer, "{d},0", .{patch.start1});
        } else if (patch.length1 == 1) {
            try format(writer, "{d}", .{patch.start1 + 1});
        } else {
            try format(writer, "{d},{d}", .{ patch.start1 + 1, patch.length1 });
        }
        _ = try writer.write(" +");
        if (patch.length2 == 0) {
            try std.fmt.format(writer, "{d},0", .{patch.start2});
        } else if (patch.length2 == 1) {
            _ = try format(writer, "{d}", .{patch.start2 + 1});
        } else {
            try format(writer, "{d},{d}", .{ patch.start2 + 1, patch.length2 });
        }
        _ = try writer.write(PATCH_TAIL);
        // Escape the body of the patch with %xx notation.
        for (patch.diffs.items) |a_diff| {
            switch (a_diff.operation) {
                .insert => try writer.writeByte('+'),
                .delete => try writer.writeByte('-'),
                .equal => try writer.writeByte(' '),
            }
            _ = try writeUriEncoded(writer, a_diff.text);
            try writer.writeByte('\n');
        }
        return;
    }
};

const PATCH_HEAD = "@@ -";
const PATCH_TAIL = " @@\n";

//| MATCH FUNCTIONS

/// Locate the best instance of 'pattern' in 'text' near 'loc'.
/// Returns -1 if no match found.
/// @param text The text to search.
/// @param pattern The pattern to search for.
/// @param loc The location to search around.
/// @return Best match index or -1.
pub fn matchMain(
    config: PatchConfig,
    allocator: Allocator,
    text: []const u8,
    pattern: []const u8,
    passed_loc: usize,
) error{OutOfMemory}!?usize {
    // Clamp the loc to fit within text.
    const loc = @min(passed_loc, text.len);
    if (std.mem.eql(u8, text, pattern)) {
        // Shortcut
        return 0;
    } else if (text.len == 0) {
        // Nothing to match.
        return null;
    } else if (loc + pattern.len <= text.len and std.mem.eql(u8, text[loc..][0..pattern.len], pattern)) {
        // Perfect match at the perfect spot!  (Includes case of null pattern)
        return loc;
    } else {
        // Do a fuzzy compare.
        return matchBitap(config, allocator, text, pattern, loc);
    }
}

const sh_one: u64 = 1;

//| TODO: There's a lot we can tweak here.  Big one: a SIMD-lane Shift-Or
//| can be a lot larger than 64 / 32 bits, when we have one.
//| ---
//| The notes about perfect match optimization are actually spurious because the
//| speedups above prevent that.  What I don't like is the 'speedups' which will
//| search the entire text without matching if there isn't a perfect fit.  We
//| should be able to use the clamp function to determine what's so far off from
//| our threshold that we don't treat it as a match even if we find it, then
//| clamp off the source text in both directions so we decline to search where
//| we don't care if there is a match.
//| ---
//| I also don't like the hash map we're using for the alphabet, it's a
//| heavyweight heap-allocated data structure, and what we do with it can be
//| done simpler.  Stack space is cheap, since we know the total call graph
//| is shallow, so we can use the sparse array trick.  Two [256]u8, and one
//| [256]usize: we index sparse with our byte, and if sparse[b] < n, the number
//| of elements, we check if dense[sparse[b]] == b.  If so, our value is at
//| val[sparse[b]].  Even for big vector match-maps, 256 bits, this is not a lot
//| of stack allocation.  Better yet, we have the option to allocate the val
//| array after building our alphabet, and we only make as many vectors as we
//| have unique letters.  But it's 'just' a 16KiB stack allocation, even then,
//| and we use it densely, not sparsely.
//| ---
//| Bonus round: making our alphabet bytes does not fit the problem domain,
//| and this matters: our result will treat drift by wider characters as more
//| expensive than narrow ones, which is contrary to intuition.  Same issue with
//| Levenshein, the value should be in terms of codepoints, not codeunits.  I
//| think both of these are amenable to a cheap 'fixup', though the details
//| escape me.  Options: make a map of the pattern with indices in increasing
//| order, where multibytes all get the same number.  Or, maybe we just adjust
//| the default match threshold by the mean of character widths, and hope for
//| the best.  That heuristic has the advantage of being very easy, at least.

/// Locate the best instance of `pattern` in `text` near `loc` using the
/// Bitap algorithm.  Returns -1 if no match found.
///
/// @param text The text to search.
/// @param pattern The pattern to search for.
/// @param loc The location to search around.
/// @return Best match index or -1.
pub fn matchBitap(
    config: PatchConfig,
    allocator: Allocator,
    text: []const u8,
    pattern: []const u8,
    loc: usize,
) error{OutOfMemory}!?usize {
    // TODO decide what to do here:
    // assert (Match_MaxBits == 0 || pattern.Length <= Match_MaxBits)
    //    : "Pattern too long for this application.";
    assert(text.len != 0 and pattern.len != 0);

    // Initialise the alphabet.
    var map = try matchAlphabet(allocator, pattern);
    defer map.deinit();
    // Highest score beyond which we give up.
    var score_threshold = config.match_threshold;
    // Is there a nearby exact match? (speedup)
    // TODO obviously if we want a speedup here, we do this:
    // if (threshold == 0.0) return best_loc;  #proof in comments
    // We don't have to unwrap best_loc because the retval is ?usize already
    // #proof axiom: threshold is between 0.0 and 1.0 (doc comment)
    var best_loc = std.mem.indexOfPos(u8, text, loc, pattern);
    if (best_loc) |best| { // #proof this returns 0.0 for exact match (see comments in function)
        score_threshold = @min(matchBitapScore(config, 0, best, loc, pattern), score_threshold);
    }
    // What about in the other direction? (speedup)
    const trunc_text = text[0..@min(loc + pattern.len, text.len)];
    best_loc = std.mem.lastIndexOf(u8, trunc_text, pattern);
    if (best_loc) |best| { // #proof same here obviously
        score_threshold = @min(matchBitapScore(config, 0, best, loc, pattern), score_threshold);
    }
    // Initialise the bit arrays.
    const shift: u6 = @intCast(pattern.len - 1);
    const matchmask = sh_one << shift;
    best_loc = null;
    // Zig is very insistent about integer width and signedness.
    const i_textlen: isize = @intCast(text.len);
    const i_patlen: isize = @intCast(pattern.len);

    const i_loc: isize = @intCast(loc);
    var bin_min: isize = undefined;
    var bin_mid: isize = undefined;
    var bin_max: isize = i_patlen + i_textlen;
    // null last_rd to simplify freeing memory
    var last_rd: []usize = try allocator.alloc(usize, 0);
    errdefer allocator.free(last_rd);
    for (0..pattern.len) |d| {
        // Scan for the best match; each iteration allows for one more error.
        // Run a binary search to determine how far from 'loc' we can stray at
        // this error level.
        bin_min = 0;
        bin_mid = bin_max;
        while (bin_min < bin_mid) {
            // #proof lemma: if threshold == 0.0, this never happens
            if (matchBitapScore(config, d, @intCast(i_loc + bin_mid), loc, pattern) <= score_threshold) {
                bin_min = bin_mid;
            } else {
                bin_max = bin_mid;
            }
            bin_mid = @divTrunc(bin_max - bin_min, 2) + bin_min;
        }
        // Use the result from this iteration as the maximum for the next.
        bin_max = bin_mid;
        var start: usize = @intCast(@max(1, i_loc - bin_mid + 1));
        const finish: usize = @intCast(@min(i_loc + bin_mid, i_textlen) + i_patlen);
        var rd: []usize = try allocator.alloc(usize, finish + 2);
        errdefer allocator.free(rd);
        const dshift: u6 = @intCast(d);
        rd[finish + 1] = (sh_one << dshift) - 1;
        var j = finish;
        while (j >= start) : (j -= 1) {
            const char_match: usize = if (text.len <= j - 1 or !map.contains(text[j - 1]))
                // Out of range.
                0
            else
                map.get(text[j - 1]).?;
            if (d == 0) {
                // First pass: exact match.
                rd[j] = ((rd[j + 1] << 1) | 1) & char_match;
            } else {
                // Subsequent passes: fuzzy match.
                rd[j] = ((rd[j + 1] << 1) | 1) & char_match | (((last_rd[j + 1] | last_rd[j]) << 1) | 1) | last_rd[j + 1];
            }
            if ((rd[j] & matchmask) != 0) {
                const score = matchBitapScore(config, d, j - 1, loc, pattern);
                // This match will almost certainly be better than any existing
                // match.  But check anyway.
                // #proof: the smoking gun. This can only be equal not less.
                if (score <= score_threshold) {
                    // Told you so.
                    score_threshold = score;
                    best_loc = j - 1;
                    if (best_loc.? > loc) {
                        // When passing loc, don't exceed our current distance from loc.
                        const i_best_loc: isize = @intCast(best_loc.?);
                        start = @max(1, 2 * i_loc - i_best_loc);
                    } else {
                        // Already passed loc, downhill from here on in.
                        break;
                    }
                }
            }
        } // #proof Anything else will do this.
        // #proof d + 1 starts at 1, so (see function) this will always break.
        if (matchBitapScore(config, d + 1, loc, loc, pattern) > score_threshold) {
            // No hope for a (better) match at greater error levels.
            allocator.free(rd);
            break;
        }
        allocator.free(last_rd);
        last_rd = rd;
    }
    allocator.free(last_rd);
    return best_loc;
}

/// Compute and return the score for a match with e errors and x location.
/// @param e Number of errors in match.
/// @param x Location of match.
/// @param loc Expected location of match.
/// @param pattern Pattern being sought.
/// @return Overall score for match (0.0 = good, 1.0 = bad).
pub fn matchBitapScore(
    config: PatchConfig,
    e: usize,
    x: usize,
    loc: usize,
    pattern: []const u8,
) f64 {
    // shortcut? TODO, proof in comments
    if (e == 0 and x == loc) return 0.0;
    const e_float: f64 = @floatFromInt(e);
    const len_float: f64 = @floatFromInt(pattern.len);
    // if e == 0, accuracy == 0: 0/x = 0
    const accuracy = e_float / len_float;
    // if loc == x, proximity == 0
    const proximity = if (loc >= x) loc - x else x - loc;
    if (config.match_distance == 0) {
        // Dodge divide by zero
        if (proximity == 0) // therefore this returns 0
            return accuracy
        else
            return 1.0;
    }
    const float_match: f64 = @floatFromInt(config.match_distance);
    const float_proximity: f64 = @floatFromInt(proximity);
    // or this is 0 + 0/f_m aka 0
    return accuracy + (float_proximity / float_match);
}

/// Initialise the alphabet for the Bitap algorithm.
/// @param pattern The text to encode.
/// @return Hash of character locations.
fn matchAlphabet(allocator: Allocator, pattern: []const u8) error{OutOfMemory}!std.AutoHashMap(u8, usize) {
    var map = std.AutoHashMap(u8, usize).init(allocator);
    errdefer map.deinit();
    for (pattern) |c| {
        if (!map.contains(c)) {
            try map.put(c, 0);
        }
    }
    for (pattern, 0..) |c, i| {
        const shift: u6 = @intCast(pattern.len - i - 1);
        const value: usize = map.get(c).? | (@as(usize, 1) << shift);
        try map.put(c, value);
    }
    return map;
}

//|  PATCH FUNCTIONS

/// Increase the context until it is unique, but don't let the pattern
/// expand beyond DiffMatchPatch.match_max_bits.
///
/// @param patch The patch to grow.
/// @param text Source text.
pub fn patchAddContext(
    config: PatchConfig,
    allocator: Allocator,
    patch: *Hunk,
    text: []const u8,
) error{OutOfMemory}!void {
    if (text.len == 0) return;
    // TODO the fixup logic here might make patterns too large?
    // It should be ok, because big patches get broken up.  Hmm.
    // Also, the SimpleNote maintained branch does it this way.
    var padding: usize = 0;
    { // Grow the pattern around the patch until unique, to set padding amount.
        var pattern = text[patch.start2 .. patch.start2 + patch.length1];
        const max_width: usize = config.match_max_bits - (2 * config.margin);
        while (std.mem.indexOf(u8, text, pattern) != std.mem.lastIndexOf(u8, text, pattern) and pattern.len < max_width) {
            padding += config.margin;
            const pat_start = if (padding > patch.start2) 0 else patch.start2 - padding;
            const pat_end = @min(text.len, patch.start2 + patch.length1 + padding);
            pattern = text[pat_start..pat_end];
        }
    }
    // Add one chunk for good luck.
    padding += config.margin;
    // Add the prefix.
    const prefix = pre: {
        var pre_start = if (padding > patch.start2) 0 else patch.start2 - padding;
        // Make sure we're not breaking a codepoint.
        pre_start = fixSplitBackward(text, pre_start);
        // Assuming we did everything else right, pre_end should be
        // properly placed.
        break :pre text[pre_start..patch.start2];
    };
    if (prefix.len != 0) {
        try patch.diffs.ensureUnusedCapacity(allocator, 1);
        patch.diffs.insertAssumeCapacity(0, Edit.init(
            .equal,
            try allocator.dupe(u8, prefix),
        ));
    }
    // Add the suffix.
    const suffix = post: {
        const post_start = patch.start2 + patch.length1;
        var post_end = @min(text.len, patch.start2 + patch.length1 + padding);
        // Prevent broken codepoints here as well
        post_end = fixSplitForward(text, post_end);
        break :post text[post_start..post_end];
    };
    if (suffix.len != 0) {
        try patch.diffs.ensureUnusedCapacity(allocator, 1);
        patch.diffs.appendAssumeCapacity(
            Edit.init(
                .equal,
                try allocator.dupe(u8, suffix),
            ),
        );
    }
    // Roll back the start points.
    patch.start1 -= prefix.len;
    patch.start2 -= prefix.len;
    // Extend the lengths.
    patch.length1 += prefix.len + suffix.len;
    patch.length2 += prefix.len + suffix.len;
}

/// Determines how to handle Diffs in a patch.  Functions which create
/// the diffs internally can use `.own`: the Diffs will be copied to
/// the patch list, new ones allocated, and old ones freed.  Then call
/// `deinit` on the DiffList, but not `deinitDiffList`.  This *must not*
/// be used if the DiffList is not immediately freed, because some of
/// the diffs will contain spuriously empty text.
///
/// Functions which operate on an existing DiffList should use `.copy`:
/// as the name indicates, copies of the Diffs will be made, and the
/// original memory must be freed separately.
const DiffHandling = enum {
    copy,
    own,
};

pub fn diffAndMakePatchWithConfig(
    config: PatchConfig,
    allocator: Allocator,
    text1: []const u8,
    text2: []const u8,
) error{OutOfMemory}!PatchList {
    var diff_obj = Diff.init();
    defer diff_obj.deinit(allocator);
    diff_obj.config.check_lines = true;
    _ = try diff_obj.diff(allocator, text1, text2);
    if (diff_obj.edits.items.len > 2) {
        _ = try diff_obj.cleanupSemantic(allocator);
        _ = try diff_obj.cleanupEfficiency(allocator);
    }
    var diffs = diff_obj.edits;
    diff_obj.edits = .empty;
    defer deinitDiffList(allocator, &diffs);
    return try makePatchInternal(config, allocator, text1, diffs, .own);
}

/// @return List of Patch objects.
fn makePatchInternal(
    config: PatchConfig,
    allocator: Allocator,
    text: []const u8,
    diffs: DiffList,
    diff_act: DiffHandling,
) error{OutOfMemory}!PatchList {
    var patches: PatchList = .empty;
    errdefer deinitPatchList(allocator, &patches);
    if (diffs.items.len == 0) {
        return patches; // Empty diff means empty patchlist
    }

    var char_count1: usize = 0;
    var char_count2: usize = 0;
    // This avoids freeing the original copy of the text:
    var first_patch = true;
    var prepatch_text = text;
    defer {
        if (!first_patch)
            allocator.free(prepatch_text);
    }
    // Calculate amount of extra bytes needed.
    // This should let the allocator reuse freed space.
    var extra: isize = 0;
    for (diffs.items) |a_diff| {
        switch (a_diff.operation) {
            .insert => {
                extra += @intCast(a_diff.text.len);
            },
            .delete => {
                extra -= @intCast(a_diff.text.len);
            },
            .equal => continue,
        }
    }
    const extra_u: usize = if (extra > 0) @intCast(extra) else 0;
    const dummy_diff = Edit{ .operation = .equal, .text = "" };
    var postpatch = try ArrayList(u8).initCapacity(allocator, text.len + extra_u);
    defer postpatch.deinit();
    postpatch.appendSliceAssumeCapacity(text);
    var patch = Hunk{};
    errdefer patch.deinit(allocator);
    for (diffs.items, 0..) |a_diff, i| {
        if (patch.diffs.items.len == 0 and a_diff.operation != .equal) {
            patch.start1 = char_count1;
            patch.start2 = char_count2;
        }
        switch (a_diff.operation) {
            .insert => {
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                const d = the_diff: {
                    if (diff_act == .copy) {
                        const new = try a_diff.clone(allocator);
                        break :the_diff new;
                    } else {
                        assert(a_diff.eql(diffs.items[i]));
                        diffs.items[i] = dummy_diff;
                        break :the_diff a_diff;
                    }
                };
                patch.diffs.appendAssumeCapacity(d);
                patch.length2 += a_diff.text.len;
                try postpatch.insertSlice(char_count2, a_diff.text);
            },
            .delete => {
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                const d = the_diff: {
                    if (diff_act == .copy) {
                        const new = try a_diff.clone(allocator);
                        break :the_diff new;
                    } else {
                        assert(a_diff.eql(diffs.items[i]));
                        diffs.items[i] = dummy_diff;
                        break :the_diff a_diff;
                    }
                };
                patch.diffs.appendAssumeCapacity(d);
                patch.length1 += a_diff.text.len;
                try postpatch.replaceRange(char_count2, a_diff.text.len, "");
            },
            .equal => {
                //
                if (a_diff.text.len <= 2 * config.margin and patch.diffs.items.len != 0 and !a_diff.eql(diffs.getLast())) {
                    // Small equality inside a patch.
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    const d = the_diff: {
                        if (diff_act == .copy) {
                            const new = try a_diff.clone(allocator);
                            break :the_diff new;
                        } else {
                            assert(a_diff.eql(diffs.items[i]));
                            diffs.items[i] = dummy_diff;
                            break :the_diff a_diff;
                        }
                    };
                    patch.diffs.appendAssumeCapacity(d);
                    patch.length1 += a_diff.text.len;
                    patch.length2 += a_diff.text.len;
                }
                if (a_diff.text.len >= 2 * config.margin) {
                    // Time for a new patch.
                    if (patch.diffs.items.len != 0) {
                        // Free the Diff if we own it.
                        if (diff_act == .own) {
                            assert(a_diff.eql(diffs.items[i]));
                            allocator.free(a_diff.text);
                            diffs.items[i] = dummy_diff;
                        }
                        try patchAddContext(config, allocator, &patch, prepatch_text);
                        try patches.ensureUnusedCapacity(allocator, 1);
                        patches.appendAssumeCapacity(patch);
                        patch = Hunk{};
                        // Unlike Unidiff, our patch lists have a rolling context.
                        // https://github.com/google/diff-match-patch/wiki/Unidiff
                        // Update prepatch text & pos to reflect the application of the
                        // just completed patch.
                        const free_patch_text = prepatch_text;
                        prepatch_text = try allocator.dupe(u8, postpatch.items);
                        if (first_patch) {
                            // no free on first, we don't own the original text
                            first_patch = false;
                        } else {
                            allocator.free(free_patch_text);
                        }
                        char_count1 = char_count2;
                    }
                }
            },
        }
        // Update the current character count.
        if (a_diff.operation != .insert) {
            char_count1 += a_diff.text.len;
        }
        if (a_diff.operation != .delete) {
            char_count2 += a_diff.text.len;
        }
    } // end for loop
    // Pick up the leftover patch if not empty.
    if (patch.diffs.items.len != 0) {
        try patchAddContext(config, allocator, &patch, prepatch_text);
        try patches.ensureUnusedCapacity(allocator, 1);
        patches.appendAssumeCapacity(patch);
    }
    return patches;
}

/// Compute a list of patches to turn text1 into text2.
/// text2 is not provided, diffs are the delta between text1 and text2.
///
/// @param text1 Old text.
/// @param diffs Array of Diff objects for text1 to text2.
pub fn makePatchWithConfig(
    config: PatchConfig,
    allocator: Allocator,
    text: []const u8,
    diffs: DiffList,
) error{OutOfMemory}!PatchList {
    return try makePatchInternal(config, allocator, text, diffs, .copy);
}

pub fn makePatchFromDiffsWithConfig(
    config: PatchConfig,
    allocator: Allocator,
    diffs: DiffList,
) error{OutOfMemory}!PatchList {
    const text1 = try (Diff{ .edits = diffs }).beforeText(allocator);
    defer allocator.free(text1);
    return try makePatchWithConfig(config, allocator, text1, diffs);
}

/// Merge a set of patches onto the text.  Returns a tuple: the first of which
/// is the patched text, the second of which is...
///
/// TODO I'm just going to return a boolean saying whether all patches
/// were successful.  Rethink this at some point.  Possibility: build up a
/// patch string with all unsuccessful patches, it's a legible plain-text
/// format containing the failed edits, which could be converted into a patch
/// again, or used directly in an error message, or the slop turned up on the
/// dmp object and the patch reattempted. The delta allows us to adjust any
/// failed patches so they "fit" the next text.
///
/// @param patches Array of Patch objects
/// @param text Old text.
/// @return Two element Object array, containing the new text and an array of
///      bool values.
pub fn patchApplyWithConfig(
    config: PatchConfig,
    allocator: Allocator,
    og_patches: PatchList,
    og_text: []const u8,
) error{OutOfMemory}!struct { []const u8, bool } {
    if (og_patches.items.len == 0) {
        // As silly as this is, we dupe the text, because something
        // passing an empty patchset isn't going to check, and will
        // end up double-freeing if we don't.  Going with 'true' as
        // the null patchset was successfully 'applied' here.
        return .{ try allocator.dupe(u8, og_text), true };
    }
    // So we can report if all patches were applied:
    var all_applied = true;
    // Deep copy the patches so that no changes are made to originals.
    var patches = try clonePatchList(allocator, og_patches);
    defer deinitPatchList(allocator, &patches);
    const null_padding = try patchAddPadding(config, allocator, &patches);
    defer allocator.free(null_padding);
    var text = try ArrayList(u8).initCapacity(allocator, og_text.len + 2 * null_padding.len);
    defer text.deinit();
    text.appendSliceAssumeCapacity(null_padding);
    text.appendSliceAssumeCapacity(og_text);
    text.appendSliceAssumeCapacity(null_padding);
    try patchSplitMax(config, allocator, &patches);
    // delta keeps track of the offset between the expected and actual
    // location of the previous patch.  If there are patches expected at
    // positions 10 and 20, but the first patch was found at 12, delta is 2
    // and the second patch has an effective expected position of 22.
    var delta: isize = 0;
    for (patches.items) |a_patch| {
        const expected_loc = cast(usize, (cast(isize, a_patch.start2) + delta));
        const text1 = try (Diff{ .edits = a_patch.diffs }).beforeText(allocator);
        defer allocator.free(text1);
        var maybe_start: ?usize = null;
        var maybe_end: ?usize = null;
        const m_max_b = config.match_max_bits;
        if (text1.len > m_max_b) {
            // patchSplitMax will only provide an oversized pattern
            // in the case of a monster delete.
            maybe_start = try matchMain(config, allocator, text.items, text1[0..m_max_b], expected_loc);
            if (maybe_start) |start| {
                // Ok because we tested and text1.len is larger.
                const e_start = text1.len - m_max_b;
                maybe_end = try matchMain(
                    config,
                    allocator,
                    text.items,
                    text1[e_start..],
                    e_start + expected_loc,
                );
                // No match if a) no end_loc or b) the matches cross each other.
                if (maybe_end) |end| {
                    if (start >= end) {
                        maybe_start = null;
                    }
                } else {
                    maybe_start = null;
                }
            }
        } else {
            maybe_start = try matchMain(config, allocator, text.items, text1, expected_loc);
        }
        if (maybe_start) |start| {
            // Found a match.  :)
            delta = cast(isize, start) - cast(isize, expected_loc);
            // results[x] = true;
            const text2 = t2: {
                if (maybe_end) |end| {
                    break :t2 text.items[start..@min(end + m_max_b, text.items.len)];
                } else {
                    break :t2 text.items[start..@min(start + text1.len, text.items.len)];
                }
            };
            if (std.mem.eql(u8, text1, text2)) {
                // Perfect match, just shove the replacement text in.
                const diff_text = try (Diff{ .edits = a_patch.diffs }).afterText(allocator);
                defer allocator.free(diff_text);
                try text.replaceRange(start, text1.len, diff_text);
            } else {
                // Imperfect match.  Run a diff to get a framework of equivalent
                // indices.
                var diff_obj = Diff.init();
                defer diff_obj.deinit(allocator);
                diff_obj.config.check_lines = false;
                _ = try diff_obj.diff(
                    allocator,
                    text1,
                    text2,
                );
                const t1_l_float: f64 = @floatFromInt(text1.len);
                const levenshtein: f64 = diff_obj.levenshtein();
                const bad_match = levenshtein / t1_l_float > config.delete_threshold;
                if (text1.len > m_max_b and bad_match) {
                    // The end points match, but the content is unacceptably bad.
                    // results[x] = false;
                    all_applied = false;
                } else {
                    _ = try diff_obj.cleanupSemanticLossless(allocator);
                    var index1: usize = 0;
                    for (a_patch.diffs.items) |a_diff| {
                        if (a_diff.operation != .equal) {
                            const index2 = diff_obj.index(index1);
                            if (a_diff.operation == .insert) {
                                // Insertion
                                try text.insertSlice(start + index2, a_diff.text);
                            } else if (a_diff.operation == .delete) {
                                // Deletion
                                const delete_at = diff_obj.index(index1 + a_diff.text.len) - index2;
                                text.replaceRangeAssumeCapacity(
                                    start + index2,
                                    delete_at,
                                    &.{},
                                );
                            }
                        }
                        if (a_diff.operation != .delete) {
                            index1 += a_diff.text.len;
                        }
                    }
                }
            }
        } else {
            // No match found.  :(
            all_applied = false;
            // Subtract the delta for this failed patch from subsequent patches.
            delta -= cast(isize, a_patch.length2) - cast(isize, a_patch.length1);
        }
    }
    // strip padding
    text.replaceRangeAssumeCapacity(0, null_padding.len, &.{});
    text.items.len -= null_padding.len;
    return .{ try text.toOwnedSlice(), all_applied };
}

// Look through the patches and break up any which are longer than the
// maximum limit of the match algorithm.
// Intended to be called only from within patchApply.
// @param patches List of Patch objects.
pub fn patchSplitMax(
    config: PatchConfig,
    allocator: Allocator,
    patches: *PatchList,
) error{OutOfMemory}!void {
    const patch_size = config.match_max_bits;
    const patch_margin = config.margin;
    const max_patch_len = patch_size - patch_margin;
    // Mutating an array while iterating it? Sure, lets!
    var x_i: isize = 0;
    while (x_i < patches.items.len) : (x_i += 1) {
        const x: usize = @intCast(x_i);
        if (patches.items[x].length1 <= patch_size) continue;

        // We have a big ol' patch.
        var bigpatch = patches.orderedRemove(x);
        defer bigpatch.deinit(allocator);
        // Prevent incrementing past the next patch:
        x_i -= 1;
        var start1 = bigpatch.start1;
        var start2 = bigpatch.start2;
        // start with an empty precontext so that we can deinit consistently
        var precontext: []const u8 = try allocator.alloc(u8, 0);
        while (bigpatch.diffs.items.len != 0) {
            var guard_precontext = true;
            errdefer {
                if (guard_precontext) {
                    allocator.free(precontext);
                }
            }
            // Create one of several smaller patches.
            var patch = Hunk{};
            errdefer patch.deinit(allocator);
            var empty = true;
            patch.start1 = start1 - precontext.len;
            patch.start2 = start2 - precontext.len;
            if (precontext.len != 0) {
                patch.length2 = precontext.len;
                patch.length1 = precontext.len;
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                guard_precontext = false;
                patch.diffs.appendAssumeCapacity(
                    Edit{
                        .operation = .equal,
                        .text = precontext,
                    },
                );
            }
            while (bigpatch.diffs.items.len != 0 and patch.length1 < max_patch_len) {
                const diff_type = bigpatch.diffs.items[0].operation;
                const diff_text = bigpatch.diffs.items[0].text;
                if (diff_type == .insert) {
                    // Insertions are harmless.
                    patch.length2 += diff_text.len;
                    start2 += diff_text.len;
                    // Move the patch (transfers ownership)
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    patch.diffs.appendAssumeCapacity(bigpatch.diffs.orderedRemove(0));
                    empty = false;
                } else if (patch.diffs.items.len == 1 and
                    diff_type == .delete and
                    patch.diffs.items[0].operation == .equal and
                    diff_text.len > 2 * patch_size)
                {
                    // This is a large deletion.  Let it pass in one chunk.
                    patch.length1 += diff_text.len;
                    start1 += diff_text.len;
                    empty = false;
                    // Transfer to patch:
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    patch.diffs.appendAssumeCapacity(bigpatch.diffs.orderedRemove(0));
                } else {
                    // Deletion or equality.  Only take as much as we can stomach.
                    // Note: because this is an internal function, we don't care
                    // about codepoint splitting, which won't affect the final
                    // result.
                    const text_end = @min(diff_text.len, patch_size - patch.length1 - patch_margin);
                    const new_diff_text = diff_text[0..text_end];
                    patch.length1 += new_diff_text.len;
                    start1 += new_diff_text.len;
                    if (diff_type == .equal) {
                        patch.length2 += new_diff_text.len;
                        start2 += new_diff_text.len;
                    } else {
                        empty = false;
                    }
                    // Now check if we did anything.
                    try patch.diffs.ensureUnusedCapacity(allocator, 1);
                    if (new_diff_text.len == diff_text.len) {
                        // We can reuse the diff.
                        patch.diffs.appendAssumeCapacity(bigpatch.diffs.orderedRemove(0));
                    } else {
                        // Free and dupe
                        patch.diffs.appendAssumeCapacity(Edit{
                            .operation = diff_type,
                            .text = try allocator.dupe(u8, new_diff_text),
                        });
                        const old_diff = bigpatch.diffs.items[0];
                        bigpatch.diffs.items[0] = Edit{
                            .operation = diff_type,
                            .text = try allocator.dupe(u8, diff_text[new_diff_text.len..]),
                        };
                        allocator.free(old_diff.text);
                    }
                }
            }
            // Append the end context for this patch.
            const post_text = try (Diff{ .edits = bigpatch.diffs }).beforeText(allocator);
            const postcontext = post: {
                if (post_text.len > patch_margin) {
                    defer allocator.free(post_text);
                    const truncated = try allocator.dupe(u8, post_text[0..patch_margin]);
                    break :post truncated;
                } else {
                    break :post post_text;
                }
            };
            var guard_postcontext = true;
            errdefer {
                if (guard_postcontext) {
                    allocator.free(postcontext);
                }
            }
            // Compute the head context for the next patch, if we're going to
            // need it.
            if (bigpatch.diffs.items.len != 0) {
                const after_text = try (Diff{ .edits = patch.diffs }).afterText(allocator);
                if (patch_margin > after_text.len) {
                    precontext = after_text;
                } else {
                    defer allocator.free(after_text);
                    precontext = try allocator.dupe(u8, after_text[after_text.len - patch_margin ..]);
                }
                guard_precontext = true;
            }
            if (postcontext.len != 0) {
                try patch.diffs.ensureUnusedCapacity(allocator, 1);
                patch.length1 += postcontext.len;
                patch.length2 += postcontext.len;
                const last_diff = patch.diffs.getLastOrNull();
                if (last_diff != null and last_diff.?.operation == .equal) {
                    // Free this diff and swap in a new one.
                    defer {
                        allocator.free(last_diff.?.text);
                        allocator.free(postcontext);
                        guard_postcontext = false;
                    }
                    patch.diffs.items.len -= 1;
                    const new_diff_text = try std.mem.concat(
                        allocator,
                        u8,
                        &.{
                            last_diff.?.text,
                            postcontext,
                        },
                    );
                    patch.diffs.appendAssumeCapacity(
                        Edit{ .operation = .equal, .text = new_diff_text },
                    );
                } else {
                    // New diff from postcontext.
                    patch.diffs.appendAssumeCapacity(
                        Edit{ .operation = .equal, .text = postcontext },
                    );
                }
                guard_postcontext = false;
            }
            if (!empty) {
                // Insert the next patch
                // Goes after x, and we need increment to skip:
                x_i += 1;
                try patches.insert(allocator, @intCast(x_i), patch);
            } else {
                patch.deinit(allocator);
            }
        } // We don't use the last precontext
        // allocator.free(precontext);
    }
}

/// Add some padding on text start and end so that edges can match something.
/// Intended to be called only from within patchApply.
/// @param patches Array of Patch objects.
/// @return The padding string added to each side.
pub fn patchAddPadding(
    config: PatchConfig,
    allocator: Allocator,
    patches: *PatchList,
) error{OutOfMemory}![]const u8 {
    if (patches.items.len == 0) return "";
    const pad_len = config.margin;
    var paddingcodes = try ArrayList(u8).initCapacity(allocator, pad_len);
    defer paddingcodes.deinit();

    {
        var control_code: u8 = 1;
        while (control_code <= pad_len) : (control_code += 1) {
            paddingcodes.appendAssumeCapacity(control_code);
        }
    }
    // Bump all the patches forward.
    for (patches.items) |*a_patch| {
        a_patch.*.start1 += pad_len;
        a_patch.*.start2 += pad_len;
    }
    // Add some padding on start of first diff.
    var patch_start = &patches.items[0];
    var diffs_start = &patch_start.diffs;
    if (diffs_start.items.len == 0 or diffs_start.items[0].operation != .equal) {
        // Add nullPadding equality.
        try diffs_start.ensureUnusedCapacity(allocator, 1);
        diffs_start.insertAssumeCapacity(
            0,
            Edit{
                .operation = .equal,
                .text = try allocator.dupe(u8, paddingcodes.items),
            },
        );
        // Should be 0 due to prior patch bump
        patch_start.start1 -= pad_len;
        assert(patch_start.start1 == 0);
        patch_start.start2 -= pad_len;
        assert(patch_start.start2 == 0);
        patch_start.length1 += pad_len;
        patch_start.length2 += pad_len;
        // patches.items[0].diffs = diffs_start;
    } else if (pad_len > diffs_start.items[0].text.len) {
        // Grow first equality.
        var diff1 = &diffs_start.items[0];
        const old_diff_text = diff1.text;
        const extra_len = pad_len - diff1.text.len;
        diff1.text = try std.mem.concat(
            allocator,
            u8,
            &.{ paddingcodes.items[diff1.text.len..], diff1.text },
        );
        allocator.free(old_diff_text);
        patch_start.start1 -= extra_len;
        patch_start.start2 -= extra_len;
        patch_start.length1 += extra_len;
        patch_start.length2 += extra_len;
    }
    // Add some padding on end of last diff.
    var patch_end = &patches.items[patches.items.len - 1];
    var diffs_end = &patch_end.diffs;
    if ((diffs_end.items.len == 0) or (diffs_end.getLast().operation != .equal)) {
        // Add nullPadding equality.
        try diffs_end.ensureUnusedCapacity(allocator, 1);
        diffs_end.appendAssumeCapacity(
            Edit{
                .operation = .equal,
                .text = try allocator.dupe(u8, paddingcodes.items),
            },
        );
        patch_end.length1 += pad_len;
        patch_end.length2 += pad_len;
    } else if (pad_len > diffs_end.getLast().text.len) {
        // Grow last equality.
        var last_diff = &diffs_end.items[diffs_end.items.len - 1];
        const old_diff_text = last_diff.text;
        const extra_len = pad_len - last_diff.text.len;
        last_diff.text = try std.mem.concat(
            allocator,
            u8,
            &.{ last_diff.text, paddingcodes.items[0..extra_len] },
        );
        allocator.free(old_diff_text);
        patch_end.length2 += extra_len;
        patch_end.length1 += extra_len;
    }
    return paddingcodes.toOwnedSlice();
}

/// Take a list of patches and return a textual representation.
/// @param patches List of Patch objects.
/// @return Text representation of patches.
pub fn patchListToText(allocator: Allocator, patches: PatchList) error{OutOfMemory}![]const u8 {
    var text_array = ArrayList(u8).init(allocator);
    defer text_array.deinit();
    const writer = text_array.writer();
    try writePatch(writer, patches);
    return text_array.toOwnedSlice();
}

/// Stream a `PatchList` to the provided Writer.
pub fn writePatch(writer: anytype, patches: PatchList) !void {
    for (patches.items) |a_patch| {
        try a_patch.writeText(writer);
    }
}

/// Parse a textual representation of patches and return a List of Patch
/// objects.
/// @param textline Text representation of patches.
/// @return List of Patch objects.
/// @throws ArgumentException If invalid input.
pub fn patchListFromText(allocator: Allocator, text: []const u8) DiffError!PatchList {
    if (text.len == 0) return .empty;
    var patches: PatchList = .empty;
    errdefer deinitPatchList(allocator, &patches);
    var cursor: usize = 0;
    while (cursor < text.len) {
        // TODO catch BadPatchString here and print diagnostic
        try patches.ensureUnusedCapacity(allocator, 1);
        const cursor_delta, const patch = try patchFromHeader(allocator, text[cursor..]);
        cursor += cursor_delta;
        patches.appendAssumeCapacity(patch);
    }
    return patches;
}

pub fn patchFromHeader(allocator: Allocator, text: []const u8) DiffError!struct { usize, Hunk } {
    var patch = Hunk{ .diffs = .empty };
    errdefer patch.deinit(allocator);
    var cursor: usize = undefined;
    if (std.mem.eql(u8, text[0..4], PATCH_HEAD)) {
        // Parse location and length in before text
        const count = 4 + countDigits(text[4..]);
        if (count == 4) return error.BadPatchString;
        patch.start1 = std.fmt.parseInt(
            usize,
            text[4..count],
            10,
        ) catch return error.BadPatchString;
        cursor = count;
        if (text[cursor] != ',') {
            patch.start1 -= 1;
            patch.length1 = 1;
        } else {
            cursor += 1;
            const delta = countDigits(text[cursor..]);
            patch.length1 = std.fmt.parseInt(
                usize,
                text[cursor .. cursor + delta],
                10,
            ) catch return error.BadPatchString;
            if (delta == 0) return error.BadPatchString;
            cursor += delta;
            if (patch.length1 != 0) {
                patch.start1 -= 1;
            }
        }
    } else return error.BadPatchString;
    // Parse location and length in after text.
    if (text[cursor] == ' ' and text[cursor + 1] == '+') {
        cursor += 2;
        const delta1 = countDigits(text[cursor..]);
        if (delta1 == 0) return error.BadPatchString;
        patch.start2 = std.fmt.parseInt(
            usize,
            text[cursor .. cursor + delta1],
            10,
        ) catch return error.BadPatchString;
        cursor += delta1;
        if (text[cursor] != ',') {
            patch.start2 -= 1;
            patch.length2 = 1;
        } else {
            cursor += 1;
            const delta2 = countDigits(text[cursor..]);
            if (delta2 == 0) return error.BadPatchString;
            patch.length2 = std.fmt.parseInt(
                usize,
                text[cursor .. cursor + delta2],
                10,
            ) catch return error.BadPatchString;
            cursor += delta2;
            if (patch.length2 != 0) {
                patch.start2 -= 1;
            }
        }
    } else return error.BadPatchString;
    if (cursor + 4 <= text.len and std.mem.eql(u8, text[cursor .. cursor + 4], PATCH_TAIL)) {
        cursor += 4;
    } else return error.BadPatchString;
    // Eat the diffs
    var patch_lines = std.mem.splitScalar(
        u8,
        text[cursor..],
        '\n',
    );
    // `splitScalar` means blank lines, but we need that to
    // track the cursor.
    patch_loop: while (patch_lines.next()) |line| {
        cursor += line.len + 1;
        if (line.len == 0) continue;
        // Microsoft encodes spaces as +, we don't, so we don't need this:
        // line = line.Replace("+", "%2b");
        const diff_line = decodeUri(allocator, line[1..]) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => return error.BadPatchString,
            }
        };
        errdefer allocator.free(diff_line);
        switch (line[0]) {
            '+' => { // Insertion
                try patch.diffs.append(
                    allocator,
                    Edit{
                        .operation = .insert,
                        .text = diff_line,
                    },
                );
            },
            '-' => { // Deletion
                try patch.diffs.append(
                    allocator,
                    Edit{
                        .operation = .delete,
                        .text = diff_line,
                    },
                );
            },
            ' ' => { // Minor equality
                try patch.diffs.append(
                    allocator,
                    Edit{
                        .operation = .equal,
                        .text = diff_line,
                    },
                );
            },
            '@' => { // Start of next patch
                // back out cursor
                allocator.free(diff_line);
                cursor -= line.len + 1;
                break :patch_loop;
            },
            else => return error.BadPatchString,
        }
    } // end while
    return .{ cursor, patch };
}

/// Decode our URI-esque escaping
pub fn decodeUri(allocator: Allocator, line: []const u8) DiffError![]const u8 {
    if (std.mem.indexOf(u8, line, "%")) |first| {
        // Text to decode.
        // Result will always be shorter than line:
        var new_line = try ArrayList(u8).initCapacity(allocator, line.len);
        defer new_line.deinit();
        try new_line.appendSlice(line[0..first]);
        var out_buf: [1]u8 = .{0};
        var codeunit = std.fmt.hexToBytes(
            &out_buf,
            line[first + 1 .. first + 3],
        ) catch return error.BadPatchString;
        try new_line.append(codeunit[0]);
        var cursor = first + 3;
        while (std.mem.indexOfScalarPos(u8, line, cursor, '%')) |next| {
            try new_line.appendSlice(line[cursor..next]);
            codeunit = std.fmt.hexToBytes(
                &out_buf,
                line[next + 1 .. next + 3],
            ) catch return error.BadPatchString;
            try new_line.append(codeunit[0]);
            cursor = next + 3;
        } else {
            try new_line.appendSlice(line[cursor..]);
        }
        return new_line.toOwnedSlice();
    } else {
        return allocator.dupe(u8, line);
    }
}

///
/// Borrowed from https://github.com/elerch/aws-sdk-for-zig/blob/master/src/aws_http.zig
/// under the MIT license. Thanks!
///
/// Modified to implement Unidiff escaping, documented here:
/// https://github.com/google/diff-match-patch/wiki/Unidiff
///
/// The documentation reads:
///
/// > Special characters are encoded using %xx notation. The set of
/// > characters which are encoded matches JavaScript's `encodeURI()`
/// > function, with the exception of spaces which are not encoded.
///
/// So we encode everything but the characters defined by Moz:
/// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/encodeURI
///
/// These:  !#$&'()*+,-./:;=?@_~  (and alphanumeric ASCII)
///
/// There is a nice contiguous run of 10 symbols between `&` and `/`, which we
/// can test in two comparisons, leaving these assorted:
///
///     !#$:;=?@_~
///
/// Each URI encoded byte is formed by a '%' and the two-digit
/// hexadecimal value of the byte.
///
/// Letters in the hexadecimal value must be uppercase, for example "%1A".
///
pub fn writeUriEncoded(writer: anytype, text: []const u8) !usize {
    const remaining_characters = "!#$:;=?@_~";
    var written: usize = 0;
    for (text) |c| {
        const should_encode = should: {
            if (c == ' ' or std.ascii.isAlphanumeric(c)) {
                break :should false;
            }
            if ('&' <= c and c <= '/') {
                break :should false;
            }
            for (remaining_characters) |r| {
                if (r == c) {
                    break :should false;
                }
            }
            break :should true;
        };

        if (!should_encode) {
            try writer.writeByte(c);
            written += 1;
            continue;
        }
        // Whatever remains, encode it
        try writer.writeByte('%');
        written += 1;
        const hexen = std.fmt.bytesToHex(&[_]u8{c}, .upper);
        written += try writer.write(&hexen);
    }
    return written;
}

fn encodeUri(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var charlist = try ArrayList(u8).initCapacity(allocator, text.len);
    defer charlist.deinit();
    const writer = charlist.writer();
    _ = try writeUriEncoded(writer, text);
    return charlist.toOwnedSlice();
}

//|
//| UTILITIES
//|

pub inline fn boolInt(b: bool) u8 {
    return @intFromBool(b);
}

inline fn is_follow(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

pub inline fn fixSplitForward(text: []const u8, i: usize) usize {
    var idx = i;
    while (idx < text.len and is_follow(text[idx])) : (idx += 1) {}
    return idx;
}

pub inline fn fixSplitBackward(text: []const u8, i: usize) usize {
    var idx = i;
    if (idx < text.len) while (idx != 0 and is_follow(text[idx])) : (idx -= 1) {};
    return idx;
}

pub inline fn cast(as: type, val: anytype) as {
    return @intCast(val);
}

fn countDigits(text: []const u8) usize {
    var idx: usize = 0;
    while (std.ascii.isDigit(text[idx])) : (idx += 1) {}
    return idx;
}

//|
//| TESTS
//|

test "encodeUri" {
    const allocator = std.testing.allocator;
    const special_chars = "!#$&'()*+,-./:;=?@_~";
    const special_encoded = try encodeUri(allocator, special_chars);
    defer allocator.free(special_encoded);
    try testing.expectEqualStrings(special_chars, special_encoded);
    const alphaspace = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const alpha_encoded = try encodeUri(allocator, alphaspace);
    defer allocator.free(alpha_encoded);
    try testing.expectEqualStrings(alphaspace, alpha_encoded);
    const to_encode = "\"%<>[\\]^`{|}δ";
    const encoded = try encodeUri(allocator, to_encode);
    defer allocator.free(encoded);
    try testing.expectEqualStrings("%22%25%3C%3E%5B%5C%5D%5E%60%7B%7C%7D%CE%B4", encoded);
    const decoded = try decodeUri(allocator, encoded);
    defer allocator.free(decoded);
    try testing.expectEqualStrings(to_encode, decoded);
}

pub fn sliceToDiffList(allocator: Allocator, diff_slice: []const Edit) !DiffList {
    var diff_list: DiffList = .empty;
    errdefer deinitDiffList(allocator, &diff_list);
    try diff_list.ensureTotalCapacity(allocator, diff_slice.len);
    for (diff_slice) |d| {
        diff_list.appendAssumeCapacity(Edit.init(
            d.operation,
            try allocator.dupe(u8, d.text),
        ));
    }
    return diff_list;
}

fn testMapSubsetEquality(left: anytype, right: anytype) !void {
    var map_iter = left.iterator();
    while (map_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        try testing.expectEqual(value, right.get(key));
    }
}
test "matchAlphabet" {
    var map = std.AutoHashMap(u8, usize).init(testing.allocator);
    defer map.deinit();
    try map.put('a', 4);
    try map.put('b', 2);
    try map.put('c', 1);
    var bitap_map = try matchAlphabet(testing.allocator, "abc");
    defer bitap_map.deinit();
    try testMapSubsetEquality(map, bitap_map);
    map.clearRetainingCapacity();
    try map.put('a', 37);
    try map.put('b', 18);
    try map.put('c', 8);
    var bitap_map2 = try matchAlphabet(testing.allocator, "abcaba");
    defer bitap_map2.deinit();
    try testMapSubsetEquality(map, bitap_map2);
}

const TBitap = struct {
    text: []const u8,
    pattern: []const u8,
    loc: usize,
    expect: ?usize,
};

fn testMatchBitap(
    allocator: Allocator,
    config: PatchConfig,
    params: TBitap,
) !void {
    const best_loc = try matchBitap(
        config,
        allocator,
        params.text,
        params.pattern,
        params.loc,
    );
    try testing.expectEqual(params.expect, best_loc);
}

test matchBitap {
    var config: PatchConfig = .{
        .match_distance = 500,
        .match_threshold = 0.5,
    };
    // Exact match #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "fgh",
                .loc = 5,
                .expect = 5,
            },
        },
    );
    // Exact match #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "fgh",
                .loc = 0,
                .expect = 5,
            },
        },
    );
    // Fuzzy match #1
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "efxhi",
                .loc = 0,
                .expect = 4,
            },
        },
    );
    // Fuzzy match #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "cdefxyhijk",
                .loc = 5,
                .expect = 2,
            },
        },
    );
    // Fuzzy match #3.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "bxy",
                .loc = 1,
                .expect = null,
            },
        },
    );
    // Overflow.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "123456789xx0",
                .pattern = "3456789x0",
                .loc = 2,
                .expect = 2,
            },
        },
    );
    //Before start match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdef",
                .pattern = "xxabc",
                .loc = 4,
                .expect = 0,
            },
        },
    );
    //
    // Beyond end match.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdef",
                .pattern = "defyy",
                .loc = 4,
                .expect = 3,
            },
        },
    );
    //  Oversized pattern.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdef",
                .pattern = "xabcdefy",
                .loc = 0,
                .expect = 0,
            },
        },
    );
    config.match_threshold = 0.4;
    // Threshold #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "efxyhi",
                .loc = 1,
                .expect = 4,
            },
        },
    );
    config.match_threshold = 0.3;
    //  Threshold #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "efxyhi",
                .loc = 1,
                .expect = null,
            },
        },
    );
    config.match_threshold = 0.0;
    //  Threshold #3.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijk",
                .pattern = "bcdef",
                .loc = 1,
                .expect = 1,
            },
        },
    );
    config.match_threshold = 0.5;
    //  Multiple select #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdexyzabcde",
                .pattern = "abccde",
                .loc = 5,
                .expect = 8,
            },
        },
    );
    config.match_distance = 10; // Strict location.
    //  Distance test #1.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijklmnopqrstuvwxyz",
                .pattern = "abcdefg",
                .loc = 1,
                .expect = 0,
            },
        },
    );
    // Distance test #2.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijklmnopqrstuvwxyz",
                .pattern = "abcdxxefg",
                .loc = 1,
                .expect = 0,
            },
        },
    );
    config.match_distance = 1000; // Loose location.
    //  Distance test #3.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testMatchBitap,
        .{
            config,
            TBitap{
                .text = "abcdefghijklmnopqrstuvwxyz",
                .pattern = "abcdefg",
                .loc = 24,
                .expect = 0,
            },
        },
    );
}

test matchMain {
    var config: PatchConfig = .{
        .match_threshold = 0.5,
        .match_distance = 100,
    };
    const allocator = testing.allocator;
    // Equality.
    try testing.expectEqual(0, matchMain(
        config,
        allocator,
        "abcdefg",
        "abcdefg",
        1000,
    ));
    // Null text
    try testing.expectEqual(null, matchMain(
        config,
        allocator,
        "",
        "abcdefg",
        1,
    ));
    // Null pattern.
    try testing.expectEqual(3, matchMain(
        config,
        allocator,
        "abcdefg",
        "",
        3,
    ));
    // Exact match.
    try testing.expectEqual(3, matchMain(
        config,
        allocator,
        "abcdefg",
        "de",
        3,
    ));
    // Beyond end match.
    try testing.expectEqual(3, matchMain(
        config,
        allocator,
        "abcdef",
        "defy",
        4,
    ));

    // Oversized pattern.
    try testing.expectEqual(0, matchMain(
        config,
        allocator,
        "abcdef",
        "abcdefy",
        0,
    ));
    config.match_threshold = 0.7;
    // Complex match.
    try testing.expectEqual(4, matchMain(
        config,
        allocator,
        "I am the very model of a modern major general.",
        " that berry ",
        5,
    ));
    config.match_threshold = 0.5;
}

const std = @import("std");
const dmp = @import("../dmp.zig");
const Diff = @import("Diff.zig");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.array_list.Managed;
const Patch = @This();

// Triage: almost all of this should be removed, figure out what has to stay
const DiffError = dmp.DiffError;
const Edit = Diff.Edit;
const DiffConfig = Diff.DiffConfig;
const DiffList = Diff.DiffList;
const deinitDiffList = Diff.deinitDiffList;
