# Terminal graphics runtime handoff

Prepared 2026-09-08 for a separate runtime agent. This is a memory transfer with
source findings and an acceptance plan, not an approved design or a merge
request. The Bee agent continues application/UI work independently, including
the Bee-only Phase 1 below, which requires none of this runtime work.

`MOD` = `~/go/pkg/mod/github.com/wippyai/runtime@v0.1.14-0.20260907210421-055505effbb0`.
Verify against the current upstream head before branching; module-cache paths
are evidence pointers, not an edit target. Runtime changes land as upstream
PRs per `docs/RUNTIME_UPSTREAM.md`.

## Mission

Add terminal graphics (kitty graphics protocol, sixel ingress) to the runtime's
terminal stack so Bee can capture images from child PTYs, composite them across
windows, re-emit them to capable hosts, and let agents capture window content —
locally and across mesh mounts — without breaking any existing peer, consumer,
or invariant. Everything must be additive; the breakage table below names the
exact traps.

The user explicitly asked:

- A clear canonical split between runtime and Bee, settled by adversarial
  review (three rounds against a second architecture agent; both converged):
  runtime owns the ordered graphics protocol state machine, resolved
  revision-consistent snapshots, retained image resources, replaceable codecs,
  host capability negotiation, and typed output adaptation. Bee owns desktop
  layout, clipping, occlusion, composition, agent-facing MCP tools, and raster
  capture orchestration. Both share versioned scene/resource contracts and mesh
  transport behavior.
- Architecture must not require breaking changes later; extending is fine.
- Pixels never cross into Lua for processing — Lua sees handles, metadata, and
  geometry; bulk bytes move Go-side (wasm codec slot later). Blob production
  from a wasm actor must remain possible behind the same store.
- Across the cluster: transmit-once blobs by handle, placements per frame,
  coalescing preserved; graphics capability advertised, never silently dropped.
- End goal: an agent (claude/codex CLI running inside Bee) can screenshot the
  whole desktop or one window and read the content; text-layer inspection ships
  first in Bee and is labeled as text-only (`layers`) so agents never mistake
  the text layer for the whole truth.

## Settled model (do not relitigate without new evidence)

- Internal model is kitty's semantic model: transmission/placement separation,
  runtime-scoped image ids (never child protocol ids — two PTYs can both send
  kitty image `7`; protocol ids live in session-scoped lookup tables), signed
  z, pixel-unit source crops, cell-mapped placements for unicode placeholders.
  Wire syntax lives in adapters: kitty ingress+egress, sixel ingress only.
- Snapshot is resolved display state, never protocol transaction history.
  Resources, placement definitions, and visible instances are distinct.
  Cell runs carry destination coords plus source-cell coords and source grid
  dimensions, or cell-mapped placements cannot be re-rendered.
- `placement_id` is distinct from `image_id` (kitty `p=`: one image, many
  placements; deletion targets placements).
- Image resources are immutable and revision-bound with explicit
  retention/release, so a capture outlives child-side deletion. Animation is
  current-frame resources advancing revision; timelines deferred.
- Graphics protocol state (creation-time sizing, per-protocol lifecycle:
  sixel dies on ED/EL, kitty placements survive text clears) must be
  synchronous with the emulator write path. The proxy
  (`MOD/service/terminal/proxy/`) already registers CSI/OSC handlers
  (`keyboard.go`, `page.go`) answering via `screen.InputPipe()`; graphics is a
  sibling using x/vt `RegisterApcHandler`/`RegisterDcsHandler`. x/vt has no
  image or scroll-observation model today; if its callback surface cannot
  express placement-affecting events, contribute hooks upstream to
  charmbracelet/x/vt rather than shadowing emulator state.
- Canvas invariant (`MOD/runtime/lua/modules/tty/canvas_region.go`) is
  untouched: images never enter row strings; emission is typed
  (`present(rows, {images = ...})`), surface composes the APC envelope.
- Bee-side Phase 1 (inspection MCP tool over `view:snapshot()` + composed
  frame) is versioned, `layers`-tagged, composition-revision-stamped; the
  runtime work only ever adds fields to it.

## Mesh findings (verified in source)

Wire format: `wireFrame` (`MOD/system/tty/mesh.go:40-53`) encodes via
msgpack maps with field names (`mesh.go:13,92-93`; no `StructToArray`,
`ErrorIfNoField` default false), so unknown fields are skipped by old peers
and zero-valued by new peers. `ttyapi.Snapshot` rides embedded by value.

Limits and lifecycle:

- 512 KiB frame cap enforced four times: `mesh.go:21,110-112,116`,
  `cluster/internode/class.go:40` + `state_manager.go:254-256`,
  `connection.go:413-415`. An oversize snapshot closes the mount
  (`mesh.go:298-301` → `mount.go:139-156`); no truncation exists.
- Coalescing: cap-1 watermark per watcher (`system/tty/port.go:347-361`),
  one outstanding notification per mount (`mesh.go:285-313` blocks on
  `record.ack`), consumer adopts only `Revision >=` cached (`mesh.go:573`).
- RPCs: strict `Seq == lastSeq+1` (`mesh.go:233`), 1-slot `callGate`
  (`mesh.go:475-484`), replay cache holds only the last reply
  (`mount.go:32-33`, `mesh.go:272-273`), 5 s timeout, 128 pending cap.
- Scheduling: strict-priority classes drain first, then `ClassPGBroadcast` ↔
  `ClassSurface` alternate per-peer with a 32-frame drain cap
  (`state_manager.go:361-407`); surface admission 32 + 32 reserved for requeue
  (`state_manager.go:201-209,263-268,496-505`).
- Capability: `MetadataSurfaceProtocol = "1"` advertised in memberlist meta
  (`boot/components/system/cluster.go:279-288`), checked by strict equality in
  `surfaceMesh.CheckPeer` (`tty_mesh.go:58-66`) before any surface byte is
  sent; mismatch fails attach locally. Note `cluster/stack.go:193-198` (the
  embedded stack) does not set the key at all.
- Leases: 30 s timer armed at mount issue (`mount.go:19,108`), reset on every
  accepted remote request (`mesh.go:274`), 10 s `opPing` renewal
  (`mesh.go:546-559`). `mountRecord.close()` (`mount.go:139-156`, sync.Once)
  is the single release funnel for all paths — lease expiry, revoke, issuer
  close, owner exit, transport failure.

## Breakage table — the additive path is narrow

| Change | Old-peer effect |
|---|---|
| New `Snapshot`/`wireFrame` field | Ignored (msgpack map, `ErrorIfNoField` false) |
| Bumping `wireVersion` (`mesh.go:20`) | Breaks: every frame dropped at `mesh.go:125` |
| New `opXxx` sent to an old peer | Breaks that mount: `mesh.go:268` → `ErrMeshProtocol` |
| New `internode.Class` byte | Breaks the whole connection: `connection.go:409-411` |
| Changing `MetadataSurfaceProtocol` from `"1"` | Breaks both directions: strict equality at `tty_mesh.go:61` |
| New separate metadata key | Ignored (pattern at `cluster.go:289-294`) |
| Frame > 512 KiB | Mount closed |

Consequences: do not bump `wireVersion`; do not add an internode class for
blobs (stay inside `ClassSurface` ops); advertise graphics as a separate
additive metadata key (e.g. `tty_surface_graphics = "1"`), leaving
`MetadataSurfaceProtocol` untouched; gate every new op and every image-bearing
snapshot on the peer's advertised capability so an old peer never sees them.

## Requirements from the runtime

R1. Graphics state machine in the proxy: APC `G` / DCS `q` capture, kitty
    command parse, transfer assembly, sixel decode behind a codec interface,
    runtime-scoped image/placement identity, per-protocol lifecycle ordered
    with the write path, child query replies via `InputPipe()`.
R2. Retained blob store: refcounted, revision-bound, budgeted; wasm-actor
    producers can insert blobs behind the same interface; release hooks in
    `mountRecord.close()` and `remoteViewport.finish` (`mesh.go:581-597`).
R3. Additive `Snapshot.images` + `layers`: placement records
    `{placement_id, image_id, kind rect|cells, geometry, z, src crop,
    revision}`; image metadata by handle; `surface.Present` gains an images
    dirty test (today only `changedRows`+`sameCursor` bump revision,
    `system/tty/port.go:318-340` — images alone must also advance it);
    Lua projection in `runtime/lua/modules/tty/viewport.go:203-215`;
    snapshots never inline pixel bytes (512 KiB kills the mount).
R4. Typed emission + host probe: `surface:present(rows, {images=...})`
    composes APC envelopes (base64, chunked at 4096); capability probe
    (kitty query + DA1, timeout) co-located with the encoder;
    `surface:capabilities()` for products. Canvas untouched.
R5. Blob fetch over mesh, inside `ClassSurface`: new ops after `opReply`
    with `Data []byte` chunks under 512 KiB, per-op payload bounds mirroring
    `mesh.go:260`, emission gated on the graphics capability. The strict
    sequence gate means chunk fetches serialize behind snapshot/input RPCs on
    the same attachment and the replay cache only covers the last chunk —
    either accept serialized transfer for v1 or add a separate sequence space
    on `mountRecord`; decide explicitly, do not pipeline over the existing
    gate. Respect the 32-slot admission (`ErrQueueFull` is currently fatal to
    the mount via `mesh.send` callers — blob ops need backpressure, not
    mount death).
R6. Capability advertisement: additive metadata key; extend
    `surfaceMesh.CheckPeer` to return a capability set (widen
    `ttyapi.MeshPeerChecker`, `api/tty/mount.go:58-60` — a variant interface,
    it currently returns only error); store per-peer capability on
    `remoteViewport` and `mountRecord` so the owner strips images for
    non-graphics peers and the consumer reports `layers = {"text"}`.
    Include `cluster/stack.go` if the embedded stack participates.
R7. Nothing in the table's "Breaks" column occurs; every existing test in
    `system/tty` and `runtime/lua/modules/tty` passes unmodified.

## How to prove it works

P1. Mixed-version mesh test: new owner + old consumer and the reverse, over
    the `meshFixture` in-memory transport (`mount_test.go:132-141`): old peer
    receives text-only snapshots, never a new op, never a torn connection;
    new consumer of an old owner reports `layers = {"text"}`. Extend the
    existing drop/duplicate fault injection to the blob ops.
P2. Wire-size property test: image-bearing snapshots never exceed
    `maxWireBytes` regardless of placement count; blob chunks individually
    bounded. Failure mode asserted as refusal-to-encode, not mount death.
P3. Coalescing preserved: `BenchmarkMeshSnapshotFanout`
    (`mesh_bench_test.go:529-579`) numbers unchanged for text-only frames
    (no regression in ns/op, allocs, `wire_frames/present`); new
    `BenchmarkMeshGraphicsFanout` reusing the fixture, reporting
    `wire_frames/present` and a new `wire_bytes/present` (add a bytes counter
    beside `sent` in `testSurfaceTransport`, `mount_test.go:111-131`).
    Assert a moved placement re-sends coordinates only — transmit-once blob
    proven by byte counters across N present calls.
P4. Lifecycle: lease expiry, revoke, owner exit, and transport failure each
    release retained blobs exactly once (hook assertions in
    `mountRecord.close()`); a capture retained at revision R stays readable
    after the child deletes its image.
P5. Emulator conformance: golden tests driving kitty transmit/place/delete,
    sixel, scroll/DECSTBM/ED/EL/resize/alt-screen against recorded expected
    placement tables; sixel-dies-on-erase vs kitty-survives asserted
    explicitly. TDD applies: each lifecycle rule gets its failing test first.
P6. Existing suites green unmodified (R7), including `canvas_boundary_test.go`
    (no escape leakage) and the Lua-side `tests/tty-mesh` load tests
    (`tests/tty-mesh/README.md:69-72`), with p95 latency comparable to
    `V1_REVIEW.md:12-15` for text traffic while a blob transfer is in flight
    (head-of-line check).
P7. End-to-end: a child emitting kitty graphics inside a Bee window renders
    on a kitty-capable host, clips at window edges, survives window drag
    (placement update only), and disappears cleanly on window close; on a
    non-graphics host the probe times out and the placeholder path renders.

## Open decisions for the runtime agent

- x/vt hook shape for placement-affecting events (scroll/clear/resize) —
  upstream contribution vs proxy-level interception where x/vt already
  yields control; investigate before committing to either.
- Serialized vs second-sequence-space blob fetch (R5) — measure first
  against the V1_REVIEW baseline before adding concurrency machinery.
- Animation budgeting (per-mount blob bytes/s) — required before any
  animated child is admitted over mesh; a static cap is acceptable for v1.
