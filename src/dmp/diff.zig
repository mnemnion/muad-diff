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
    /// Cost of an empty edit operation in terms of edit characters.  Higher
    /// values lead to fewer, larger edit chunks.
    edit_cost: u16,
    /// If true, use the initial line-mode speedup when inputs are large enough.
    /// This is generally faster, but can result in non-minimal diffs.
    check_lines: bool,
    /// Number of bytes in each string needed to trigger a line-based diff.
    /// Ignored if check_lines is `false`.
    check_line_threshold: u32,

    /// Reasonable defaults for diffing: use line mode in most cases (4K
    /// strings), with an edit cost which prevents most chaff.
    pub const default: DiffConfig = .{
        .edit_cost = 4,
        .check_lines = true,
        .check_line_threshold = 4096,
    };
};

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

pub const Diff = diff_fn_mod.DiffFn(.{
    .context = void,
    .LineIterator = LineIterator,
    .semanticScore = diffCleanupSemanticScore,
});

/// File-public, not module-public.  Just a synonym in any case.
pub const DiffList = ArrayListUnmanaged(Edit);

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

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const diff_fn_mod = @import("../diff_fn.zig");
const common = @import("common.zig");
const zdelta_mod = @import("../zdelta.zig");
const testing = std.testing;
pub const diffCleanupSemanticScore = common.diffCleanupSemanticScore;
