# Change Management

This library has a number of affordances in a mature state:

- Diffs, which are heavily optimized.  There is work in flight here, but
  the basics of making a good diff of two texts is solved.
- Patch, a mechanism for transporting and applying a diff, with some
  flexibility tolerated as to whether the document has also changed.
  This is relevant here as a reference, but not as a working surface.
- Deltas.  These are compressed Diffs, effectively, and must be applied
  to the exact before text of the diff to be effective.  This is where
  the action is.

Whole application of deltas is a solved problem.  Partial application
of deltas is a barely-attempted and very difficult problem.  What does
exist, does not work, and cannot be expected to.

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

We call a skipped edit a `skip`.  Each `skip` partitions the future.
Deltas are a series of instructions ordered from beginning to end of
the before text: thus a skip affects two regions: the `reject` and
the `remainder`.

Skips come in two flavors: a skipped insert we call a `decline`,
and a skipped delete we call a `rescue.`  A decline's reject is an
`evacuation`.  A rescue's reject is an `imposition`.  These regions
together we call `anomalies`.

We will have an additional condition, once the mechanism is in place.
We will be able to pair the combination of a delete in one place, with
an insert in another, and deem these semantically the same, but in
different locations.  This, we call a `translation`.  Translations will
not be added before the other mechanisms are solid.

The remaining regions we call `pristine`.  This does not mean that they
exist where the deltas expect them to, but merely that a single number,
updated with each edit, will suffice to find the application of an edit
wholly contained in a pristine region.  This number, which may be zero,
we call the `shift`.

Here we must note a fundamental distinction between deletes and inserts,
namely: at the time of application, deletes comprise a region, while
inserts comprise only a position.

The situation of an insert is thus simpler, but not simplistic: at the
moment of insertion, the edit has a definite location, but no _width_,
and we may posit that, in making the decision to accept or reject the
insert, those positions between two regions may call for different
display from those wholly enclosed within one.

Thus, there is a position, or region, where an edit may affect the text,
pending the decision to do so.  This we call, the `target`.

The number and nature of regions crossed by a single edit is unbounded,
such that every variation cannot be named.  But certain ones must be:
we call an edit lying wholly within a pristine region `pure`, one rooted
on both sides in pristine regions, but crossing one anomaly, we call
`overlaid`, one with a foot in each status is `clipped`.  One wholly
within a single anomaly is `stranded`, anything more complex, is
`composite.`

To apply a delete which overlays an evacuation is well-formed: simply,
we delete such text as still exists, and similarly, if skipped, such
text as still remains becomes rescued.  An insertion stranded within an
evacuation has no effect if declined, and ramifies matters if applied,
but is similarly well-formed as its inverse.

A delete overlaying an imposition is more complex, as the user may wish
to apply the delete wholly, that is, to include the rescue, or in part,
deleting that which was but leaving that which wasn't but now is.

An insertion stranded within an evacuation may surely be applied, and
the effect itself is simple: the text appears between the borders of
the evacuation.  But the consequences are not simple: we must continue
to track the evacuation, which no longer has extent, but has phantom
location on one or both sides of the insertion, within which later
edits may expect to appear.

A deletion stranded within an evacuation is automatic, but with
cognate effect to the prior case: the shape of the evacuation
shrinks, but in such a manner as to translate the senseward side
of the text, requiring a bifurcation.

