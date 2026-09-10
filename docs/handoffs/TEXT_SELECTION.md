# Text selection — installed local path and native-client acceptance

Bee must select text from one application window and copy it on the physical
client where the user requested the operation. Applications can remain on their
owner node; their placement does not select the clipboard destination.

## Presenter behavior

Use an explicit Select text action so application mouse handling remains usable
and host-terminal Shift-drag interception is not required. On entry, capture the
selected view's identity, attachment generation, dimensions and immutable visible
rows. Selection coordinates are cells relative to that view's body, never the
composed desktop. Dragging outside the body clamps to it; background windows
cannot contribute text. Render the frozen rows while selecting, so later output
cannot change what the user is about to copy.

The model owns only endpoints and a bounded snapshot. Native cell-aware slicing
handles wide glyphs and combining characters; an explicit native plain-text
helper removes terminal controls before clipboard delivery. Do not introduce a
Lua ANSI parser. Multiline selection preserves line breaks. Soft-wrap recovery
is not available from viewport rows, so do not claim to reconstruct logical lines.

Escape cancels. Copy is explicit, then selection retires. View retirement,
attachment replacement, resize and F12 cancel selection. Selection and copied
text are ephemeral, absent from client databases, scene records and checkpoints.

## Physical delivery

The existing presenter-to-client `bee.workspace.control` channel authenticates
the current presenter. A bounded copy request can use this path to the local
client owner. The physical output adapter must serialize its clipboard write
with frame writes. Sending OSC52 is a request to the terminal; it does not prove
the OS clipboard changed. Do not report a confirmed clipboard write without an
acknowledgement mechanism.

The native physical client now handles an explicit Ctrl+C through the existing
`bee.desktop:copy` Hive operation. The request binds owner execution, workspace,
desktop and session. The owner authenticates the native caller and requires its
current controlling attachment. The retained supervisor queues a reserved
`bee.copy` key marker, carrying its fresh correlation ID, through the same native
input queue as preceding mouse events. It is consumed by the presenter and never
forwarded to an application. The marker is an ordering token, not authorization;
only the supervisor’s matching pending request can receive a result. This keeps
selection reads behind admitted input.

The presenter returns the frozen text through the authenticated owner chain.
The retained supervisor matches the pending ID, recipient and exact mount; the
native binding matches the Hive sender, call ID and session, and rechecks the
native observation grant before physical output. No selected text means the
original Ctrl+C is forwarded once. A valid selected reply writes only to that
client's native physical surface. Its matching key release is consumed.

This uses the existing serialized Hive call/reply reader. The unsolicited-copy
inbox experiment from checkpoint `003fe91` was removed: explicit copy requests
need no second control queue or background dispatcher. No runtime API or mesh
transport was added. Only the controlling client can use this path today;
independent selection by observing clients remains unimplemented.

Clipboard text must not be added to snapshots: reconnect and observation would
replay or distribute it. A copy request targets one live physical attachment.
Another observer or replacement attachment must not inherit pending requests.
Retiring a selection cancels work not yet submitted; once a physical write has
been accepted, cancellation cannot claim to undo it. Delivery, expiry and
completion feedback need explicit tests when this control operation is wired.

## Acceptance required before enablement

- Two overlapping windows: only the selected body's text reaches copy output.
- Forward/reverse drags, off-body clamping, ANSI, wide/combining glyphs and bounds.
- Output arriving mid-selection cannot alter captured text.
- Escape, resize, app exit and F12 cannot deliver a stale copy.
- Two physical clients: only the requesting attachment receives the operation;
  unrelated observers and revoked mounts receive none, reconnect does not replay it.
  Selecting an observed application's already-authorized content must not require
  control of that application.
- Clipboard requests and synchronized frame writes remain separate valid terminal
  sequences; unsupported delivery gives visible feedback without a remote fallback.

The native extraction prerequisite is proposed in
[runtime PR #720](https://github.com/wippyai/runtime/pull/720): typed
`tty.text.plain(string) -> string`, with TTY race tests and repository lint passing.
It is not adopted in Bee's selected runtime and adds no clipboard delivery.

The presenter and local client now implement this flow on the candidate runtime.
The terminal model/render suites have 22 passing focused cases, and the client
request decoder has two. `make terminal-selection-check` exercises two actual
Terminal windows from source and pack and decodes the exact foreground text
from physical OSC52 output. The application clears its live output while the
selection remains frozen; copying yields the original text, then the latest
output becomes visible. It also covers hover stability, resumed input,
cancellation/rejoin and resize. Full foundation and remote-recipient acceptance
remain open.

The physical output prerequisite is
[runtime PR #722](https://github.com/wippyai/runtime/pull/722), assigned to skhaz.
It adds optional `tty.ClipboardSurface` and typed `surface:clipboard(text)`;
physical writes share the surface lock, closed leases reject them, and virtual
surfaces are unsupported. Native terminal, lease, LuaTTY and virtual TTY race
suites and scoped lint pass; hosted CI is green. The release pin is unchanged.

The global executable now includes the tested local candidate, installed at the
user's explicit request. Run `bee` normally. Older persisted deployments can still select stale code;
`--base` is a diagnostic recovery path that selects different registry history,
not the required embedded-default behavior. Do not use it as an overlay-preserving
upgrade workaround. Right-click the window title or tab,
choose **Select text**, drag within its body, then press Ctrl+C. Escape cancels.
The installed executable passed `tests/native_binary.py`, including actual
physical selection/copy, Settings recovery, Terminal input and F12. Evidence is
`/tmp/bee-global-installed-check.log`. Remote physical clipboard routing remains
unimplemented; this local acceptance does not establish the two-client gate.

### Window-body context menu

Ordinary right-click inside the topmost window opens its Bee menu, including
**Select text**. Title and tab menus retain the same action. Shift-right-click
in the body is forwarded to the application. The captured menu click/release
must not leak into the underlying application. Source/pack and standalone
selection acceptance now start selection from the body; the source/pack proof
also retains title-menu coverage and checks the Shift-right-click exception.

## Native-client checks and release gate

The source copy route and native binding are implemented, but the global launcher
has not switched to them. Exact sender/session/expiry and plain-text bounds have
native tests. The physical tests prove exact OSC52 output using the
clipboard-capable runtime, ordinary Ctrl+C fallback, refusal without disconnect,
key-release suppression, revoked-mount rejection and no side effect or fallback
on uncertain replies. The actual-source owner/client composition proves the
no-selection request through the owner and ordinary shell interruption, alongside
cold startup, retained rejoin and terminal restoration.

`make clipboard-contract-check` runs the pure decoder's three cases in Wippy's
own test runner without a desktop/Hive activation. It covers the 8192-byte plain
text limit and conservative JSON expansion bound. Oversized encoded text is
refused visibly rather than truncated or dropped by the actor's 16 KiB inbox.
Definite selection refusals use `INVALID_STATE` and do not interrupt the app or
detach the client. Uncertain requests are never retried. The owner's status says
"Clipboard requested"; this is not an OS clipboard acknowledgement.

The isolated combined runtime `d1f6599833` now supplies launch, text extraction,
clipboard and typed native channels together. It builds through the pinned builder;
strict Bee lint checks 315 entries and the standalone bundle contains 517 entries.
`local-owner-selection-check` passes in 72.104 seconds: actual rendered selection,
immediate Copy ordering, exact physical clipboard output and reconnect without replay.
The full foundation suite is running against this toolchain; no full-suite or new
global-install claim is made yet. Independent observer selection and embedded-default
upgrade with preserved registry overlays remain separate acceptance requirements.

### Cancellation and actual-owner denial checks

A deterministic regression reproduced clipboard output when cancellation occurred
inside the final native grant check. Physical copy now rechecks cancellation after
that check and before beginning clipboard output. The physical race/vet suite
passes with the regression; a write already submitted remains non-retractable.

The actual-source composition also creates a second native client on a separate
stack: it can attach as observer, but Copy returns `DENIED`. A substituted session
returns `DENIED`, and copying after explicit detach returns `NOT_FOUND`. The
original controller continues using its retained shell after those refusals.
These prove denial, not independent observer selection. The expanded composition
passes under race checking (60.585s); the combined-runtime release gate is unchanged.

### Full native-client selection gate

`BEE_OWNER_TEST_WIPPY=/path/to/pack-toolchain make -C native
local-owner-selection-check MESH_RUNTIME=/path/to/combined-runtime` runs the
full gate (write the command on one line). For the native-only checkpoint also
set `BEE_OWNER_TEST_SOURCE` to the current absolute Bee source checkout.

The fixture interprets actual physical output with the native VT emulator,
locates Terminal text and its context menu, selects the text, and presses Ctrl+C
immediately after mouse release. It requires exactly the selected text in one
OSC52 request, continued shell input, and no clipboard replay on a fresh client.
It does not substitute a local display or inject selection text into the result.

The initial run reached selection and Ctrl+C, then timed out awaiting the owner
(`/tmp/bee-full-selection-gate.log`). The compiled-module preflight now identifies
the missing prerequisites directly: `tty.text.plain` and physical surface
`Clipboard` (`/tmp/bee-full-selection-prerequisite.log`). This is a failing release
gate, not a successful selected-window proof. With a combined runtime the same
test proceeds through the complete interaction and reconnect checks.
