//! Contract for the checked-in diff corpus.
//!
//! The `.wiki` fixtures and `.zdset` batches under `corpus/diff` are currently
//! a development-time contract for `delta-tool` and friends. The data stays in
//! the corpus tree, but the policy for finding and interpreting it lives here
//! so callers do not each grow their own idea of "the corpus layout".

pub const corpus_diff_root = "corpus/diff";
pub const default_runs_path = corpus_diff_root ++ "/delta_tool.runs";

pub const CorpusRevision = struct {
    ordinal: usize,
    relative_path: []u8,
    body: []u8,
    zdelta: ?[]u8 = null,

    pub fn deinit(revision: *CorpusRevision, allocator: Allocator) void {
        allocator.free(revision.relative_path);
        allocator.free(revision.body);
        if (revision.zdelta) |delta| allocator.free(delta);
        revision.* = undefined;
    }
};

pub const CorpusSelection = struct {
    revisions: []CorpusRevision,

    pub fn deinit(selection: *CorpusSelection, allocator: Allocator) void {
        for (selection.revisions) |*revision| revision.deinit(allocator);
        allocator.free(selection.revisions);
        selection.* = undefined;
    }
};

pub fn loadCheckedInSelection(
    allocator: Allocator,
    start_revision: usize,
    end_revision: usize,
) !CorpusSelection {
    return loadSelectionAtPath(allocator, corpus_diff_root, start_revision, end_revision);
}

pub fn loadSelectionAtPath(
    allocator: Allocator,
    corpus_root: []const u8,
    start_revision: usize,
    end_revision: usize,
) !CorpusSelection {
    var relative_paths = try collectSortedCorpusWikiPathsAtPath(allocator, corpus_root);
    defer deinitOwnedStrings(allocator, &relative_paths);

    if (relative_paths.items.len == 0) return error.EmptyCorpus;
    if (end_revision > relative_paths.items.len) return error.RevisionOrdinalOutOfRange;

    const count = end_revision - start_revision + 1;
    var revisions = try allocator.alloc(CorpusRevision, count);
    var initialized: usize = 0;
    errdefer {
        for (revisions[0..initialized]) |*revision| revision.deinit(allocator);
        allocator.free(revisions);
    }

    var corpus_dir = try openCorpusDir(corpus_root, .{});
    defer corpus_dir.close();

    for (revisions, 0..) |*revision, idx| {
        const ordinal = start_revision + idx;
        const relative_path = relative_paths.items[ordinal - 1];
        const file_data = try corpus_dir.readFileAlloc(allocator, relative_path, std.math.maxInt(usize));
        defer allocator.free(file_data);

        revision.* = .{
            .ordinal = ordinal,
            .relative_path = try allocator.dupe(u8, relative_path),
            .body = try allocator.dupe(u8, try fixtureBody(file_data)),
            .zdelta = null,
        };
        initialized += 1;
    }

    try loadSelectionZDeltasAtPath(allocator, corpus_root, revisions);
    return .{ .revisions = revisions };
}

pub fn fixtureBody(file_data: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, file_data, "---\n")) return error.MissingOpeningFrontmatter;
    const closing_rel = std.mem.indexOf(u8, file_data[4..], "\n---\n") orelse {
        return error.MissingClosingFrontmatter;
    };
    const start = 4 + closing_rel + "\n---\n".len;
    return file_data[start..];
}

pub fn collectSortedCorpusWikiPaths(allocator: Allocator) !ArrayList([]u8) {
    return collectSortedCorpusWikiPathsAtPath(allocator, corpus_diff_root);
}

pub fn collectSortedCorpusWikiPathsAtPath(
    allocator: Allocator,
    corpus_root: []const u8,
) !ArrayList([]u8) {
    var paths = ArrayList([]u8).init(allocator);
    errdefer deinitOwnedStrings(allocator, &paths);

    var dir = try openCorpusDir(corpus_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wiki")) continue;
        try paths.append(try allocator.dupe(u8, entry.path));
    }

    std.sort.heap([]u8, paths.items, {}, lessThanString);
    return paths;
}

pub fn collectSortedBatchNames(allocator: Allocator, root_dir: std.fs.Dir) !ArrayList([]u8) {
    var names = ArrayList([]u8).init(allocator);
    errdefer deinitOwnedStrings(allocator, &names);

    var iterator = root_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }

    std.sort.heap([]u8, names.items, {}, lessThanString);
    return names;
}

pub fn collectSortedWikiNames(allocator: Allocator, dir: std.fs.Dir) !ArrayList([]u8) {
    var names = ArrayList([]u8).init(allocator);
    errdefer deinitOwnedStrings(allocator, &names);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wiki")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }

    std.sort.heap([]u8, names.items, {}, lessThanString);
    return names;
}

pub fn deinitOwnedStrings(allocator: Allocator, strings: *ArrayList([]u8)) void {
    for (strings.items) |item| allocator.free(item);
    strings.deinit();
}

fn loadSelectionZDeltasAtPath(
    allocator: Allocator,
    corpus_root: []const u8,
    revisions: []CorpusRevision,
) !void {
    if (revisions.len <= 1) return;

    var dir = try openCorpusDir(corpus_root, .{ .iterate = true });
    defer dir.close();

    var zdset_names = ArrayList([]u8).init(allocator);
    defer deinitOwnedStrings(allocator, &zdset_names);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zdset")) continue;
        try zdset_names.append(try allocator.dupe(u8, entry.name));
    }
    std.sort.heap([]u8, zdset_names.items, {}, lessThanString);

    var next_needed: usize = 1;
    for (zdset_names.items) |name| {
        if (next_needed >= revisions.len) break;

        const file_data = try dir.readFileAlloc(allocator, name, std.math.maxInt(usize));
        defer allocator.free(file_data);

        var line_iter = std.mem.tokenizeScalar(u8, file_data, '\n');
        var pending_path: ?[]const u8 = null;
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "# baseline ")) {
                pending_path = null;
                continue;
            }
            if (std.mem.startsWith(u8, line, "# ")) {
                pending_path = line[2..];
                continue;
            }
            const path = pending_path orelse continue;
            pending_path = null;

            while (next_needed < revisions.len and std.mem.order(u8, revisions[next_needed].relative_path, path) == .lt) {
                next_needed += 1;
            }
            if (next_needed >= revisions.len) break;
            if (!std.mem.eql(u8, revisions[next_needed].relative_path, path)) continue;

            revisions[next_needed].zdelta = try allocator.dupe(u8, line);
            next_needed += 1;
        }
    }

    for (revisions[1..]) |revision| {
        if (revision.zdelta == null) return error.MissingCorpusZDelta;
    }
}

fn openCorpusDir(path: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, flags)
    else
        std.fs.cwd().openDir(path, flags);
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

//| Tests

const testing = std.testing;

test "fixtureBody extracts only the wiki portion" {
    const body = try fixtureBody(
        "---\norigin = \"wikipedia\"\n---\nbody text\nsecond line\n",
    );

    try testing.expectEqualStrings("body text\nsecond line\n", body);
}

test "collectSortedCorpusWikiPathsAtPath sorts nested wiki fixtures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("000100-000199");
    try tmp.dir.makePath("000000-000099");
    try tmp.dir.writeFile(.{
        .sub_path = "000100-000199/20000101T000002Z_3.wiki",
        .data = "---\n---\nthree\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "000000-000099/20000101T000001Z_2.wiki",
        .data = "---\n---\ntwo\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "000000-000099/20000101T000000Z_1.wiki",
        .data = "---\n---\none\n",
    });

    const root_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(root_path);

    var names = try collectSortedCorpusWikiPathsAtPath(testing.allocator, root_path);
    defer deinitOwnedStrings(testing.allocator, &names);

    try testing.expectEqualStrings("000000-000099/20000101T000000Z_1.wiki", names.items[0]);
    try testing.expectEqualStrings("000000-000099/20000101T000001Z_2.wiki", names.items[1]);
    try testing.expectEqualStrings("000100-000199/20000101T000002Z_3.wiki", names.items[2]);
}

test "loadSelectionAtPath loads fixture bodies and matching zdset entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("000000-000099");
    try tmp.dir.writeFile(.{
        .sub_path = "000000-000099/20000101T000000Z_1.wiki",
        .data = "---\n---\none\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "000000-000099/20000101T000001Z_2.wiki",
        .data = "---\n---\none\ntwo\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "000000-000099.zdset",
        .data = "# baseline 000000-000099/20000101T000000Z_1.wiki\n" ++
            "# 000000-000099/20000101T000001Z_2.wiki\n" ++
            "delta-two\n",
    });

    const root_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(root_path);

    var selection = try loadSelectionAtPath(testing.allocator, root_path, 1, 2);
    defer selection.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), selection.revisions.len);
    try testing.expectEqualStrings("one\n", selection.revisions[0].body);
    try testing.expectEqualStrings("one\ntwo\n", selection.revisions[1].body);
    try testing.expectEqualStrings("delta-two", selection.revisions[1].zdelta.?);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
