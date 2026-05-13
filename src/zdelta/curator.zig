//! Curator middleware for interactive zdelta review.
//!
//! This file is intentionally a narrow first implementation rather than the
//! finished replacement for `delta_tool`.  The goal is to put the Curator's
//! vocabulary into Zig types while the shape is still cheap to review and
//! change, then let the executable behavior grow from that vocabulary.
//!
//! Curator sits between the front end and `DeltaGuidanceSystem`.
//!
//! Guidance owns the effective text and correction surface.  Curator owns the
//! presentation plan: which revision is being reviewed, which stable hunk is on
//! screen, which surfaces are active or latent, and which decorations should be
//! repainted after a command.
//!
//! A hunk is deliberately not a mini guidance system.  It may cache composed
//! text and edit presentation state, but it must not become a second authority
//! over the correction tree.  That tradeoff costs some reconciliation work, but
//! it keeps undo and redo centered on the persistent guidance history rather
//! than on whatever happens to be visible in the terminal.
//!
//! We also assume the next guidance revision retains attached zdeltas.  Curator
//! may decode or otherwise prepare zdelta text at attach time, but once an open
//! succeeds, the retained raw delta is guidance/history material rather than a
//! Curator-owned temporary.

/// Describes the first body in a revision set.
pub const BaselineRevision = struct {
    ordinal: usize,
    relative_path: []const u8,
    body: []const u8,
};

/// Describes one target revision and its raw zdelta text.
pub const RevisionStep = struct {
    ordinal: usize,
    relative_path: []const u8,
    target_body: []const u8,
    zdelta_text: []const u8,
};

/// Describes the immutable revision set handed to a Curator.
pub const RevisionSeed = struct {
    baseline: BaselineRevision,
    steps: []const RevisionStep,
};

/// Stable id for a retained presentation hunk.
pub const HunkId = enum(u32) { _ };

/// Stable id for a surface inside a hunk.
pub const SurfaceId = enum(u32) { _ };

/// Stable id for a surface that can receive a review decision.
pub const DecidableSurfaceId = enum(u32) { _ };

/// High-level kind of presentation hunk.
pub const HunkKind = enum {
    revision,
    split,
    big,
};

/// Selects which text families the hunk should expose to the painter.
pub const HunkDisplayMode = enum {
    combined,
    inserts,
    deletes,
};

/// Names the lifecycle state of a decidable surface.
pub const SurfaceState = enum {
    ready,
    applied,
    skipped,
    latent,
    blocked,
};

/// Names the paint-facing decoration derived from a surface.
pub const SurfaceDecoration = enum {
    normal,
    ready,
    active,
    applied,
    skipped,
    latent,
    blocked,
};

/// Tuneables used while composing hunk presentation.
pub const PresentationSettings = struct {
    viewport_rows: u16,
    viewport_cols: u16,
    context_lines: u16,
    small_split_edit_limit: u16,

    /// Conservative defaults for text-terminal hunk composition.
    pub const default: PresentationSettings = .{
        .viewport_rows = 24,
        .viewport_cols = 80,
        .context_lines = 2,
        .small_split_edit_limit = 4,
    };
};

/// Hunk-local handle back to the guidance preview that produced a surface.
pub const GuidanceSurfaceRef = enum(u32) { _ };

/// An inert portion of a hunk.
pub const ContextSurface = struct {
    id: SurfaceId,
    text: Span,
};

/// An active insert control inside a hunk.
pub const InsertSurface = struct {
    id: SurfaceId,
    decidable: DecidableSurfaceId,
    text: Span,
    guidance_ref: GuidanceSurfaceRef,
    state: SurfaceState,
};

/// An active delete control inside a hunk.
pub const DeleteSurface = struct {
    id: SurfaceId,
    decidable: DecidableSurfaceId,
    text: Span,
    guidance_ref: GuidanceSurfaceRef,
    state: SurfaceState,
    available_resolutions: []const ApplyResolution,
};

/// The active hunk-local control target.
pub const HunkControl = union(enum) {
    none,
    active: DecidableSurfaceId,
    // Future selection mode belongs here as another variant, not as an
    // independent list beside active.  A hunk should have one control shape at
    // a time.
};

/// A contiguous, optionally active portion of a hunk.
pub const Surface = union(enum) {
    context: ContextSurface,
    insert: InsertSurface,
    delete: DeleteSurface,

    /// Returns this surface's stable id.
    pub fn id(surface: Surface) SurfaceId {
        // Implementation note:
        // Keeping the id inside each variant lets an inert context surface never
        // masquerade as an edit control, while still letting iterators address
        // every surface.
        return switch (surface) {
            .context => |context| context.id,
            .insert => |insert| insert.id,
            .delete => |delete| delete.id,
        };
    }

    /// Returns this surface's decidable id when it can receive a command.
    pub fn decidableId(surface: Surface) ?DecidableSurfaceId {
        // Implementation note:
        // Context is deliberately excluded from the command address space.
        // Selection mode can number `DecidableSurfaceId`s later without ever
        // needing to ask whether a context run is secretly selectable.
        return switch (surface) {
            .context => null,
            .insert => |insert| insert.decidable,
            .delete => |delete| delete.decidable,
        };
    }

    /// Returns whether this surface can issue guidance commands.
    pub fn isControl(surface: Surface) bool {
        // Implementation note:
        // `.insert` and `.delete` are controls.  `.context` is text only.  This
        // distinction is encoded in the tag instead of in a nullable edit id.
        return switch (surface) {
            .context => false,
            .insert, .delete => true,
        };
    }

    /// Returns this surface's guidance ref when it can issue a guidance command.
    pub fn guidanceRef(surface: Surface) ?GuidanceSurfaceRef {
        return switch (surface) {
            .context => null,
            .insert => |insert| insert.guidance_ref,
            .delete => |delete| delete.guidance_ref,
        };
    }

    /// Sets the lifecycle state when this surface is decidable.
    pub fn setState(surface: *Surface, state: SurfaceState) Error!void {
        switch (surface.*) {
            .context => return error.SurfaceNotDecidable,
            .insert => |*insert| insert.state = state,
            .delete => |*delete| delete.state = state,
        }
    }

    /// Returns the painter decoration implied by this surface alone.
    pub fn baseDecoration(surface: Surface) SurfaceDecoration {
        // Implementation note:
        // Active-ness is hunk-local and is layered on by `Hunk.decorationFor`.
        // The surface can only report its own lifecycle state.
        return switch (surface) {
            .context => .normal,
            .insert => |insert| decorationFromState(insert.state),
            .delete => |delete| decorationFromState(delete.state),
        };
    }

    fn decorationFromState(state: SurfaceState) SurfaceDecoration {
        return switch (state) {
            .ready => .ready,
            .applied => .applied,
            .skipped => .skipped,
            .latent => .latent,
            .blocked => .blocked,
        };
    }
};

/// A stable review surface composed for one part of one revision.
pub const Hunk = struct {
    id: HunkId,
    kind: HunkKind,
    revision_ordinal: usize,
    display_mode: HunkDisplayMode,
    text: []u8,
    control: HunkControl,
    surfaces: []Surface,
    sink: ?CommandSink,

    /// Releases hunk-owned presentation storage.
    pub fn deinit(hunk: *Hunk, allocator: Allocator) void {
        // The hunk owns composed text and surfaces.  It does not own guidance,
        // raw zdeltas, or revision bodies.
        allocator.free(hunk.text);
        allocator.free(hunk.surfaces);
        hunk.* = undefined;
    }

    /// Returns an iterator over paint-facing presentation runs.
    pub fn runIterator(hunk: *const Hunk) RunIterator {
        _ = .{hunk};
        // Implementation note:
        // This iterator should skip hidden runs for modes such as `.inserts`
        // or `.deletes`; recomposition is reserved for modes that change which
        // surfaces are available, not just how existing surfaces are decorated.
        return .{
            .hunk = hunk,
            .index = 0,
        };
    }

    /// Returns the active decidable surface, if this hunk has one.
    pub fn activeSurfaceId(hunk: *const Hunk) ?DecidableSurfaceId {
        // Implementation note:
        // This is the "decide one" target.  Future selection mode belongs in
        // this same control union rather than in an unrelated list.
        return switch (hunk.control) {
            .none => null,
            .active => |active| active,
        };
    }

    /// Returns the active surface, if this hunk has one.
    pub fn activeSurface(hunk: *Hunk) Error!?*Surface {
        // Implementation note:
        // The implementation will scan `hunk.surfaces` for the active
        // `DecidableSurfaceId`.  It must never manufacture an active context
        // surface, because context has no decidable id.
        const active = hunk.activeSurfaceId() orelse return null;
        for (hunk.surfaces) |*surface| {
            if (surface.decidableId()) |decidable| {
                if (decidable == active) return surface;
            }
        }
        return error.SurfaceNotFound;
    }

    /// Makes one decidable surface the hunk-local active surface.
    pub fn activateSurface(hunk: *Hunk, surface: DecidableSurfaceId) Error!void {
        // Implementation note:
        // Activation should validate that the id belongs to one of this hunk's
        // current controllable surfaces.  That check is where "decide one"
        // stays attached to the same surface space used by selection mode.
        for (hunk.surfaces) |candidate| {
            if (candidate.decidableId()) |decidable| {
                if (decidable == surface) {
                    hunk.control = .{ .active = surface };
                    return;
                }
            }
        }
        return error.SurfaceNotFound;
    }

    /// Returns the decoration for a surface in this hunk.
    pub fn decorationFor(hunk: *const Hunk, surface: Surface) SurfaceDecoration {
        // Implementation note:
        // Active is not stored on the surface.  It is a hunk control relation,
        // which prevents multiple surfaces from all independently claiming to be
        // active.
        if (surface.decidableId()) |decidable| {
            if (hunk.activeSurfaceId()) |active| {
                if (decidable == active) return .active;
            }
        }
        return surface.baseDecoration();
    }

    /// Returns whether the surface is visible in this hunk's display mode.
    pub fn shouldShow(hunk: *const Hunk, surface: Surface) bool {
        return switch (hunk.display_mode) {
            .combined => true,
            .inserts => switch (surface) {
                .context, .insert => true,
                .delete => false,
            },
            .deletes => switch (surface) {
                .context, .delete => true,
                .insert => false,
            },
        };
    }

    /// Requests application of the currently active surface through Curator.
    pub fn applyActive(hunk: *Hunk, resolution: ?ApplyResolution) Error!CommandOutcome {
        // Implementation note:
        // The hunk knows which surface is active, but the command must flow
        // back through Curator so guidance stays behind one authoritative command
        // boundary.
        const active = hunk.activeSurfaceId() orelse return error.NoActiveSurface;
        const sink = hunk.sink orelse return error.MissingCommandSink;
        return try sink.dispatch(.{ .apply_surface = .{
            .address = .{
                .hunk = hunk.id,
                .surface = active,
            },
            .resolution = resolution,
        } });
    }

    /// Requests skipping of the currently active surface through Curator.
    pub fn skipActive(hunk: *Hunk) Error!CommandOutcome {
        // Implementation note:
        // Skipping changes both guidance history and hunk surface state.
        // The hunk should not attempt the guidance portion directly.
        const active = hunk.activeSurfaceId() orelse return error.NoActiveSurface;
        const sink = hunk.sink orelse return error.MissingCommandSink;
        return try sink.dispatch(.{ .skip_surface = .{
            .hunk = hunk.id,
            .surface = active,
        } });
    }
};

/// Iterator over a hunk's paint-facing runs.
pub const RunIterator = struct {
    hunk: *const Hunk,
    index: usize,

    /// Returns the next visible presentation run.
    pub fn next(iter: *RunIterator) Error!?Surface {
        // Implementation note:
        // The base case simply walks `hunk.surfaces`.  Display modes may hide runs
        // in-place, while future modes that introduce new controllable surfaces
        // may require Curator to build a fresh hunk before iteration starts.
        while (iter.index < iter.hunk.surfaces.len) {
            const surface = iter.hunk.surfaces[iter.index];
            iter.index += 1;
            if (iter.hunk.shouldShow(surface)) return surface;
        }
        return null;
    }
};

/// Commands sent from the front end or from a hunk back to Curator.
pub const CuratorCommand = union(enum) {
    apply_hunk: HunkId,
    skip_hunk: HunkId,
    apply_active: ?ApplyResolution,
    skip_active,
    apply_surface: ApplySurfaceCommand,
    skip_surface: DecidableSurfaceAddress,
    apply_rest: ?ApplyResolution,
    skip_rest,
    split_hunk: HunkId,
    set_display_mode: HunkDisplayMode,
    undo,
    redo,
    finish_revision,
    quit,
};

/// The guidance operation implied by a Curator command.
pub const GuidanceCommand = union(enum) {
    apply_next: ?ApplyResolution,
    skip_next,
    apply_rest: ?ApplyResolution,
    skip_rest,
    finish_step,
    undo,
    redo,
};

/// Address of a decidable surface within a retained hunk.
pub const DecidableSurfaceAddress = struct {
    hunk: HunkId,
    surface: DecidableSurfaceId,
};

/// Application request for one decidable surface.
pub const ApplySurfaceCommand = struct {
    address: DecidableSurfaceAddress,
    resolution: ?ApplyResolution,
};

/// Result reported after dispatching a Curator command.
pub const CommandOutcome = struct {
    guidance_changed: bool,
    presentation_changed: bool,
    active_surface: ?DecidableSurfaceAddress,
    surfaces_decided: usize,
    revision_finished: bool,
    quit: bool,
};

const OutcomeFacts = struct {
    guidance_changed: bool,
    presentation_changed: bool,
    surfaces_decided: usize,
    revision_finished: bool,
    quit: bool,
};

/// Erased command target used by hunks without sharing guidance directly.
pub const CommandSink = struct {
    context: *anyopaque,
    dispatch_fn: *const fn (*anyopaque, CuratorCommand) Error!CommandOutcome,

    /// Sends a command to the owning Curator.
    pub fn dispatch(sink: CommandSink, command: CuratorCommand) Error!CommandOutcome {
        return try sink.dispatch_fn(sink.context, command);
    }
};

/// Middleware state for one interactive revision-set review.
pub const Curator = struct {
    allocator: Allocator,
    guidance: *DeltaGuidanceSystem,
    seed: RevisionSeed,
    revision_index: usize,
    active_hunk: ?HunkId,
    hunks: std.ArrayListUnmanaged(Hunk),
    settings: PresentationSettings,
    display_mode: HunkDisplayMode,
    opened: bool,

    /// Creates a Curator over a revision seed and an initialized guidance system.
    pub fn init(
        allocator: Allocator,
        seed: RevisionSeed,
        guidance: *DeltaGuidanceSystem,
        settings: PresentationSettings,
    ) Error!Curator {
        // Implementation note:
        // Curator does not allocate or initialize guidance in this sketch.  That
        // keeps ownership explicit while we are still deciding how the front end
        // should provision the back end.
        return .{
            .allocator = allocator,
            .guidance = guidance,
            .seed = seed,
            .revision_index = 0,
            .active_hunk = null,
            .hunks = .empty,
            .settings = settings,
            .display_mode = .combined,
            .opened = false,
        };
    }

    /// Releases retained hunk presentation state.
    pub fn deinit(curator: *Curator) void {
        // Implementation note:
        // This frees hunks and their composed text, but not `guidance` and not
        // any revision bodies or zdelta text borrowed from `RevisionSeed`.
        for (curator.hunks.items) |*hunk| hunk.deinit(curator.allocator);
        curator.hunks.deinit(curator.allocator);
        curator.* = undefined;
    }

    /// Opens the first review revision and composes its initial hunk.
    pub fn open(curator: *Curator) Error!void {
        // Implementation note:
        // Opening should decode or prepare the current step's zdelta text and
        // hand it to guidance.  After successful open, guidance retains the raw
        // delta for history, undo, redo, and later correction.
        if (curator.opened) return error.RevisionAlreadyOpen;
        const step = curator.currentRevisionStep() orelse return error.NoActiveRevision;

        const raw_delta = try curator.allocator.create(ZDelta);
        raw_delta.* = zdelta_mod.decode(curator.allocator, step.zdelta_text) catch |err| {
            curator.allocator.destroy(raw_delta);
            return err;
        };

        try curator.guidance.openStep(raw_delta, step.ordinal);
        curator.opened = true;
        try curator.composeRevision();
    }

    /// Composes the current revision into retained presentation hunks.
    pub fn composeRevision(curator: *Curator) Error!void {
        // Implementation note:
        // The first pass creates one preview-backed hunk at a time.  Real hunk
        // resolution remains deferred: this does not choose durable boundaries
        // for the full zDelta.
        if (!curator.opened) return error.NoActiveRevision;

        const edit = try curator.guidance.previewNext() orelse {
            curator.active_hunk = null;
            return;
        };

        const text = try curator.allocator.dupe(u8, curator.guidance.currentText());
        errdefer curator.allocator.free(text);

        var surfaces = try curator.allocator.alloc(Surface, 1);
        errdefer curator.allocator.free(surfaces);
        surfaces[0] = surfaceFromPreview(edit);

        const hunk_id: HunkId = @enumFromInt(curator.hunks.items.len);
        const hunk = Hunk{
            .id = hunk_id,
            .kind = .revision,
            .revision_ordinal = curator.currentRevisionStep().?.ordinal,
            .display_mode = curator.display_mode,
            .text = text,
            .control = .{ .active = @enumFromInt(0) },
            .surfaces = surfaces,
            .sink = curator.commandSink(),
        };
        try curator.hunks.append(curator.allocator, hunk);
        curator.active_hunk = hunk_id;
    }

    /// Returns the current active hunk, if one is available.
    pub fn activeHunk(curator: *Curator) Error!?*Hunk {
        // Implementation note:
        // Returning nullable keeps "revision exhausted" distinct from I/O or
        // allocation failures.
        const hunk_id = curator.active_hunk orelse return null;
        return curator.findHunk(hunk_id) orelse error.HunkNotFound;
    }

    /// Returns the current active decidable surface, if one is available.
    pub fn activeSurface(curator: *Curator) Error!?DecidableSurfaceAddress {
        // Implementation note:
        // The active surface is derived from the active hunk plus that hunk's
        // `HunkControl`.  Curator should not store an unrelated active surface
        // field which could drift away from the hunk.
        const hunk = (try curator.activeHunk()) orelse return null;
        const surface = hunk.activeSurfaceId() orelse return null;
        return .{
            .hunk = hunk.id,
            .surface = surface,
        };
    }

    /// Dispatches a front-end or hunk-originated command.
    pub fn dispatch(curator: *Curator, command: CuratorCommand) Error!CommandOutcome {
        // Implementation note:
        // Dispatch is the single logging/test seam.  It translates command
        // vocabulary into guidance operations and presentation-state updates.
        return switch (command) {
            .apply_hunk => |hunk_id| blk: {
                const hunk = curator.findHunk(hunk_id) orelse return error.HunkNotFound;
                const surface = hunk.activeSurfaceId() orelse return error.NoActiveSurface;
                break :blk try curator.applySurface(.{
                    .hunk = hunk_id,
                    .surface = surface,
                }, null);
            },
            .skip_hunk => |hunk_id| blk: {
                const hunk = curator.findHunk(hunk_id) orelse return error.HunkNotFound;
                const surface = hunk.activeSurfaceId() orelse return error.NoActiveSurface;
                break :blk try curator.skipSurface(.{
                    .hunk = hunk_id,
                    .surface = surface,
                });
            },
            .apply_active => |resolution| try curator.applyActive(resolution),
            .skip_active => try curator.skipActive(),
            .apply_surface => |request| try curator.applySurface(request.address, request.resolution),
            .skip_surface => |address| try curator.skipSurface(address),
            .apply_rest => |resolution| try curator.applyRest(resolution),
            .skip_rest => try curator.skipRest(),
            .split_hunk => |_| error.NotImplemented,
            .set_display_mode => |mode| try curator.setDisplayMode(mode),
            .undo => try curator.undo(),
            .redo => try curator.redo(),
            .finish_revision => try curator.finishRevision(),
            .quit => try curator.outcome(.{
                .guidance_changed = false,
                .presentation_changed = false,
                .surfaces_decided = 0,
                .revision_finished = false,
                .quit = true,
            }),
        };
    }

    /// Applies the currently active surface.
    pub fn applyActive(curator: *Curator, resolution: ?ApplyResolution) Error!CommandOutcome {
        // Implementation note:
        // This is the "decide one" path.  It should resolve the active surface
        // through `activeSurface()` and then route through the same command path
        // as an addressed decidable surface.
        const address = (try curator.activeSurface()) orelse return error.NoActiveSurface;
        return try curator.applySurface(address, resolution);
    }

    /// Skips the currently active surface.
    pub fn skipActive(curator: *Curator) Error!CommandOutcome {
        // Implementation note:
        // Like `applyActive`, this should be syntactic sugar over the single
        // decidable-surface command address space, not a separate state machine.
        const address = (try curator.activeSurface()) orelse return error.NoActiveSurface;
        return try curator.skipSurface(address);
    }

    /// Applies one active surface.
    pub fn applySurface(curator: *Curator, address: DecidableSurfaceAddress, resolution: ?ApplyResolution) Error!CommandOutcome {
        // Implementation note:
        // This should resolve the addressed surface's `guidance_ref`, then ask
        // guidance whether that reference is still the next decidable operation
        // before applying it.
        const surface = try curator.findAddressedSurface(address);
        try curator.validateGuidanceRef(surface.*);
        const applied = try curator.guidance.applyNext(resolution);
        if (!applied) return error.NoActiveSurface;
        try surface.setState(.applied);
        try curator.composeRevision();
        return try curator.outcome(.{
            .guidance_changed = true,
            .presentation_changed = true,
            .surfaces_decided = 1,
            .revision_finished = false,
            .quit = false,
        });
    }

    /// Skips one active surface.
    pub fn skipSurface(curator: *Curator, address: DecidableSurfaceAddress) Error!CommandOutcome {
        // Implementation note:
        // A skip creates guidance history and then marks the surface skipped.
        // Latent surfaces may become ready after this point without
        // recomposing the hunk's text.
        const surface = try curator.findAddressedSurface(address);
        try curator.validateGuidanceRef(surface.*);
        const skipped = try curator.guidance.skipNext();
        if (!skipped) return error.NoActiveSurface;
        try surface.setState(.skipped);
        try curator.composeRevision();
        return try curator.outcome(.{
            .guidance_changed = true,
            .presentation_changed = true,
            .surfaces_decided = 1,
            .revision_finished = false,
            .quit = false,
        });
    }

    /// Splits a hunk into smaller retained presentation hunks.
    pub fn splitHunk(curator: *Curator, hunk_id: HunkId) Error!CommandOutcome {
        _ = .{ curator, hunk_id };
        // Implementation note:
        // The intended split is binary in spirit, but not mechanically halfway
        // through bytes.  It should look for an edit boundary that keeps the two
        // resulting hunks cognitively balanced.
        return error.NotImplemented;
    }

    /// Applies the rest of the active revision.
    pub fn applyRest(curator: *Curator, default_resolution: ?ApplyResolution) Error!CommandOutcome {
        // Implementation note:
        // This routes to guidance's rest operation, then marks all
        // still-eligible surfaces applied or stranded according to the returned
        // state.
        const count = try curator.guidance.applyRest(default_resolution);
        curator.active_hunk = null;
        return try curator.outcome(.{
            .guidance_changed = count != 0,
            .presentation_changed = count != 0,
            .surfaces_decided = count,
            .revision_finished = false,
            .quit = false,
        });
    }

    /// Skips the rest of the active revision.
    pub fn skipRest(curator: *Curator) Error!CommandOutcome {
        // Implementation note:
        // This is a bulk command, not a loop owned by the painter.  Curator owns
        // the transition because the retained hunk list must be reconciled after
        // the guidance state moves.
        const count = try curator.guidance.skipRest();
        curator.active_hunk = null;
        return try curator.outcome(.{
            .guidance_changed = count != 0,
            .presentation_changed = count != 0,
            .surfaces_decided = count,
            .revision_finished = false,
            .quit = false,
        });
    }

    /// Moves one decision backward through guidance history.
    pub fn undo(curator: *Curator) Error!CommandOutcome {
        // Implementation note:
        // Undo may cross hunk boundaries.  This is why exhausted hunks are
        // retained until a changed past strands and reclaims them.
        const moved = try curator.guidance.undo();
        if (moved) {
            curator.reclaimStrandedHunks();
            try curator.composeRevision();
        }
        return try curator.outcome(.{
            .guidance_changed = moved,
            .presentation_changed = moved,
            .surfaces_decided = 0,
            .revision_finished = false,
            .quit = false,
        });
    }

    /// Moves one decision forward through guidance history when possible.
    pub fn redo(curator: *Curator) Error!CommandOutcome {
        // Implementation note:
        // Redo is non-destructive while the future path is still live.  Curator's
        // presentation state follows guidance; it does not invent a branch.
        const moved = try curator.guidance.redo();
        if (moved) try curator.composeRevision();
        return try curator.outcome(.{
            .guidance_changed = moved,
            .presentation_changed = moved,
            .surfaces_decided = 0,
            .revision_finished = false,
            .quit = false,
        });
    }

    /// Finishes the active revision and advances to the next revision step.
    pub fn finishRevision(curator: *Curator) Error!CommandOutcome {
        // Implementation note:
        // Finishing promotes the guidance step, then Curator either composes the
        // next revision or reports completion of the revision set.
        try curator.guidance.finishStep();
        curator.opened = false;
        curator.active_hunk = null;
        curator.revision_index += 1;
        const complete = curator.currentRevisionStep() == null;
        if (!complete) try curator.open();
        return try curator.outcome(.{
            .guidance_changed = true,
            .presentation_changed = true,
            .surfaces_decided = 0,
            .revision_finished = true,
            .quit = false,
        });
    }

    /// Changes the hunk display mode, recomposing only when necessary.
    pub fn setDisplayMode(curator: *Curator, mode: HunkDisplayMode) Error!CommandOutcome {
        // Implementation note:
        // Combined, insert-only, and delete-only views should usually be render
        // filters over the currently stable surface set.
        curator.display_mode = mode;
        for (curator.hunks.items) |*hunk| hunk.display_mode = mode;
        return try curator.outcome(.{
            .guidance_changed = false,
            .presentation_changed = true,
            .surfaces_decided = 0,
            .revision_finished = false,
            .quit = false,
        });
    }

    fn currentRevisionStep(curator: *const Curator) ?RevisionStep {
        if (curator.revision_index >= curator.seed.steps.len) return null;
        return curator.seed.steps[curator.revision_index];
    }

    fn commandSink(curator: *Curator) CommandSink {
        return .{
            .context = curator,
            .dispatch_fn = dispatchFromSink,
        };
    }

    fn dispatchFromSink(context: *anyopaque, command: CuratorCommand) Error!CommandOutcome {
        const curator: *Curator = @ptrCast(@alignCast(context));
        return try curator.dispatch(command);
    }

    fn findHunk(curator: *Curator, id: HunkId) ?*Hunk {
        for (curator.hunks.items) |*hunk| {
            if (hunk.id == id) return hunk;
        }
        return null;
    }

    fn findAddressedSurface(curator: *Curator, address: DecidableSurfaceAddress) Error!*Surface {
        const hunk = curator.findHunk(address.hunk) orelse return error.HunkNotFound;
        for (hunk.surfaces) |*surface| {
            if (surface.decidableId()) |decidable| {
                if (decidable == address.surface) return surface;
            }
        }
        return error.SurfaceNotFound;
    }

    fn validateGuidanceRef(curator: *Curator, surface: Surface) Error!void {
        const ref = surface.guidanceRef() orelse return error.SurfaceNotDecidable;
        const preview = try curator.guidance.previewNext() orelse return error.NoActiveSurface;
        if (preview.raw_op_index != @intFromEnum(ref)) return error.StaleSurface;
    }

    fn outcome(curator: *Curator, facts: OutcomeFacts) Error!CommandOutcome {
        return .{
            .guidance_changed = facts.guidance_changed,
            .presentation_changed = facts.presentation_changed,
            .active_surface = try curator.activeSurface(),
            .surfaces_decided = facts.surfaces_decided,
            .revision_finished = facts.revision_finished,
            .quit = facts.quit,
        };
    }

    fn reclaimStrandedHunks(curator: *Curator) void {
        _ = .{curator};
        // First implementation hook only.  Once changed-history invalidation is
        // concrete, this will release hunks no longer reachable from the live
        // guidance path.
    }
};

fn surfaceFromPreview(edit: EffectiveEdit) Surface {
    // Guidance geometry is consumed at this edge only.  The retained surface
    // stores a generic text span plus a `GuidanceSurfaceRef`, not separate
    // expected/effective axes or correction-tree truth.
    const id: SurfaceId = @enumFromInt(0);
    const decidable: DecidableSurfaceId = @enumFromInt(0);
    const guidance_ref: GuidanceSurfaceRef = @enumFromInt(edit.raw_op_index);
    const text = spanFromPreview(edit);
    const state: SurfaceState = if (edit.class == .complex) .blocked else .ready;
    return switch (edit.expected_target) {
        .insert_at => .{ .insert = .{
            .id = id,
            .decidable = decidable,
            .text = text,
            .guidance_ref = guidance_ref,
            .state = state,
        } },
        .delete => .{ .delete = .{
            .id = id,
            .decidable = decidable,
            .text = text,
            .guidance_ref = guidance_ref,
            .state = state,
            .available_resolutions = edit.available_resolutions,
        } },
    };
}

fn spanFromPreview(edit: EffectiveEdit) Span {
    return switch (edit.effective_target) {
        .insert_at => |at| .{ .start = at, .end = at },
        .delete => |span| span,
        .complex => .{ .start = 0, .end = 0 },
    };
}

/// Error set reserved for Curator skeleton work.
pub const Error = zdelta_mod.ZDeltaDecodeError || guidance_mod.Error || error{
    NotImplemented,
    NoActiveRevision,
    NoActiveHunk,
    NoActiveSurface,
    HunkNotFound,
    MissingCommandSink,
    RevisionAlreadyOpen,
    StaleSurface,
    SurfaceNotDecidable,
    SurfaceNotFound,
};

const std = @import("std");

const Allocator = std.mem.Allocator;

const guidance_mod = @import("guidance.zig");
const ApplyResolution = guidance_mod.ApplyResolution;
const DeltaGuidanceSystem = guidance_mod.DeltaGuidanceSystem;
const EffectiveEdit = guidance_mod.EffectiveEdit;
const Span = guidance_mod.Span;

const zdelta_mod = @import("../zdelta.zig");
const ZDelta = zdelta_mod.ZDelta;
