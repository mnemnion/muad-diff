//! The default `Differ` specialization and its `Diff` result type.
//!
//! A `Differ` compares texts and returns a `Diff` containing the resulting
//! `DiffList` of `Edit` values.
//!
//! `Differ` has several configurable parameters. Use `.default` for the
//! default configuration, or `.init(cfg)` to provide a custom `DiffConfig`.
//!
//! `DiffConfig` controls how the diff is produced:
//! - `edit_cost` tunes the efficiency cleanup heuristics.
//! - `check_segments` enables the initial segment-mode speedup for large inputs.
//! - `check_segment_threshold` sets the minimum input size for that speedup.
//!
//! To produce a diff:
//!
//!     var differ: Differ = .default;
//!     var diff = try differ.diff(allocator, before, after);
//!     defer diff.deinit(allocator);
//!
//! The diffing algorithm only allocates memory when it has to, so most of a
//! typical diff will consist of views into the compared strings.  These must
//! therefore stay in memory, or at your option, you may call `.own(allocator)`
//! to own that memory.
//!

pub const ZDeltaEncodeError = zdelta_mod.ZDeltaEncodeError;
pub const ZDeltaDecodeError = zdelta_mod.ZDeltaDecodeError;

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

pub const DiffList = ArrayListUnmanaged(Edit);

/// A completed difference between two texts.
pub const Diff = struct {
    /// The individual edits making up this difference.
    edits: DiffList,

    /// An empty difference.
    pub const empty: Diff = .{ .edits = .empty };

    /// Own all edits in the `Diff`. After this operation it is safe to
    /// dispose of the original strings.
    pub fn own(difference: *Diff, allocator: Allocator) OOM!void {
        for (difference.edits.items) |*edit| {
            try edit.own(allocator);
        }
    }

    /// Clone this `Diff`, including its owned edits.
    pub fn clone(difference: *const Diff, allocator: Allocator) OOM!Diff {
        return .{ .edits = try common.cloneDiffList(allocator, &difference.edits) };
    }

    /// Make a copy of the `Diff`, preserving edit ownership status.
    pub fn copy(difference: *const Diff, allocator: Allocator) OOM!Diff {
        return .{ .edits = try common.copyDiffList(allocator, &difference.edits) };
    }

    /// Release the storage owned by this `Diff`.
    pub fn deinit(difference: *Diff, allocator: Allocator) void {
        common.deinitDiffList(allocator, &difference.edits);
        difference.edits = .empty;
    }

    /// Return text representing a pretty-formatted `Diff`.
    /// See `DiffDecorations` for how to customize this output.
    pub fn prettyFormat(difference: *const Diff, allocator: Allocator, deco: DiffDecorations) ![]const u8 {
        return diffPrettyFormat(allocator, difference.edits, deco);
    }

    /// Return text representing a pretty-formatted `DiffList`, in Xterm format.
    pub fn prettyFormatXTerm(difference: *const Diff, allocator: Allocator) ![]const u8 {
        return diffPrettyFormatXTerm(allocator, difference.edits);
    }

    /// Write a pretty-formatted `Diff` to `writer`. The `Allocator`
    /// is only used if a custom text formatter is defined for
    /// `DiffDecorations`. Returns number of bytes written.
    pub fn writePrettyFormat(
        difference: *const Diff,
        allocator: Allocator,
        writer: anytype,
        deco: DiffDecorations,
    ) !usize {
        return writeDiffPrettyFormat(allocator, writer, difference.edits, deco);
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

    /// Write a Diff in a zDelta format. Currently supported are
    /// formats `.a` and `.b`, see documentation for more details.
    pub fn toZDelta(
        difference: *const Diff,
        allocator: Allocator,
        version: ZDeltaVersion,
    ) ZDeltaEncodeError![]const u8 {
        return zdelta_mod.encode(allocator, difference.edits, version);
    }

    /// Populate a Diff from a zDelta string and the before text.
    pub fn fromZDelta(
        difference: *Diff,
        allocator: Allocator,
        before: []const u8,
        zdelta: []const u8,
    ) ZDeltaDecodeError!void {
        var edits = try zdelta_mod.toDiffList(Edit, DiffList, allocator, before, zdelta);
        errdefer common.deinitDiffList(allocator, &edits);
        if (difference.edits.items.len != 0) {
            common.deinitDiffList(allocator, &difference.edits);
        }
        difference.edits = edits;
    }

    /// Compute and return the source text (all equalities and deletions).
    pub fn beforeText(difference: Diff, allocator: Allocator) OOM![]const u8 {
        return common.diffBeforeText(allocator, difference.edits);
    }

    /// Compute and return the destination text (all equalities and insertions).
    pub fn afterText(difference: Diff, allocator: Allocator) OOM![]const u8 {
        return common.diffAfterText(allocator, difference.edits);
    }

    /// loc is a location in text1; compute and return the equivalent
    /// location in text2.
    pub fn index(difference: Diff, loc: usize) usize {
        return common.diffIndex(difference.edits, loc);
    }

    /// Answers the number of bytes total be added or removed by
    /// applying this difference.
    pub fn changeInBytes(difference: *const Diff) isize {
        var count: isize = 0;
        for (difference.edits.items) |edit| {
            switch (edit.operation) {
                .insert => count += common.u2i(edit.text.len),
                .delete => count -= common.u2i(edit.text.len),
                .equal => {},
            }
        }
        return count;
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

/// The default text differ.
pub const Differ = diff_fn_mod.DiffFn(.{
    .context = void,
    .SegmentIterator = LineIterator,
    .fixSegmentBackward = fixLineSegmentBackward,
    .fixSegmentForward = fixLineSegmentForward,
    .semanticScore = diffCleanupSemanticScore,
});

/// See `DiffDecorations` for how to customize this output.
fn diffPrettyFormat(
    allocator: Allocator,
    diffs: DiffList,
    deco: DiffDecorations,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = try writeDiffPrettyFormat(allocator, &out.writer, diffs, deco);
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

//| DMP DiffFn specialization

pub const LineIterator = struct {
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

fn fixLineSegmentBackward(_: *void, text: []const u8, _: diff_fn_mod.WhichText) usize {
    const newline = std.mem.lastIndexOfScalar(u8, text, '\n') orelse return 0;
    return newline + 1;
}

fn fixLineSegmentForward(_: *void, text: []const u8, _: diff_fn_mod.WhichText) usize {
    const newline = std.mem.indexOfScalar(u8, text, '\n') orelse return text.len;
    return newline + 1;
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

    const left_trimmed = std.mem.trimStart(u8, text, &std.ascii.whitespace);
    const leading_len = text.len - left_trimmed.len;
    if (leading_len != 0) {
        written += try writer.write(markers.ws_start);
        written += try writer.write(text[0..leading_len]);
        written += try writer.write(markers.ws_end);
    }

    const fully_trimmed = std.mem.trimEnd(u8, left_trimmed, &std.ascii.whitespace);
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

fn preProcessUpper(allocator: Allocator, edit: Edit) OOM![]const u8 {
    const text = try allocator.dupe(u8, edit.text);
    for (text) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return text;
}

fn testWriteDecoratedEditPreProcess(allocator: Allocator) !void {
    var buffer: [32]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    const written = try writeDecoratedEdit(
        allocator,
        &out,
        .{
            .insert_start = "<ins>",
            .insert_end = "</ins>",
            .pre_process = preProcessUpper,
        },
        Edit.asBorrow(.insert, "abc"),
    );

    try testing.expectEqual(@as(usize, 14), written);
    try testing.expectEqualStrings("<ins>ABC</ins>", buffer[0..out.end]);
}

test "writeDecoratedEdit frees pre-processed text" {
    try testing.checkAllAllocationFailures(testing.allocator, testWriteDecoratedEditPreProcess, .{});
}

test "default Differ fixes segment splits to line boundaries" {
    var context: void = {};
    try testing.expectEqual(@as(usize, 6), fixLineSegmentBackward(&context, "alpha\nomega", .before));
    try testing.expectEqual(@as(usize, 0), fixLineSegmentBackward(&context, "alpha", .after));
    try testing.expectEqual(@as(usize, 6), fixLineSegmentForward(&context, "alpha\nomega", .before));
    try testing.expectEqual(@as(usize, 5), fixLineSegmentForward(&context, "alpha", .after));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const diff_fn_mod = @import("../diff_fn.zig");
const common = @import("common.zig");
const Patch = @import("Patch.zig");
const PatchConfig = Patch.PatchConfig;
const zdelta_mod = @import("../zdelta.zig");
const ZDeltaVersion = zdelta_mod.ZDeltaVersion;
const testing = std.testing;
pub const diffCleanupSemanticScore = common.diffCleanupSemanticScore;
