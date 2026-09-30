# bee.harness

The harness owns host-selected CLI definitions, launch admission and process
preparation. The Sessions owner owns durable agent sessions, work scheduling
and the public catalog. Driver packages own provider arguments, codecs and
readiness descriptors.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.harness.catalog` | Reads one registry snapshot, classifies activated driver bindings and reports component diagnostics. Compatibility and activation describe capabilities; neither authorizes a launch. |
| `bee.harness.carrier` | Runs one admitted CLI attempt, persists its checkpoint and settles its thread receipt through the typed driver and placement contracts. |
| `bee.harness.launch` | Decodes `bee.launch_definition` entries, measures admission plans, admits the authenticated caller, prepares declared workspace resources and resolves component-owned CLI command names. The `locate_probe` entry measures activated descriptor drivers for the Sessions catalog; it reads login-file existence only. |
| `bee.harness.profiles` | Stores bounded workspace preferences in the node-owned profile feed. Reads and writes still require the caller's workspace authority. |
| `bee.harness.app` | Runs the Sessions application. Its list reads the public sessions contract and reopens stable addresses, including closed sessions. Its new-session picker reads `bee.sessions:catalog`, opens an idle session, and sends each input as one work item. `M` keeps the explicit native PTY attach path. |

## Session catalog and readiness

The new-session picker calls `bee.sessions:catalog.list`. The Sessions owner lists
registered definitions and saved profiles, checks each route with launch
admission, then asks the host locator to measure the driver's executable,
version, platform and login-file presence. Ready entries appear by default;
`include_unavailable` adds entries that need attention with their reason.
Repeating the call probes again. The locator never reads login contents, and
catalog results grant no launch authority. Opening a session performs
admission again under the caller's host-selected policy.

Driver metadata and registry entries never select an executable path, login
source, placement grant or permission policy. Launch admission pins the
definition, driver binding, driver profile, policy and placement plan. The
Agent window and the `bee claude`, `bee codex`, `bee agy`, `bee grok`,
`bee muse` and `bee opencode` shortcuts pass the selected definition back
through admission before execution.

Saved profiles contain bounded options, MCP tool names, instructions and
optional workdir or thread preferences. The picker carries the selected
profile ID and revision into `session_open`; a changed profile must be selected
again. Profile contents do not add authority. Provider credentials are
projected by the host credential broker and are never returned through the
catalog.

## Boundaries

The carrier and placement contracts remain separate. A successful session send
means work is queued; it does not mean a CLI is running or a result is ready.
The external executor starts one CLI invocation per reserved turn and leaves
the session active after that invocation exits. Native Terminal continues to
run with the operating system user's authority.

## Sessions application

Sessions is the primary desktop destination for agent work. The list shows
activity separately from session lifecycle and offers all permitted sessions or
a current-workspace filter. Saved workspace labels and relative folders come
from the public workspace catalog. Unreadable metadata says unavailable.
Opening an existing row uses `get`; opening a ready catalog choice uses `open`.
Enter sends Work; Ctrl+K asks to cancel current Work; Ctrl+X asks to close intake
and drain accepted Work. Escape returns to the list. Closing the window leaves
its sessions addressable. At 120 columns the conversation shows a session rail;
compact screens use Escape to return to the list. Ctrl+D shows the session ref.

The conversation currently retains only Work submitted by this window and its
observed results. The public session snapshot exposes neither thread identity
nor Work history, so reopening after window loss cannot reconstruct the Work
queue or read live turn events. Durable history, provider metadata, last result
and interactive Terminal switching need those public associations; they are
proposals until the owner exposes them. Manual `M` attach remains in the catalog.
The unavailable Setup action explains the owner-reported reason and the
install/sign-in/refresh steps; it executes no provider commands.

Stock definitions offer Customize copy. Name, admitted folder and model are
basic fields. Ctrl+P opens Advanced permissions for instructions, conversation
selection, other options and tool grants with human-readable names. Saving uses
the existing profile revision and operation keys and grants no new authority.
