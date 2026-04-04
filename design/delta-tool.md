# delta_tool design note

Created: `2026-04-04T16:36:10Z`
Git HEAD: `3609f9247176f0f215fc7e0a507811d4cda381f8`

This is a Memento note for the current `delta_tool` system. It describes the
shape that exists now, the boundaries that are intentional, and the policies
that should be preserved unless we consciously decide to change them.

## Purpose

`delta_tool` is a development tool for exercising selectable zdelta
application against the checked-in `corpus/diff` history. Its job is not to be
a generic end-user interface. Its job is to make stateful partial-application
behavior observable, repeatable, and diagnosable.

The important idea is:

- corpus revisions are the input contract
- operator choices are reduced to canonical review intents
- the session core owns review semantics
- the shell owns terminals, transcripts, replay, and paging
- `zdelta` internals remain usable without knowing anything about terminals

## Main files and their roles

- `corpus/diff_contract.zig`
  Owns the checked-in corpus layout contract and runtime filesystem loading.
  This is the single place that knows where `corpus/diff` lives, how `.wiki`
  fixture bodies are extracted, how `.wiki` and `.zdset` entries are sorted,
  and how revision selections are loaded.

- `src/zdelta/session.zig`
  Owns the transport-independent review state machine. This is the semantic
  center of `delta_tool`: prompt kind, allowed intents, revision progression,
  summary accounting, attach diagnostics, quit/completion policy, and the
  review-facing snapshot shape all live here.

- `src/zdelta/context.zig`
  Pure projection layer. It takes a `SessionSnapshot` and turns it into review
  sections and annotated documents. It knows about excerpts, boundaries,
  skipped-history sections, and focused-change sections. It does not know about
  terminals, replay, transcripts, or pagers.

- `src/delta_tool.zig`
  Shell adapter and presentation layer. It parses CLI arguments, reads the
  corpus through `corpus_contract`, collects live/replay input, normalizes it
  into `SessionIntent`, records canonical transcript commands, renders context
  sections, handles Ctrl-C, and performs the final mismatch review.

- `src/zdelta/apply_base.zig`
  Shared buffer-management policy for zdelta application. This holds the common
  slack-buffer mechanics used by both whole-apply and partial-apply paths.

- `src/zdelta/whole_apply.zig`
  Baseline whole-delta applicator. This is the simple path: attach a delta and
  apply mutations in order, with no skipped-history concerns.

- `src/zdelta/apply_manager.zig`
  Partial-application driver. This is where skip history, harmonization, and
  blocked/rewritten delta semantics live.

- `src/zdelta/common.zig`
  Shared zdelta-side structs that need to exist independent of either
  applicator, especially harmonized ops, previews, and skipped-history entries.

## Structure and boundaries

### 1. Corpus contract

The corpus remains on disk under `corpus/diff`. We are intentionally using
runtime filesystem access, not embedding fixtures into the binary.

Important policy:

- corpus layout is currently contractual
- that policy must be centralized in one place
- callers should not duplicate knowledge of `.wiki` ordering, `.zdset`
  matching, or fixture frontmatter extraction

### 2. Session core

`ReviewSession` is a reducer-like state machine over review decisions.

It owns:

- which revision pair is active
- whether the prompt is delta-level or edit-level
- which intents are valid in each state
- when an attached delta fails length checks and should be diagnosed then
  skipped
- how summary counters evolve
- what it means to be `in_progress`, `quit_early`, or `complete`

It intentionally does not own:

- terminal bytes
- replay script parsing
- ANSI rendering
- transcript files
- pagers

The point is that the core should still make sense if the shell later becomes
mouse-driven, menu-driven, test-driven, or something else entirely.

### 3. Projection layer

`context.InteractionState.build(...)` takes a `SessionSnapshot` and produces a
set of `Section`s. A `Section` is the review-facing unit of presentation:
overview, focused change, or skipped history. Each section contains a
`DocumentModel` with text, line starts, annotations, and semantic boundary
markers.

The projection layer knows:

- what part of the text to show
- how to annotate inserts/deletes/focus/blocked/rewritten regions
- how to describe skipped history as its own review section

It does not know:

- what prompt text to print
- whether output is plain or ANSI
- where user input came from

### 4. Shell adapter

`delta_tool` is now a thin but still important shell.

It owns:

- CLI argument parsing
- live stdin byte handling
- replay script handling
- canonical transcript logging
- raw terminal mode
- Ctrl-C interruption semantics
- rendering `Section`s to plain or ANSI output
- final mismatch review paging/fallback

It does not directly own review semantics anymore. It asks the session for a
snapshot, renders that snapshot, parses input into a `SessionIntent`, and
dispatches that intent back into the session.

### 5. Partial-apply internals

`ReviewSession` does not reach directly into `DeltaManager` fields. It talks to
the private `ReviewDriver` facade in `session.zig`. Right now that facade is a
thin wrapper over `DeltaManager`, but it is the seam that prevents the session
core from depending on harmonization internals.

That means the session speaks in verbs like:

- attach delta
- peek next change
- apply next
- skip next
- apply rest
- skip rest
- read current text
- inspect skipped history

and not in terms of `DeltaManager` bookkeeping fields.

## Policy choices that matter

### Canonical actions, not raw input

The system records and dispatches canonical review actions, not raw terminal
input. This is why transcripts and replay use the compact command stream:

- delta level: `y`, `n`, `s`, `q`, `?`
- edit level: `y`, `n`, `a`, `d`, `q`, `?`

The terse one-character interface is intentional. BEL on invalid live input is
intentional. The important boundary is that parsing those bytes is a shell job,
while acting on the resulting review intent is a session job.

### Replay is exact and exclusive

When `--replay` is active, the tool does not fall back to live stdin. Script
exhaustion and invalid replay commands are errors, because replay is meant to
be a deterministic debugging path, not a convenience mode.

### Ctrl-C is interruption, not quit

Ctrl-C is handled at the shell boundary and becomes `error.Interrupted`. It is
not normalized into `q`, and it must not synthesize or log a trailing quit in
the transcript. This preserves the meaning of incomplete transcript blocks as
failure/interruption markers.

### Pager review is ancillary

The final mismatch review through `less` is helpful but non-essential. If pager
spawn/write/wait fails, the diff falls back to stdout. A successful review run
must not be retroactively treated as a failed run just because paging broke.

### Skip history is real state

In the partial path, skipped edits are not just UI notes. They materially alter
the relation between the current text and the corpus baseline. That is why
later deltas must be harmonized against skipped history, and why the system
tracks blocked and rewritten states.

The system which represents skip history is recognized as both buggy,
and inadequate to carry this part of the `muad_diff` project to
completion.  The work summarized in this document has reduced interface
bugs enough that model bugs can surface.

## Current execution flow

The current runtime flow is:

1. `delta_tool` parses CLI args and revision ordinals.
2. It loads the selected corpus range through `corpus/diff_contract.zig`.
3. It builds a `SessionSeed` consisting of one baseline revision plus ordered
   target steps containing target bodies and zdelta text.
4. It creates `ReviewSession` and calls `open()`.
5. `open()` attaches the first usable delta, or emits length-mismatch
   diagnostics and advances until it finds one.
6. The shell requests `session.snapshot()`.
7. `context.build(...)` turns the snapshot into sections/documents.
8. The shell renders those sections.
9. The shell prompts, reads one live/replay command, and parses it into a
   canonical `SessionIntent`.
10. The shell records the canonical command in the transcript before execution.
11. The shell dispatches the intent into `session.dispatch(...)`.
12. The session mutates reducer state and, through `ReviewDriver`, mutates the
    partial-apply engine as needed.
13. The shell handles help output or attach diagnostics, then repeats until the
    session is complete or quit early.
14. On clean completion, the shell compares current text to expected final
    text. If they differ, it renders a pretty diff through the pager fallback
    path.
15. The shell prints the summary and, on successful non-error exit, ensures the
    transcript ends in `q` unless the operator already used `q`.

## Testing center of gravity

The tests are intentionally not centered in the shell anymore.

The main contract tests now belong in `src/zdelta/session.zig`, because that is
the semantic state machine. Those tests should keep describing:

- prompt transitions
- allowed intents
- help behavior
- whole-delta apply/skip
- split/edit progression
- apply-rest/skip-rest
- multi-revision advancement
- quit-early behavior
- attach-diagnostic behavior

`context.zig` tests should stay about projection semantics, not terminal text.

`delta_tool.zig` tests should stay smoke-level and shell-focused:

- CLI help
- replay compatibility
- transcript behavior
- invalid input BEL
- Ctrl-C interruption semantics
- pager fallback

`apply_manager.zig` and `whole_apply.zig` still share a baseline interface, and
there is now an explicit shared-interface test to keep that overlap visible.

## What future-you should preserve

- Keep corpus layout policy centralized.
- Keep `SessionIntent` as the canonical action boundary.
- Keep `context` terminal-agnostic.
- Keep `delta_tool` as the shell, not the semantic core.
- Keep incomplete transcripts meaningful on interruption/error.
- Keep pager failure non-fatal.
- Keep skip history treated as real application state, not a cosmetic detail.

## What is still knowingly provisional

- `ReviewDriver` is currently a private facade over `DeltaManager`, not a fully
  separated subsystem.
- The partial-apply/harmonization internals are improved but still dense.
- Focus/change presentation may still evolve as operator-facing language
  settles.
- Performance is not the current center of gravity; boundary correctness and
  functional description took priority.

If future-you is confused, start by re-reading:

- `corpus/diff_contract.zig`
- `src/zdelta/session.zig`
- `src/zdelta/context.zig`
- `src/delta_tool.zig`

That is the current spine of the system.
