# Plan: Replace Replay Harmonization with a Span-Based Forward Projection Tree

## Summary

Keep `TextManager.skipped` as the canonical permanent history, but add
a compiled forward projection tree that maps future-delta spans onto
the current realized text. The tree is keyed by half-open spans, stores
either a continuous coordinate shift or an unmapped gap, and carries all
causal skip ids for each segment. `addDelta` should stop replaying all
skips against the incoming delta and instead harmonize each incoming op
by querying this projection tree. An op is mechanically rewritable only
if its full span maps through one continuous translated segment; if it
crosses a gap or multiple segments, it becomes unresolved and keeps the
touched skip ids as provenance.

## Key Changes

- Add a compiled projection structure owned by `TextManager`.
  - It is span-based, forward-only, and append-updated when `skipNext()` happens.
  - It maps from the counterfactual/future coordinate space that later deltas use into the current realized text coordinate space.
  - Each segment stores:
    - source half-open span,
    - either a continuous shift or an unmapped gap,
    - all causal skip ids affecting that segment/gap.
- Keep `skipped` as the source of truth.
  - `SkippedDeltaOp` remains the full audit/history record with exact text and skip-time context.
  - The projection tree stores only skip ids, never duplicated text payload.
- Rework `skipNext()` to update both history and compiled projection.
  - Skipping an insert creates a gap over the inserted counterfactual span and shifts later spans by `-len`.
  - Skipping a delete creates the dual discontinuity for later forward projection and shifts later spans by `+len`.
  - Projection updates are incremental; no full recompilation from history on each skip.
- Rework `addDelta()` harmonization around projection queries.
  - For each incoming op span, query the projection tree.
  - If the full span maps through one continuous translated segment:
    - rewrite the op coordinates mechanically,
    - mark it unchanged or rewritten as appropriate.
  - If the span touches a gap or multiple segments:
    - mark it unresolved,
    - attach the union of touched skip ids as provenance.
  - Keep the existing ownership, budget, room, and lifecycle rules after harmonization.
- Refine analyzed-op provenance.
  - Replace the single `skip_index` field on harmonized ops with a span-provenance shape that can hold all contributing skip ids.
  - Unresolved ops should carry the full touched skip-id set so later interactive tooling can reconstruct phantom/current text from `skipped`.
- Keep the existing acceptance check, but make it projection-native.
  - `equivalentLen()` remains a sanity check conceptually, but the long-term source of truth should be derivable from the projection model rather than separate replay arithmetic.
  - `addDelta()` still rejects deltas whose original-before span model cannot be accepted by the current realized history.

## Public API / Type Changes
- Add an internal `TextManager` projection-tree field and its owned lifecycle.
- Extend harmonized op provenance from `?u32` to a collection/range form that can represent all causal skip ids.
- Keep `skippedItems()` as the public read path for full history.
- Keep `applyNext()` behavior: resolved ops apply, unresolved ops return `error.UnresolvedZDeltaOp`.

## Test Plan
- Add projection-tree unit tests for:
  - skipped insert creates a gap and downstream negative shift,
  - skipped delete creates the dual discontinuity and downstream positive shift,
  - incremental multiple-skip updates preserve correct spans and provenance sets.
- Add `addDelta()` harmonization tests for:
  - op wholly inside one mapped span rewrites mechanically,
  - op crossing a segment boundary becomes unresolved,
  - op touching an unmapped gap becomes unresolved,
  - unresolved ops carry all touched skip ids, not only the latest one.
- Add scenario tests with multiple historical skips where:
  - later deltas far from danger zones harmonize without replaying full history,
  - later deltas spanning danger zones keep enough provenance to reconstruct phantom/current text from `skipped`.
- Keep existing lifecycle, skip-history, `move`, budget, and `applyNext` tests green.

## Assumptions and Defaults
- History is single-timeline and forward-propagating only; alternative outcomes require rewinding and replaying, not branching.
- The projection tree is a compiled acceleration structure, not the canonical historical record.
- Tree keys are half-open spans, not points.
- Danger Zone is defined mechanically: an incoming op is in danger when its span cannot be projected as one continuous translated span.
- Projection segments and gaps store all causal skip ids, but semantic text/details continue to live only in `skipped`.
