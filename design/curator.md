# The Curator

We have a viable Delta Guidance System.  This has the proper data structure
to support correction of subsequent zdeltas in the face of decisions which
change the course of history, as well as support for undo and redo.

This is our back end.  It is far from complete but it is correct in design.
The old back end has been removed, and the old middleware has some mocks to
keep it compiling.

The new middleware is Curator.  Like any middleware it sits between the back
end and the front.  It's called the curator because from front to back it's
a thin client, from front to middle and back to middle (and vice versa) it
has complex and ramified duties.

We're operating on revision sets; a single revision is all the deltas which
can transform one file into its next version.  These range from one character,
to an arbitrary number of pages, and the first task of the curator, informed of
the dimensions of the view, and how many lines of context are preferred, is to
compose the current revision into presentation sets.

We'll call these 'hunks', out of tradition, but it must be understood that
fine-grained patching based on character diffs has different needs from the
line-based systems implied by the name.  Our hunks differ a great deal from
those: like classic hunks, they can easily take up more than a screen, but
unlike classic hunks, they can be a messy snarl of a score edits or more, all
packed into a single view.

The current behavior of our front-end `delta_tool` is to treat a hunk (under
an obsolete name) in only two modes: apply or skip everything on screen, or
go over them one at a time.

That won't give users a good experience here.  We need to provide a fairly
large collection of operations, starting with a new semantic for split:
each split does a somewhat-binary partition of the edits, binary in spirit
but looking for an equality to partition on, rather than between an insert
abutting an edit.  It gives up on this around, four edits, and handles that
as the individual case.

Vocabulary: we call a single hunk which is large enough to require unique
presentation, a "big hunk".  "hunk" is our common case, where there are
presumed-many presumed-small-ish edits on one view into the text.  Big
hunks aren't mentioned much in what follows, because they're easy.  Ish.
Refinement is left for after the first draft.

Important fact: each hunk stays fixed in place on the screen, we repaint
it as many times as we want.  So there are many states, rendered as XTerm
color decorations, which the visible edits can be in.  An edit can be:

- insert or delete
- offered (the active target of selection)
- applied or skipped
- latent (disabled until the offered edits are processed)

Undo and redo are also supported.

Note something critical here: the text itself is composed **once**, and only
the decorations change.  Very different from the back end!  Every result of
an edit changes the text buffer and the CorrectionTree in ways which affect
everything after it.  So the composer tracks the hunk in a way which _can_
be reconciled with the state of the DeltaGuidanceSystem, but, it does so in
a way which is better modeled as a parallel source of truth, because the
nature of the consequences of each choice is very different!

I told a little fib here, because it's not strictly true that the text
is composed only once.  That does apply to the operations I've already
described, but we're also going to have other commands which change text
composition but do not affect the back end status at all: important
examples being toggling from "show inserts and deletes" (the base case)
to "show inserts" and to "show deletes", adding superscript numbers
to each edit so they can be processed by enumeraton and ranges, and
"phantom text", such as displaying an evacuation so that the effect of
an edit which wants to be applied to fully or partially evacuated text
can be shown.

So the presentation sequence (how many hunks, and which edits are in each)
is decided up-front, and managed by the composer.  Each hunk itself is a
mutable control surface, constructed fresh when needed.  It is constructed
and owned by the composer, which asks the guidance system a series of atomic
questions.

Between composer and guidance we have two kinds of interaction: queries,
used to build up the hunk, and commands, used to induce guidance to take
action.  Queries shall be implemented as ordinary function calls on
the guidance instance, but we'll use a command pattern for commands: a
tagged union of everything the composer can implore the guidance system
to do, along with payloads, with a single function handling all of them.
This is easier to test, to understand, to log, and so on.

Some queries may be awkward to execute atomically, I'm thinking of "give
me the anomalies inside this region".  Those we can implement in terms
of an iterator.  But what the guidance system _never does_ is build up
a slice of stuff with an allocator and gives it back.

Hunks are retained after exhaustion, for the duration of the program.
This is necessary because undo is allowed to cross hunk boundaries.
Since changing history is destructive (unlike redo), hunks 'stranded'
by such an action are reclaimed.

## Composition

A const pointer to the hunk is routed to the painter to compose and
paint the screen output using `mnemnion/obelizmo`, a library I wrote
specifically toward this purpose.  It needs to hand out slices of
string, in order, along with "what they mean": so when something is
intended to be invisible, it's the hunk iterator which skips that.

We make no effort to do minimal paints, because we anticipate that
effort to be wasted on modern systems.  We simply send sync off, paint
the lines, sync back on and flush.

The hunk knows how to show itself, the painter decides what that looks
like, including little details like reflow.

Because the hunk has this close relationship with the front end, the
composer (owner of hunks, but distinct from them) does not have a
clear design reason to stand between the front end and actions taken
by it.  By which I mean, the delta_tool parser divines intention from
some keystrokes, and needs to translate them into action: for the
most part, the clean line for that action to take is: front tells
hunk "accept edit 2" and hunk sends the command to guidance without
involving the composer itself.

But the hunk should not have a sharing relationship with guidance,
unlike composer.  So what we'll do is have an erased pointer to
composer which exposes the ability to send commands.  That keeps
things from getting too promiscuous.

This isn't an Actor model, we don't need a rigid separation of
concerns where everything is routed through message passing.  The
front end _is_ the program, so it can see everything and talk to
whatever makes sense.  This is pragmatic: the program is going to
get input like "apply" (something) and the hunk is in the best
position to know what "something" means right now.  So it's simpler
for the program to just tell the hunk "apply the next thing" or
"apply all the things which are eligible right now", rather than
ask it to resolve those questions and then relay them to guidance
through the composer.
