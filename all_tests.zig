const std = @import("std");

pub const all_tests_root = true;

const muad_diff = @import("src/muad_diff.zig");
const dmp_root = @import("src/dmp.zig");
const zdelta = @import("src/zdelta.zig");
const driff = @import("src/driff.zig");
const corpus_tests = @import("src/corpus_tests.zig");
const diff_fn = @import("src/diff_fn.zig");
const patch = @import("src/dmp/Patch.zig");
const diff = @import("src/dmp/diff.zig");
const diff_context = @import("src/diff_context.zig");

comptime {
    std.testing.refAllDecls(muad_diff);
    std.testing.refAllDecls(dmp_root);
    std.testing.refAllDecls(zdelta);
    std.testing.refAllDecls(driff);
    std.testing.refAllDecls(corpus_tests);
    std.testing.refAllDecls(diff_fn);
    std.testing.refAllDecls(patch);
    std.testing.refAllDecls(diff);
    std.testing.refAllDecls(diff_context);
}
