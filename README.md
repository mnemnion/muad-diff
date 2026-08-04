# Muad'Diff: The Splice Must Flow

A Zig diffing library based on [diff-match-patch].  This started as a PR
for [diffz], before developing a life of its own.

Some of the features, relative to the classic library:

- **UTF-8 native**: `muad-diff` assumes it's working on UTF-8 encoded
  text.  When that's true, it will not split codepoints in preparing a
  diff.

- **View-based**: borrows slices of the underlying text, favoring the
  'before' text for equality.  This is not possible in the general case,
  so ownership is tracked.

- **Segmented**: `diff-match-patch` has a line-oriented 'fast mode',
  which for encoding reasons is classically limited to 64K (unique)
  lines.  Muad'Diff uses an encoding allowing up to 2^31 lines, and
  isn't limited to lines either.

- **Streamlined Patches**: The "unidiff format" aggressively uses
  percent encoding, presumably because this is available for all six
  supported languages.  Muad D'iff sparingly uses percent encoding:
  edits to non-ASCII-limited language remains legible, and the result
  may still be percent decoded using the stock algorithm for same.

- **'Line'-only diffs**: while fundamentally character (codepoint)
  based, Muad D'iff offers diffing of lines only, for those occasions
  where this may be useful.

- **Faster Better Bitap**: Uses the native machine width for [bitap]
  matching, instead of hard-coding 32 bits.  The bitap implementation
  also uses sparse arrays, rather than a hashmap, to store the alphabet
  mask.  It does consider the alphabet to be bytes, not codepoints:
  I haven't found an efficient way to avoid this.

- **Improved Deltas**: More on this later.


## Status

The core functionality of this library is stable, well-tested, and ready
for use.  It's implicated in a rather elaborate quest involving syntax-
directed diffing, so if it looks like it has a few more degrees of freedom,
and affordances, than it's really making good use of: that's why.

[diff-match-patch]: https://github.com/google/diff-match-patch
[diffz]: https://github.com/ziglibs/diffz/pull/26
[bitap]: https://en.wikipedia.org/wiki/Bitap_algorithm
