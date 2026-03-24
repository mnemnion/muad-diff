//! Offline corpus-backed tests for multilingual revision fixtures.

const corpus_root = "testdata/corpus";

const FixtureError = error{
    MissingOpeningFrontmatter,
    MissingClosingFrontmatter,
    MissingBody,
    MissingLanguage,
    MissingTitle,
    MissingTimestamp,
    MissingRevisionId,
    BadMetadataLine,
    UnsupportedValue,
};

const RevisionFixture = struct {
    /// Relative path from the corpus root to this revision fixture file.
    relative_path: []const u8,
    /// Directory grouping used to collect adjacent revisions into one history.
    group: []const u8,
    /// Language tag recorded in the fixture frontmatter.
    language: []const u8,
    /// Article title or synthetic fixture title from the source metadata.
    title: []const u8,
    /// ISO 8601 revision timestamp used for deterministic ordering.
    timestamp: []const u8,
    /// Username or synthetic actor recorded for the revision.
    user: []const u8,
    /// Edit summary or synthetic comment associated with the revision.
    comment: []const u8,
    /// Fixture origin, currently `wikipedia` or `synthetic`.
    origin: []const u8,
    /// Stable article identifier used in the checked-in corpus layout.
    article_slug: []const u8,
    /// Raw wikitext body stored after the frontmatter block.
    body: []const u8,
    /// Revision identifier from Wikipedia or the synthetic corpus generator.
    revid: u64,
    /// Parent revision identifier when available.
    parentid: ?u64,
    /// Declared source text size from the fixture metadata.
    size: usize,
    /// Minor-edit marker carried over from the source metadata.
    minor: bool,
};

fn lessThanRevision(_: void, lhs: RevisionFixture, rhs: RevisionFixture) bool {
    const group_order = std.mem.order(u8, lhs.group, rhs.group);
    if (group_order != .eq) {
        return group_order == .lt;
    }

    const timestamp_order = std.mem.order(u8, lhs.timestamp, rhs.timestamp);
    if (timestamp_order != .eq) {
        return timestamp_order == .lt;
    }

    return lhs.revid < rhs.revid;
}

fn trimAscii(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, &std.ascii.whitespace);
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return FixtureError.UnsupportedValue;
}

fn parseQuotedString(arena: Allocator, raw_value: []const u8) ![]const u8 {
    if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') {
        return FixtureError.UnsupportedValue;
    }

    return try std.json.parseFromSliceLeaky([]const u8, arena, raw_value, .{});
}

fn parseFrontmatter(
    arena: Allocator,
    revision: *RevisionFixture,
    frontmatter: []const u8,
) !void {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = trimAscii(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            return FixtureError.BadMetadataLine;
        };
        const key = trimAscii(trimmed[0..eq_index]);
        const value = trimAscii(trimmed[eq_index + 1 ..]);

        if (std.mem.eql(u8, key, "language")) {
            revision.language = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "title")) {
            revision.title = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "timestamp")) {
            revision.timestamp = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "user")) {
            revision.user = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "comment")) {
            revision.comment = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "origin")) {
            revision.origin = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "article_slug")) {
            revision.article_slug = try parseQuotedString(arena, value);
        } else if (std.mem.eql(u8, key, "revid")) {
            revision.revid = try std.fmt.parseUnsigned(u64, value, 10);
        } else if (std.mem.eql(u8, key, "parentid")) {
            if (std.mem.eql(u8, value, "null")) {
                revision.parentid = null;
            } else {
                revision.parentid = try std.fmt.parseUnsigned(u64, value, 10);
            }
        } else if (std.mem.eql(u8, key, "size")) {
            revision.size = try std.fmt.parseUnsigned(usize, value, 10);
        } else if (std.mem.eql(u8, key, "minor")) {
            revision.minor = try parseBool(value);
        }
    }
}

fn parseFixture(
    arena: Allocator,
    relative_path: []const u8,
    file_data: []const u8,
) !RevisionFixture {
    if (!std.mem.startsWith(u8, file_data, "---\n")) {
        return FixtureError.MissingOpeningFrontmatter;
    }

    const closing_rel = std.mem.indexOf(u8, file_data[4..], "\n---\n") orelse {
        return FixtureError.MissingClosingFrontmatter;
    };
    const frontmatter_end = 4 + closing_rel;
    const body = file_data[frontmatter_end + "\n---\n".len ..];
    if (body.len == 0) {
        return FixtureError.MissingBody;
    }

    const group = std.fs.path.dirname(relative_path) orelse ".";
    var revision = RevisionFixture{
        .relative_path = try arena.dupe(u8, relative_path),
        .group = try arena.dupe(u8, group),
        .language = "",
        .title = "",
        .timestamp = "",
        .user = "",
        .comment = "",
        .origin = "",
        .article_slug = "",
        .body = try arena.dupe(u8, body),
        .revid = 0,
        .parentid = null,
        .size = body.len,
        .minor = false,
    };

    try parseFrontmatter(arena, &revision, file_data[4..frontmatter_end]);

    if (revision.language.len == 0) return FixtureError.MissingLanguage;
    if (revision.title.len == 0) return FixtureError.MissingTitle;
    if (revision.timestamp.len == 0) return FixtureError.MissingTimestamp;
    if (revision.revid == 0) return FixtureError.MissingRevisionId;

    return revision;
}

fn loadCorpusFixtures(arena: Allocator) !ArrayList(RevisionFixture) {
    var fixtures = ArrayList(RevisionFixture).init(arena);
    errdefer fixtures.deinit();

    var dir = try std.fs.cwd().openDir(corpus_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wiki")) continue;

        const file_data = try dir.readFileAlloc(arena, entry.path, std.math.maxInt(usize));
        const revision = try parseFixture(arena, entry.path, file_data);
        try fixtures.append(revision);
    }

    std.sort.heap(RevisionFixture, fixtures.items, {}, lessThanRevision);
    return fixtures;
}

//| Tests

const testing = std.testing;

fn containsFourByteCodepoint(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return false;
        if (len == 4) return true;
        i += len;
    }
    return false;
}

fn expectValidUtf8(text: []const u8) !void {
    try testing.expect(std.unicode.utf8ValidateSlice(text));
}

fn expectDiffListUtf8(diffs: dmp.DiffList) !void {
    for (diffs.items) |diff| {
        try expectValidUtf8(diff.text);
    }
}

fn expectPatchUtf8(patches: dmp.PatchList) !void {
    for (patches.items) |patch| {
        try expectDiffListUtf8(patch.diffs);
    }
}

fn expectPatchesEqual(expected: dmp.PatchList, actual: dmp.PatchList) !void {
    try testing.expectEqual(expected.items.len, actual.items.len);

    for (expected.items, actual.items) |expected_patch, actual_patch| {
        try testing.expectEqual(expected_patch.start1, actual_patch.start1);
        try testing.expectEqual(expected_patch.length1, actual_patch.length1);
        try testing.expectEqual(expected_patch.start2, actual_patch.start2);
        try testing.expectEqual(expected_patch.length2, actual_patch.length2);
        try testing.expectEqualDeep(expected_patch.diffs.items, actual_patch.diffs.items);
    }
}

fn assertRevisionPairInvariant(
    diff_config: dmp.DiffConfig,
    patch_config: dmp.PatchConfig,
    before: RevisionFixture,
    after: RevisionFixture,
) !void {
    var diff = dmp.Diff.initOptions(diff_config);
    defer diff.deinit(testing.allocator);
    _ = try diff.diff(testing.allocator, before.body, after.body);
    try expectDiffListUtf8(diff.edits);

    const rebuilt_before = try diff.beforeText(testing.allocator);
    defer testing.allocator.free(rebuilt_before);
    try testing.expectEqualStrings(before.body, rebuilt_before);

    const rebuilt_after = try diff.afterText(testing.allocator);
    defer testing.allocator.free(rebuilt_after);
    try testing.expectEqualStrings(after.body, rebuilt_after);

    var patches = dmp.Patch.initOptions(patch_config);
    defer patches.deinit(testing.allocator);
    _ = try patches.make(testing.allocator, before.body, diff.edits);
    try expectPatchUtf8(patches.hunks);

    const patch_text = try patches.toText(testing.allocator);
    defer testing.allocator.free(patch_text);
    try expectValidUtf8(patch_text);

    var reparsed_patches = dmp.Patch.init();
    defer reparsed_patches.deinit(testing.allocator);
    _ = try reparsed_patches.fromText(testing.allocator, patch_text);
    try expectPatchUtf8(reparsed_patches.hunks);
    try expectPatchesEqual(patches.hunks, reparsed_patches.hunks);

    const patched_text, const success = try patches.apply(testing.allocator, before.body);
    defer testing.allocator.free(patched_text);
    try testing.expect(success);
    try testing.expectEqualStrings(after.body, patched_text);
}

test "corpus parser rejects malformed fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(
        FixtureError.MissingClosingFrontmatter,
        parseFixture(
            arena,
            "broken/example.wiki",
            "---\nlanguage = \"en\"\nrevid = 1\n",
        ),
    );
}

test "corpus parser requires a body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(
        FixtureError.MissingBody,
        parseFixture(
            arena,
            "broken/example.wiki",
            "---\nlanguage = \"en\"\ntitle = \"Example\"\ntimestamp = \"2024-01-01T00:00:00Z\"\nrevid = 1\n---\n",
        ),
    );
}

test "corpus fixtures load and include multilingual plus emoji coverage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fixtures = try loadCorpusFixtures(arena);
    defer fixtures.deinit();

    try testing.expect(fixtures.items.len >= 25);

    var saw_en = false;
    var saw_el = false;
    var saw_zh = false;
    var saw_ja = false;
    var saw_emoji = false;

    for (fixtures.items) |fixture| {
        if (std.mem.eql(u8, fixture.language, "en")) saw_en = true;
        if (std.mem.eql(u8, fixture.language, "el")) saw_el = true;
        if (std.mem.eql(u8, fixture.language, "zh")) saw_zh = true;
        if (std.mem.eql(u8, fixture.language, "ja")) saw_ja = true;
        if (std.mem.eql(u8, fixture.origin, "synthetic")) {
            saw_emoji = saw_emoji or containsFourByteCodepoint(fixture.body);
        }
    }

    try testing.expect(saw_en);
    try testing.expect(saw_el);
    try testing.expect(saw_zh);
    try testing.expect(saw_ja);
    try testing.expect(saw_emoji);
}

test "corpus revision pairs satisfy diff and patch invariants" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const diff_config: dmp.DiffConfig = .{ .check_line_threshold = 1024 * 1024, .timeout = 0 };
    const patch_config: dmp.PatchConfig = .{};

    var fixtures = try loadCorpusFixtures(arena);
    defer fixtures.deinit();

    var pair_count: usize = 0;
    var i: usize = 1;
    while (i < fixtures.items.len) : (i += 1) {
        const before = fixtures.items[i - 1];
        const after = fixtures.items[i];
        if (!std.mem.eql(u8, before.group, after.group)) continue;

        try assertRevisionPairInvariant(diff_config, patch_config, before, after);
        pair_count += 1;
    }

    try testing.expect(pair_count >= 20);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const dmp = @import("dmp.zig");
