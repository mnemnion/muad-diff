//! DiffMatchPatch Library
//!
//! A port of the old-school letter diff library, diff-match-patch.
//!
//! Now with Zig characteristics.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.array_list.Managed;

const diff_mod = @import("dmp/diff.zig");
const diff_fn_mod = @import("diff_fn.zig");
const diff_context_mod = @import("diff_context.zig");
const zdelta_mod = @import("zdelta.zig");

/// The default text differ.
pub const Differ = diff_mod.Differ;
/// A difference produced by the default `Differ`.
pub const Diff = diff_mod.Diff;
pub const DiffFn = diff_fn_mod.DiffFn;
pub const WhichText = diff_fn_mod.WhichText;
pub const Edit = diff_mod.Edit;
pub const DiffConfig = diff_fn_mod.DiffConfig;
pub const DiffDecorations = diff_mod.DiffDecorations;
pub const ZDeltaVersion = zdelta_mod.ZDeltaVersion;
pub const ZDeltaEncodeError = zdelta_mod.ZDeltaEncodeError;
pub const ZDeltaDecodeError = zdelta_mod.ZDeltaDecodeError;
pub const ZDelta = zdelta_mod.ZDelta;
pub const DeltaOp = zdelta_mod.DeltaOp;
pub const DeltaApplicator = zdelta_mod.DeltaApplicator;
pub const decode = zdelta_mod.decode;
pub const streamApply = zdelta_mod.streamApply;
pub const writeDecoratedEdit = diff_mod.writeDecoratedEdit;
pub const DiffContext = diff_context_mod;
pub const Patch = @import("dmp/Patch.zig");

test {
    _ = Differ;
    _ = Diff;
    _ = DiffFn(.{});
    _ = diff_fn_mod.TestDiffer;
    _ = DiffContext;
    _ = Patch;
}
