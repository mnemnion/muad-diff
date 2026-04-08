# Change Manager design note

Created: `2026-04-08T20:42:24Z`
Git HEAD: `c45c2070995a1ff22a764cb79689d3c17c222dd1`

This is the replacement design note for the old span-tree sketch.  It is the
concrete implementation spec for the next back-end iteration of selectable
zdelta application.

The old model centered on mutating an "effective" delta and replaying skipped
history into later deltas.  That model is retired here.  The new source of
truth is immutable history plus an immutable translation tree at each decision
point.

## Purpose

The purpose of `ChangeManager` is to let us:

- attach a raw `ZDelta` without rewriting it
- review its edits one at a time or in bulk
- record both applied and skipped decisions
- preserve a full, exact undo history
- expose a faithful model of where the corpus text now maps into realized text
- carry forward skipped-edit anomalies into later revisions without replaying a
  transcript of harmonization hacks

This note elaborates the concepts in [change-management.md](./change-management.md)
and supersedes the obsolete "forward projection" description.  "Forward
projection" is not the right center of gravity; the thing we actually need is a
persistent translation surface rooted in immutable history.

## Rejected model

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
- treating accepted edits as invisible to the translation surface

The distinction between ZDelta and EffectiveZDelta is preserved in case some additional metadata is necessary, not because the scope of work here expects that it will be.

## Vocabulary

The terminology in [change-management.md](./change-management.md) remains in
force.

- `skip`
  A reviewed edit which was not applied.
- `decline`
  A skipped insert.
- `rescue`
  A skipped delete.
- `evacuation`
  A region present in corpus space but absent in realized space.
- `imposition`
  A region present in realized space but absent in corpus space.
- `anomaly`
  A divergence created by a skip.  Every anomaly has a durable record.
- `pristine`
  A region whose mapping is still a single continuous deviation, which may be 0.
- `deviation`
  The numeric difference between corpus-space and realized-space position,
  accumulated from each bifurcation encountered on the path through the
  translation tree.  Not referred to as:
- `translation`
  A future semantic pairing between delete and insert.  Not implemented in the
  first pass.

This note adds two implementation terms:

- `decision`
  A reviewed apply or skip action.  Every decision creates a new immutable
  step.
- `translation tree`
  The persistent interval-tree representation of how the active corpus axis maps
  to realized text at one exact step.

Undo/redo history in this revision is a single path.  Moving backward and
forward along that path is non-destructive.  Taking a new decision from a prior
step destroys the old future and releases its resources.

## Design summary

`ChangeManager` owns the realized text plus a pointer to the current immutable
step.  Each step owns a translation tree and records the single decision that
produced it from its prior step.

Skipped edits create both:

- a `DecisionRecord`
- an `AnomalyRecord`

Accepted edits create only:

- a `DecisionRecord`

But accepted edits still update the translation tree.  They matter because they
change where later things are, and because undo must restore the exact prior
translation surface, not merely the prior bytes.  There is an aspect of the
command pattern here, because undoing an insert is deleting its span, and a
deletion must keep the deleted insert it on undo.  Terminology is consistent
in using 'do' terms (or 'did' terms), not 'undo' terms, in building the record.

The raw `ZDelta` for the currently attached step remains immutable.  The
manager never rewrites it.  Instead, the manager derives ephemeral
`ProjectedOp`s by querying the current step's translation tree against the raw
delta's before-text axis.

At step finish, the manager promotes the current step from the step's before
axis to the next revision's corpus axis.  That promotion absorbs accepted
changes into the new baseline while preserving skipped anomalies.

## Coordinate model

There are always two axes in play:

1. `corpus` axis
   The active source-of-truth revision axis for the current step.
2. `realized` axis
   The actual current text the operator has constructed.

During an open step there is a third important notion:

3. `step-before` axis
   The before-text axis of the attached raw delta.  At `openStep`, this is the
   same as the current step's corpus axis.  As decisions are taken, the
   translation tree continues to answer queries from this axis into realized
   text until `finishStep` promotes the current step to the next revision axis.

All spans are half-open: `[start, end)`.

Insertions are positions, not positive-width spans.  Insert queries must inspect
the status on both sides of a boundary; a point between two regions is not
adequately described by pretending it belongs to one region.

## Core types

The exact field layout may shift a little in implementation, but the following
types are the intended public shape of the design.

```zig
pub const ChangeManager = struct {
    allocator: Allocator,
    buffer: []u8,
    start: u32,
    end: u32,
    pivot: u32,
    budget: u32,

    current_step: *Step,
    attached_step: ?AttachedStepState,

    decisions: std.ArrayListUnmanaged(DecisionRecord),
    anomalies: std.ArrayListUnmanaged(AnomalyRecord),
};

pub const Step = struct {
    prior: ?*Step,
    next: ?*Step,
    projection_root: *ProjectionNode,

    realized_len: u32,
    corpus_len: u32,

    decision: ?DecisionRecord,
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

    anomaly_id: ?u32,
};

pub const AnomalyRecord = struct {
    id: u32,
    kind: AnomalyKind,
    text: []u8,
    corpus_site: Site,
    realized_site: Site,
    created_by_decision: u32,
};

pub const ProjectedOp = struct {
    raw_op_index: u32,
    corpus_site: Site,
    realized: RealizedProjection,
    class: ProjectedClass,
    touched_anomaly_ids: []const u32,
    available_resolutions: []const ApplyResolution,
};
```

### Supporting enums and shapes

```zig
pub const DecisionKind = enum {
    apply,
    skip,
};

pub const EffectKind = enum {
    insert,
    delete,
};

pub const AnomalyKind = enum {
    decline,
    rescue,
};

pub const ApplyResolution = enum {
    mechanical,
    delete_whole,
    delete_corpus_only,
};

pub const ProjectedClass = enum {
    pure,
    overlaid,
    clipped,
    composite,
    blocked,
};

pub const Site = union(enum) {
    point: u32,
    span: struct {
        start: u32,
        end: u32,
    },
};

pub const RealizedProjection = union(enum) {
    point: u32,
    span: struct {
        start: u32,
        end: u32,
    },
    blocked,
};

pub const LeafKind = enum {
    pristine,
    evacuation,
    imposition,
};

pub const IdRange = struct {
    start: u32,
    end: u32,
};

pub const ProjectionNode = union(enum) {
    internal: struct {
        split_at: u32,
        deviation_delta: i32,
        left: *ProjectionNode,
        right: *ProjectionNode,
    },
    leaf: ProjectionLeaf,
};
```

## Translation tree

The translation tree is the full translation logic of the current step.  It is
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
but they do not become user-facing anomalies.

### Intended leaf shape

```zig
pub const ProjectionLeaf = struct {
    kind: LeafKind,

    corpus_start: u32,
    corpus_end: u32,

    realized_width: u32,

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

### Query rules

The tree must support three query modes:

1. map a corpus span to realized text
2. inspect an insertion boundary from both sides
3. enumerate touched anomaly ids across an arbitrary query

Querying the tree means descending from the current root while accumulating
deviation.  By the time the query reaches a leaf, it has both:

- the leaf's local geometry
- the total deviation induced by the path taken to reach it

Realized coordinates are produced from that combination.

A query is mechanically safe only when:

- its mapping is continuous
- its geometry is representable by the effect being projected
- its touched anomaly set allows a well-defined operation

Otherwise the result is `blocked` or `composite`.

## Decision semantics

Every reviewed action creates a new step.

### Skip decision

Skipping a raw delta op does two things:

1. create a new `DecisionRecord`
2. if the skip is a divergence, create a new `AnomalyRecord`

Then it produces a new translation root.

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
2. a new translation root

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
translation surface.

## Projected op semantics

`previewNext()` derives a `ProjectedOp` for the current raw op index by querying
the current translation tree.

### Classification rules

- `pure`
  The op lies wholly within one pristine mapping and has a single mechanical
  realization.
- `overlaid`
  The op crosses one anomaly but still has a well-defined apply semantics.
- `clipped`
  The op is partly in a pristine region and partly in an anomaly region.
- `composite`
  The op spans multiple partitions and cannot be summarized as one simple case.
- `blocked`
  No mechanically safe action exists without extra operator intent.

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
pub fn openStep(manager: *ChangeManager, raw_delta: *const ZDelta, target_revision: usize) !void
pub fn previewNext(manager: *const ChangeManager) !?ProjectedOp
pub fn applyNext(manager: *ChangeManager, resolution: ApplyResolution) !bool
pub fn skipNext(manager: *ChangeManager) !bool
pub fn applyRest(manager: *ChangeManager, default_resolution: ApplyResolution) !usize
pub fn skipRest(manager: *ChangeManager) !usize
pub fn finishStep(manager: *ChangeManager) !void
pub fn undo(manager: *ChangeManager) !bool
pub fn redo(manager: *ChangeManager) !bool
pub fn currentText(manager: *const ChangeManager) []const u8
pub fn anomalies(manager: *const ChangeManager) []const AnomalyRecord
pub fn recentDecisions(manager: *const ChangeManager) []const DecisionRecord
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
   The manager projects the next raw op through the current translation tree.
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
the translation tree because later ops in the same step depend on the
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
more complex total history, the single-path fact of this goal should not
be over-optimized for.

## Session integration

The first session redesign stays narrow.  The transport-level workflow remains:

- attach delta
- prompt at delta scope
- optionally split into per-edit review

But the snapshot data changes materially.

### Session rules

- the session must read anomalies directly from `ChangeManager`
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
4. Accepted edits alter the translation tree, but not the anomaly log.
5. The realized buffer and `current_step.projection_root` always describe the
   same state.
6. Undo restores both text and translation surface.
7. Step finish absorbs accepted edits into the next corpus baseline without
   replaying history.
8. Later deltas are queried against the current tree; they are never rewritten
   by replaying a skip transcript.

## Implementation notes

The first implementation should aim for correctness and clarity before clever
packing.

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

### Translation tree geometry

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
