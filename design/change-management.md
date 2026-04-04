# Change Management

This library has a number of affordances in a mature state:

- Diffs, which are heavily optimized.  There is work in flight here, but
  the basics of making a good diff of two texts is solved.
- Patch, a mechanism for transporting and applying a diff, with some
  flexibility tolerated as to whether the document has also changed.
  This is relevant here as a reference, but not as a working surface.
- Deltas.  These are compressed Diffs, effectively, and must be applied
  to the exact before text of the diff to be effective.

Whole application of deltas is a solved problem.  Partial application of
deltas is a barely-attempted and very difficult problem.

The purpose of solving this problem is change management.  The goal is
to be able to record every change to a file, starting from a known-good
state, and replay those changes while choosing which to keep and which
to reject.

This is both a user-interface problem, and a substantial bookkeeping
problem.  On the back end, each edit which is rejected changes the
target for all future edits, in an additive way which ramifies with
each deviation.  Some edits become impossible, some become partially
possible, and a few might be more complex even than that, straddling
several partitions of the text.

Another thing we must have is infinite undo, although blessedly, we'll
restrict this to a single history: the user can back up, and redo
forward, but making a change in the past eliminates the future: the
total edit set remains the source of truth, and any decisions so
invalidated must be made again.

## Data Model

We call a skipped edit a reject.  Each reject partitions the future.
There is the moved, and the no longer possible.  The moved, we model
with an interval tree: an edit which remains possible is told where
it has to move in order to apply.
