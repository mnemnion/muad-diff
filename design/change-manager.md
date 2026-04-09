# Change Manager design note

Created: `2026-04-08T20:42:24Z`
Git HEAD: `c45c2070995a1ff22a764cb79689d3c17c222dd1`

This is the concrete implementation spec for the next back-end iteration
of selectable zdelta application.

The old model centered on mutating an "effective" delta and replaying skipped
history into later deltas.  That model is retired here.  The new source of
truth is immutable history plus an immutable correction tree at each decision
point.

## Purpose

The purpose of `DeltaGuidanceSystem` is to let us:

- attach a raw `ZDelta` without rewriting it
- review its edits one at a time or in bulk
- record both applied and skipped decisions
- preserve a full, exact undo history
- expose a faithful model of where the corpus text now maps into realized text
- carry forward skipped-edit anomalies into later revisions without replaying a
  transcript of harmonization hacks

This note elaborates the concepts in [Change
Management](./change-management.md) and supersedes the entire
implementation of partial application found in zdelta.  Spoiler alert:
the missile knows where it is?  Is profoundly correct.  Funny how that
works.

## Rejected Model

The current `effective.zig` / `apply_manager.zig` approach is wrong in three
ways:

1. It stores divergence twice.
   The skip log is one record, and the rewritten effective delta is another.
   That makes drift possible by construction.
2. It mutates the attached delta.
   The attached raw delta should remain immutable.  A reviewed history should
   be represented by the manager state, not scribbled into the instruction
   stream.
3. It makes undo harder than necessary.
   If the current truth is a pile of rewrites, then undo means recomputing the
   world.  If the current truth is an immutable step, undo is moving a
   pointer.

The replacement design therefore forbids:

- replay harmonization against later deltas
- suffix-based "active skipped" bookkeeping
- mutable replacement of remaining delta ops
- treating accepted edits as invisible to the correction surface

The distinction between `ZDelta` and `EffectiveZDelta` is no longer useful.
We will use `ZDelta` directly unless or until we discover that we must
make changes in the service of this implementation.

## Comments

Text in markdown comments is only actionable in later
implementation. **Not** this one.  It should neither be acted against,
nor acted upon.

## Glossary

This is the most important section of this document.  The implementation
here documented has acquired variation: it isn't where it is, and knows
where it wasn't.  This variation is error, and subject to correction,
under the guidance of the vocabulary.

- `span`
  Any contiguous amount of text.  Span width is
    - `expected`
      The span according to the corpus text.
    - `effective`
      The span as it actually is.  Absent skips, these are the same.
- `skip`
  A reviewed edit which was not applied.
  - `decline`
    A skipped insert.
  - `rescue`
    A skipped delete.
- `region`
  A span having a single characteristic.  These do not necessarily have
  width.
- `anomaly`
  A divergence created by a skip.
  - `evacuation`
    A region present in corpus space but absent in realized space.
    Consequence of a `decline`.
  - `imposition`
    A region present in realized space but absent in corpus space.
    Consequence of a `rescue`.
- `pristine`
  A region whose mapping is still a single continuous deviation, which may be 0.
- `bifurcation`
  A shared location beween a pristine region and an anomalous one, and
  vice versa.
- `deviation`
  The numeric difference between corpus-space and realized-space position,
  accumulated from each bifurcation encountered on the path through the
  correction tree.  Not referred to as:
- `translation`
  A future semantic pairing between delete and insert.  Not implemented in the
  first pass.  This is a **reserved word**.
- `target`
  The location or region where a delta expects to have effect.  Varieties are
  expounded upon later in this text.
- `correction`
  The act of accounting for deviation, guiding the delta from where it wasn't
  to where it will be.
- `decision`
  A reviewed apply or skip action.  Every decision creates a new immutable
  step.  There are four decisions: `insert` and `delete` are accepts, and
  `decline` and `rescue` are skips. <!-- Complex decisions are
  decomposed, left to right, into a series of simple decisions.  These
  are tracked as a single action, for undo and redo purposes. -->
- `correction tree`
  The persistent interval-tree representation of how the active corpus axis maps
  to realized text at one exact step.

Undo/redo history in this revision is a single path.  Moving backward
and forward along that path is non-destructive.  Taking a new decision
from a prior step destroys the old future and releases its resources.
The future of the correction tree, notably _not_ the `ZDelta`s it was
based on, which must be preserved for application in the next future
created.

## Design summary

`DeltaGuidanceSystem` owns the text buffer plus a pointer to the current
immutable step.  Each step owns a correction tree and records the single
decision that produced it from its prior step.

Skipped edits create both:

- a `DecisionRecord`
- an `AnomalyRecord`

Accepted edits create only:

- a `DecisionRecord`

But accepted edits still update the correction tree.  They matter
because they change where later things are, and because undo must
restore the exact prior correction surface, not merely the prior bytes.
There is an aspect of the command pattern here, because undoing an
insert is deleting its span, and a deletion must keep the deleted
region, to insert it on undo.  Terminology is consistent in using 'do'
terms (or 'did' terms), not 'undo' terms, in building the record.

The raw `ZDelta` for the currently attached step remains immutable.  The
manager never rewrites it.  Instead, the manager derives ephemeral
`ProjectedOp`s by querying the current step's correction tree against the raw
delta's before-text axis.

At step finish, the manager promotes the current step from the step's before
axis to the next revision's corpus axis.  That promotion absorbs accepted
changes into the new baseline while preserving skipped anomalies.

## Spans and Insertions

All spans are half-open: `[start, end)`.

Insertions occur at positions, not across positive-width spans.  Insert
queries must inspect the status on both sides of a boundary; a point
between two regions is not adequately described by pretending it belongs
to one region.

## Core types

What follows is a sketch of the types to be used in this rewrite.  What
matters is the _vocabulary_ and the _shape_.  As you read this, your
primary purpose is to refine these types into a shape I am satisfied
will produce the correct implementation.

In particular, take note of types which allow contradictory information
to be represented, and modify them so this is impossible by construction.

Do not be too quick to decide some field is redundant: it may have a
purpose, just not an obvious one.

Another note: `realized` is not in the glossary, but is all over the
documentation and type system.  It should not be.  Projection is another
mistake: that is mechanism, not policy.

```zig
pub const DeltaGuidanceSystem = struct {
    allocator: Allocator,
    buffer: []u8,
    start: u32,
    end: u32,
    pivot: u32,
    budget: u32,

    current_step: *Step,
    attached_step: ?AttachedStepState,

    // These are referenced by index, pointers would be unstable
    decisions: std.ArrayListUnmanaged(DecisionRecord),
    anomalies: std.ArrayListUnmanaged(AnomalyRecord),
};

pub const Step = struct {
    prior: ?*Step,
    next: ?*Step,
    correction_root: *CorrectionNode,

    realized_len: u32,
    corpus_len: u32,

    decision: DecisionIndex,
    anomaly: ?AnomalyIndex,
    anomaly_count: u32,
    decision_count: u32,
};

pub const AttachedStepState = struct {
    raw_delta: *const ZDelta,
    target_revision: usize,
    raw_index: u32,
    before_len: u32,
};

pub const DecisionRecord = struct {
    id: u32,
    revision_ordinal: usize,
    raw_op_index: u32,

    kind: DecisionKind,
    effect_kind: EffectKind,
    resolution: ApplyResolution,

    corpus_site: Site,
    realized_site_before: Site,
    realized_site_after: Site,

    anomaly_id: ?AnomalyIndex,
};

pub const AnomalyRecord = struct {
    id: u32,
    kind: AnomalyKind,
    text: []u8,
    corpus_site: Site,
    realized_site: Site,
    created_by_decision: DecisionIndex,
};

pub const CorrectedOp = struct {
    raw_op_index: u32,
    corpus_site: Site,
    realized: RealizedProjection,
    class: ProjectedClass,
    touched_anomaly_ids: []const u32,
    available_resolutions: []const ApplyResolution,
};

pub const DecisionIndex = enum(u32) {_}; // newtype pattern
pub const AnomalyIndex = enum(u32) {_};
```

### Supporting enums and shapes

```zig
pub const DecisionKind = enum {
    apply,
    skip,
};

pub const AcceptKind = enum {
    insert,
    delete,
};

pub const RejectKind = enum {
    decline,
    rescue,
};

pub const AnomalyKind = enum {
    evacuation,
    imposition,
};

pub const TargetClass = enum {
    pure,
    overlaid,
    clipped,
    composite,
    stranded,
    complex,
};

pub const Site = union(enum) {
    point: u32,
    span: struct {
        start: u32,
        end: u32,
    },
};

pub const CorrectedTarget = union(enum) {
    point: u32,
    span: struct {
        start: u32,
        end: u32,
    },
};

pub const LeafKind = enum {
    evacuation,
    imposition,
    pristine,
};

pub const IdRange = struct {
    start: u32,
    end: u32,
};

pub const CorrectionNode = union(enum) {
    span: struct {
        width: u32,
        deviation: i32,
        pivot: u32, // left-or-right in deviation-corrected terms
        left: *CorrectionNode,
        right: *CorrectionNode,
    },
    region: CorrectionLeaf,
};
```

## Correction tree

The correction tree is the full correction logic of the current step.  It is
persistent and immutable.  A new decision creates a new root which shares
unchanged subtrees with its prior step.

The tree is keyed by the active corpus axis.  Its leaves describe local
geometry and status, while realized-space placement is derived by accumulating
deviation along the path from the current root to the leaf.

The fundamental geometric leaf kinds are:

- `pristine`
  A positive-width corpus span which maps to realized text by one continuous
  deviation.
- `evacuation`
  A positive-width corpus span whose text is absent in realized text.
- `imposition`
  Realized text anchored at a corpus boundary, with zero corpus width and
  positive realized width.

The important refinements are:

1. geometry and anomaly status are not the same thing
2. absolute realized placement is not a leaf-local fact

- A skipped insert creates an anomalous `evacuation`.
- A skipped delete creates an anomalous `imposition`.
- An accepted delete may temporarily create evacuation geometry during an open
  step, but it is not an anomaly.
- An accepted insert may temporarily create imposition geometry during an open
  step, but it is not an anomaly.

Therefore each leaf carries provenance, but not an absolute realized offset:

1. structural provenance
   Which decision ids produced this geometry.
2. anomaly provenance
   Which anomaly ids, if any, make this geometry review-dangerous.

Accepted edits are thus "lightly tracked": they influence geometry and undo,
but they do not become user-facing anomalies.  The text of a deletion must
be cached for undo, that of an insertion need not be.

### Intended leaf shape

```zig
pub const CorrectionLeaf = struct {
    kind: LeafKind,

    corpus_start: u32,
    corpus_end: u32,

    width: u32,

    decision_ids: IdRange,
    anomaly_ids: IdRange,
};
```

Leaves do not store an absolute deviation record.  That is intentional.  A leaf
describes local geometry, while realized coordinates are derived by summing
deviation from each bifurcation on the path from the current root.  This is not
primarily an efficiency trick; it is a correctness property which lets each new
step share prior structure without rewriting every downstream leaf.

The exact storage may use packed arrays or side tables, but the semantics above
are the contract.

## Decision semantics

Every reviewed action creates a new step.

### Skip decision

Deciding a raw delta op does two things:

1. create a new `DecisionRecord`
2. If this is a skip, create a new `AnomalyRecord`

Then it produces a new correction root.  Span is updated in reference
to the realized text, deviation in (inverse) reference to the corpus.
The root deviation is always zero.

Rules:

- skipped insert
  Creates an anomalous evacuation over the insert's corpus-side contribution
  and contributes negative deviation to later realized positions
- skipped delete
  Creates an anomalous imposition containing the rescued text and contributes
  positive deviation to later realized positions

### Apply decision

Applying a raw delta op creates:

1. a new `DecisionRecord`
2. a new correction root

It does not create an anomaly record.

Rules:

- accepted insert
  Creates non-anomalous imposition geometry until step finish and contributes
  positive deviation to later realized positions
- accepted delete
  Creates non-anomalous evacuation geometry until step finish and contributes
  negative deviation to later realized positions

This is the key answer to the undo concern: accepted edits are not anomalies,
but they are absolutely part of history because they visibly move the
correction surface.  In terms of the tree, they increase or decrease spans,
but introduce no additional deviation.

## Projected op semantics

`previewNext()` derives a `ProjectedOp` for the current raw op index by querying
the current correction tree.

### Classification rules

- `pure`
  The op lies wholly within one pristine mapping and has a single mechanical
  realization.
- `overlaid`
  The op crosses one anomaly but still has a well-defined apply semantics.
- `clipped`
  The op is partly in a pristine region and partly in an anomaly region.
- `stranded`
  The op lies wholly within an anomaly.
- `complex`
  Any target across a number and type of spans such that we have not made a
  case to handle it.

### Delete-over-imposition

This case must not be collapsed to "blocked until later".  The first design
must explicitly support both resolution modes:

- `delete_whole`
  Delete the corpus-side target and the imposed text.
- `delete_corpus_only`
  Delete only that portion which corresponds to the corpus-side target, leaving
  rescued text intact.

If a focused delete overlays an imposition, `available_resolutions` must expose
both modes.  The session layer may present them simply at first, but the back
end must own the distinction.

## Manager API

The intended backend surface is:

```zig
pub fn openStep(manager: *DeltaGuidanceSystem, raw_delta: *const ZDelta, target_revision: usize) !void;
pub fn previewNext(manager: *const DeltaGuidanceSystem) !?ProjectedOp;
pub fn applyNext(manager: *DeltaGuidanceSystem, resolution: ApplyResolution) !bool;
pub fn skipNext(manager: *DeltaGuidanceSystem) !bool;
pub fn applyRest(manager: *DeltaGuidanceSystem, default_resolution: ApplyResolution) !usize;
pub fn skipRest(manager: *DeltaGuidanceSystem) !usize;
pub fn finishStep(manager: *DeltaGuidanceSystem) !void;
pub fn undo(manager: *DeltaGuidanceSystem) !bool;
pub fn redo(manager: *DeltaGuidanceSystem) !bool;
pub fn currentText(manager: *const DeltaGuidanceSystem) []const u8;
pub fn anomalies(manager: *const DeltaGuidanceSystem) []const AnomalyRecord;
pub fn recentDecisions(manager: *const DeltaGuidanceSystem) []const DecisionRecord;
```

### API intent

- `openStep`
  Attach a raw delta and initialize `AttachedStepState`.  Reject if another
  step is still open.
- `previewNext`
  Return the next unresolved or review-relevant projected op, never a rewritten
  delta stream.
- `applyNext`
  Apply the focused op with the requested resolution and advance `raw_index`.
- `skipNext`
  Skip the focused op, create anomaly history when appropriate, and advance
  `raw_index`.
- `applyRest`
  Apply the remainder, using `default_resolution` when a delete-over-imposition
  presents more than one valid choice.
- `skipRest`
  Skip the remainder.
- `finishStep`
  Promote the current step from the step-before axis to the next revision axis.
- `undo`
  Move `current_step` to `prior` and restore the realized buffer state for that
  step.
- `redo`
  Move `current_step` to `next` if it still exists.

## Step lifecycle

The step lifecycle is:

1. `openStep`
   The manager attaches an immutable raw delta.  The current step and the
   step-before axis are identical here.
2. `previewNext`
   The manager projects the next raw op through the current correction tree.
3. decision
   `applyNext` or `skipNext` create a new immutable step and update the
   realized text buffer.
4. repeat
   Continue preview and decision until the raw delta is exhausted.
5. `finishStep`
   Promote the current step to the next revision axis, absorbing accepted edits
   into the baseline and carrying only skipped anomalies forward as
   review-dangerous structure.

Promotion is the only place where accepted edits stop appearing as temporary
evacuation/imposition geometry.  Before promotion they must remain visible in
the correction tree because later ops in the same step depend on the
deviation
they create.

## Undo and redo

Undo is not a replay algorithm.  Undo is moving `current_step` to `prior` and
restoring the realized text and projection root corresponding to that step.

Redo is moving `current_step` to `next` along the preserved future path.
Moving around is non-destructive.

The operations do change the _text_, but they do not change the _record_,
because they do not affect the decisions which realize the text as it is
at each step.

If a new decision is made from a rewound step:

- that step's old `next` chain is invalidated
- the manager releases the abandoned future
- the manager starts a new live future from the rewound step

The design is intentionally single-path:

- backing up is allowed
- redoing forward is allowed
- changing the past destroys the old future
- branching futures are not retained as active alternatives

The append-only decision and anomaly arrays still preserve record ids, but only
the chain reachable from `current_step` by walking `prior` and `next` is the
live history.

The choice of a double-linked list serves to preserve the option of a
more complex total history.  The single-path fact of this goal should not
be over-optimized for.

## Session integration

The first session redesign stays narrow.  The transport-level workflow remains:

- attach delta
- prompt at delta scope
- optionally split into per-edit review

But the snapshot data changes materially.

### Session rules

- the session must read anomalies directly from `DeltaGuidanceSystem`
- there is no suffix-derived "active skipped" concept
- the visible anomaly list is the full anomaly set reachable from the current
  step
- focus metadata comes from `ProjectedOp`
- if multiple apply resolutions exist, the session must surface them

The session does not need a top-to-bottom workflow redesign in the first pass.
It does need to stop depending on `skip_index`, `blocked marker` hacks, or
tail-rewrite bookkeeping.

## Invariants

The implementation must preserve these invariants.

1. The raw `ZDelta` attached to an open step is immutable.
2. Every reviewed decision creates exactly one new step.
3. Every skipped divergence creates exactly one anomaly record.
4. Accepted edits alter the correction tree, but not the anomaly log.
5. The realized buffer and `current_step.projection_root` always describe the
   same state.
6. Undo restores both text and correction surface.
7. Step finish absorbs accepted edits into the next corpus baseline without
   replaying history.
8. Later deltas are queried against the current tree; they are never rewritten
   by replaying a skip transcript.

## Implementation notes

The first implementation should aim for correctness, clarity, and fidelity.

Practical preferences:

- keep the existing slack-buffer text storage from `apply_base.zig`
- build the first tree with obvious immutable node sharing, not heroic
  compression
- keep anomaly text payloads only in `AnomalyRecord`
- let tree leaves and decision records carry ids, not duplicated text
- derive `ProjectedOp` ephemerally; do not store a mutable analyzed-op stream

The current `DeltaManager` can serve as a temporary staging area for the text
buffer mechanics only.  Its harmonization model should not survive.

## Test plan

Tests use a combination of geometric strings (`"XXXXXAAAXXXXX"`) and
phrases / sentences as test data.  ZDeltas should be constructed by
diffing strings rather than directly from parts.

### Correction tree geometry

- declined insert creates an anomalous evacuation and downstream negative
  deviation
- rescued delete creates an anomalous imposition and downstream positive
  deviation
- accepted insert creates non-anomalous imposition geometry and later positive
  deviation during the open step
- accepted delete creates non-anomalous evacuation geometry and later negative
  deviation during the open step
- multiple decisions partition the axis correctly and preserve provenance

### Projection behavior

- pure edits project mechanically
- deletes over evacuations remain well-formed
- deletes over impositions expose both `delete_whole` and
  `delete_corpus_only`
- composite edits gather all touched anomaly ids
- blocked edits do not pretend to be simple rewritten spans
  - there is no such thing as a 'blocked' edit in a sense where it would
    be impossible to act on it.  this concept stands in for 'the possible
    decisions for this edit are beyond what we happen to currently provide'.

### Step behavior

- every decision creates a new immutable step
- undo restores both bytes and projection root
- redo follows the preserved forward path
- a new decision after undo clears redo

### Step boundaries

- later deltas are attached by querying the current tree, not replaying
  harmonization
- finishStep promotes to the next revision axis while preserving surviving
  anomalies
- accepted-edit geometry disappears into the new baseline at promotion time

### Session behavior

- snapshot exposes the full anomaly history visible at the current step
- focused changes include available apply resolutions
- split review can choose between delete-over-imposition resolutions

## Out of scope

The following are intentionally not in the first implementation:

- semantic `translation` pairing between distant delete and insert regions
- retaining multiple live future branches after undo
- redesigning the entire `delta_tool` shell interaction model

Those can attach later once the immutable back end is solid.
