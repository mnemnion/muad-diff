//! Build batch `.zdset` files from a corpus of `.wiki` fixtures.

const DeltaMakerError = error{
    MissingOpeningFrontmatter,
    MissingClosingFrontmatter,
    NoBatchDirectories,
    EmptyBatchDirectory,
};

/// Build `.zdset` files from a corpus root like `corpus/diff`.
pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    var stderr_buffer: [256]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try stdout_writer.interface.print("Usage: zig build delta-maker -- <corpus-root>\n", .{});
        try stdout_writer.interface.flush();
        return;
    }

    if (args.len != 2) {
        try stderr_writer.interface.print("Usage: zig build delta-maker -- <corpus-root>\n", .{});
        try stderr_writer.interface.flush();
        std.process.exit(1);
    }

    var root_dir = try std.fs.cwd().openDir(args[1], .{ .iterate = true });
    defer root_dir.close();

    try makeDeltaSets(RealCodec, gpa, root_dir, &stdout_writer.interface);
    try stdout_writer.interface.flush();
}

fn makeDeltaSets(
    comptime Codec: type,
    allocator: Allocator,
    root_dir: std.fs.Dir,
    stdout_writer: anytype,
) !void {
    var batch_names = try collectSortedBatchNames(allocator, root_dir);
    defer deinitOwnedStrings(allocator, &batch_names);

    if (batch_names.items.len == 0) return error.NoBatchDirectories;

    var have_baseline = false;
    var baseline_body: []const u8 = undefined;
    var baseline_path: []const u8 = undefined;
    defer if (have_baseline) {
        allocator.free(baseline_body);
        allocator.free(baseline_path);
    };

    for (batch_names.items) |batch_name| {
        var batch_dir = try root_dir.openDir(batch_name, .{ .iterate = true });
        defer batch_dir.close();

        var wiki_names = try collectSortedWikiNames(allocator, batch_dir);
        defer deinitOwnedStrings(allocator, &wiki_names);

        if (wiki_names.items.len == 0) return error.EmptyBatchDirectory;

        const output_name = try std.fmt.allocPrint(allocator, "{s}.zdset", .{batch_name});
        defer allocator.free(output_name);

        var output_file = try root_dir.createFile(output_name, .{ .truncate = true });
        defer output_file.close();
        var output_buffer: [4096]u8 = undefined;
        var output_writer = output_file.writer(&output_buffer);

        for (wiki_names.items) |wiki_name| {
            const relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ batch_name, wiki_name });
            defer allocator.free(relative_path);

            const file_data = try batch_dir.readFileAlloc(allocator, wiki_name, std.math.maxInt(usize));
            defer allocator.free(file_data);
            const target_body = try fixtureBody(file_data);

            if (!have_baseline) {
                baseline_body = try allocator.dupe(u8, target_body);
                baseline_path = try allocator.dupe(u8, relative_path);
                have_baseline = true;
                try output_writer.interface.print("# baseline {s}\n", .{baseline_path});
                continue;
            }

            const encoded = try Codec.encodePair(allocator, baseline_body, target_body);
            defer allocator.free(encoded);

            try output_writer.interface.print("# {s}\n{s}\n", .{ relative_path, encoded });

            const reconstructed = try Codec.apply(allocator, baseline_body, encoded);
            if (std.mem.eql(u8, reconstructed, target_body)) {
                allocator.free(baseline_body);
                baseline_body = reconstructed;
            } else {
                defer allocator.free(reconstructed);
                try stdout_writer.print("{s}\n", .{baseline_path});
                allocator.free(baseline_body);
                baseline_body = try allocator.dupe(u8, target_body);
            }

            allocator.free(baseline_path);
            baseline_path = try allocator.dupe(u8, relative_path);
        }

        try output_writer.interface.flush();
    }
}

fn fixtureBody(file_data: []const u8) DeltaMakerError![]const u8 {
    if (!std.mem.startsWith(u8, file_data, "---\n")) {
        return error.MissingOpeningFrontmatter;
    }

    const closing_rel = std.mem.indexOf(u8, file_data[4..], "\n---\n") orelse {
        return error.MissingClosingFrontmatter;
    };
    const frontmatter_end = 4 + closing_rel;
    return file_data[frontmatter_end + "\n---\n".len ..];
}

fn collectSortedBatchNames(allocator: Allocator, root_dir: std.fs.Dir) !ArrayList([]const u8) {
    var names = ArrayList([]const u8).init(allocator);
    errdefer deinitOwnedStrings(allocator, &names);

    var iterator = root_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }

    std.sort.heap([]const u8, names.items, {}, lessThanString);
    return names;
}

fn collectSortedWikiNames(allocator: Allocator, dir: std.fs.Dir) !ArrayList([]const u8) {
    var names = ArrayList([]const u8).init(allocator);
    errdefer deinitOwnedStrings(allocator, &names);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wiki")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }

    std.sort.heap([]const u8, names.items, {}, lessThanString);
    return names;
}

fn deinitOwnedStrings(allocator: Allocator, strings: *ArrayList([]const u8)) void {
    for (strings.items) |item| {
        allocator.free(item);
    }
    strings.deinit();
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const RealCodec = struct {
    fn encodePair(
        allocator: Allocator,
        before_text: []const u8,
        after_text: []const u8,
    ) ![]const u8 {
        var diff: dmp.Diff = .default;
        defer diff.deinit(allocator);
        _ = try diff.diff(allocator, before_text, after_text);
        return try diff.toZDelta(allocator, .b);
    }

    fn apply(
        allocator: Allocator,
        before_text: []const u8,
        zdelta: []const u8,
    ) ![]const u8 {
        var diff: dmp.Diff = .default;
        defer diff.deinit(allocator);
        _ = try diff.fromZDelta(allocator, before_text, zdelta);
        return try diff.afterText(allocator);
    }
};

//| Tests

const testing = std.testing;

test "fixtureBody extracts only the wiki portion" {
    const body = try fixtureBody(
        "---\norigin = \"wikipedia\"\n---\nbody text\nsecond line\n",
    );

    try testing.expectEqualStrings("body text\nsecond line\n", body);
}

test "delta maker writes zdsets and carries baseline across batches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("000000-000099");
    try tmp.dir.makePath("000100-000199");

    try writeFixture(
        tmp.dir,
        "000000-000099/20000101T000000Z_1.wiki",
        "one\n",
    );
    try writeFixture(
        tmp.dir,
        "000000-000099/20000101T000001Z_2.wiki",
        "one\ntwo\n",
    );
    try writeFixture(
        tmp.dir,
        "000100-000199/20000101T000002Z_3.wiki",
        "one\ntwo\nthree\n",
    );

    var stdout_buffer = ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    try makeDeltaSets(RealCodec, testing.allocator, tmp.dir, stdout_buffer.writer());

    try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);

    const first_output = try tmp.dir.readFileAlloc(
        testing.allocator,
        "000000-000099.zdset",
        std.math.maxInt(usize),
    );
    defer testing.allocator.free(first_output);

    const second_output = try tmp.dir.readFileAlloc(
        testing.allocator,
        "000100-000199.zdset",
        std.math.maxInt(usize),
    );
    defer testing.allocator.free(second_output);

    var first_lines = std.mem.splitScalar(u8, first_output, '\n');
    try testing.expectEqualStrings(
        "# baseline 000000-000099/20000101T000000Z_1.wiki",
        first_lines.next().?,
    );
    try testing.expectEqualStrings(
        "# 000000-000099/20000101T000001Z_2.wiki",
        first_lines.next().?,
    );
    const first_delta = first_lines.next().?;

    var second_lines = std.mem.splitScalar(u8, second_output, '\n');
    try testing.expectEqualStrings(
        "# 000100-000199/20000101T000002Z_3.wiki",
        second_lines.next().?,
    );
    const second_delta = second_lines.next().?;

    const reconstructed_first = try RealCodec.apply(testing.allocator, "one\n", first_delta);
    defer testing.allocator.free(reconstructed_first);
    try testing.expectEqualStrings("one\ntwo\n", reconstructed_first);

    const reconstructed_second = try RealCodec.apply(testing.allocator, "one\ntwo\n", second_delta);
    defer testing.allocator.free(reconstructed_second);
    try testing.expectEqualStrings("one\ntwo\nthree\n", reconstructed_second);
}

test "delta maker reports failed validation and rebases to the target body" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    FaultyCodec.failed_once = false;

    try tmp.dir.makePath("000000-000099");

    try writeFixture(
        tmp.dir,
        "000000-000099/20000101T000000Z_1.wiki",
        "alpha\n",
    );
    try writeFixture(
        tmp.dir,
        "000000-000099/20000101T000001Z_2.wiki",
        "alpha\nbeta\n",
    );
    try writeFixture(
        tmp.dir,
        "000000-000099/20000101T000002Z_3.wiki",
        "alpha\nbeta\ngamma\n",
    );

    var stdout_buffer = ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();

    try makeDeltaSets(FaultyCodec, testing.allocator, tmp.dir, stdout_buffer.writer());

    try testing.expectEqualStrings(
        "000000-000099/20000101T000000Z_1.wiki\n",
        stdout_buffer.items,
    );

    const output = try tmp.dir.readFileAlloc(
        testing.allocator,
        "000000-000099.zdset",
        std.math.maxInt(usize),
    );
    defer testing.allocator.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next().?;
    try testing.expectEqualStrings(
        "# 000000-000099/20000101T000001Z_2.wiki",
        lines.next().?,
    );
    _ = lines.next().?;
    try testing.expectEqualStrings(
        "# 000000-000099/20000101T000002Z_3.wiki",
        lines.next().?,
    );
    const rebased_delta = lines.next().?;

    const reconstructed = try RealCodec.apply(testing.allocator, "alpha\nbeta\n", rebased_delta);
    defer testing.allocator.free(reconstructed);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\n", reconstructed);
}

fn writeFixture(dir: std.fs.Dir, path: []const u8, body: []const u8) !void {
    const file_data = try std.fmt.allocPrint(
        testing.allocator,
        "---\norigin = \"wikipedia\"\narticle_slug = \"diff\"\nlanguage = \"en\"\ntitle = \"Diff\"\nrevid = 1\nparentid = 0\ntimestamp = \"2000-01-01T00:00:00Z\"\nuser = \"tester\"\ncomment = \"fixture\"\nsize = {d}\nminor = false\n---\n{s}",
        .{ body.len, body },
    );
    defer testing.allocator.free(file_data);

    try dir.writeFile(.{ .sub_path = path, .data = file_data });
}

const FaultyCodec = struct {
    var failed_once = false;

    fn encodePair(
        allocator: Allocator,
        before_text: []const u8,
        after_text: []const u8,
    ) ![]const u8 {
        return try RealCodec.encodePair(allocator, before_text, after_text);
    }

    fn apply(
        allocator: Allocator,
        before_text: []const u8,
        zdelta: []const u8,
    ) ![]const u8 {
        if (!failed_once) {
            failed_once = true;
            return try allocator.dupe(u8, "WRONG");
        }

        return try RealCodec.apply(allocator, before_text, zdelta);
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const dmp = @import("dmp");
