# Persistent desktop owner: implementation boundary

Status: retained resources verified through checkpoint `9308a39`. Public named
desktop attachment is not implemented. Preserve the native-runtime transport
ownership recorded in journal 183; do not enable the private TLS path.

Current integration dependency: journal request 206 has no response as of seq
207. The physical adapter README still requires a research runtime patch and
the `physicalclient` build tag. No supported cutover commit or public physical
attachment contract has been handed off. At checkpoint `9308a39` there were no live Bee validation jobs; the resumed
retained-supervisor candidate and its current gates are recorded below.
Production supervisor activation must use that supported boot/admission/lifetime
boundary; the verified local fixtures do not supply it. Keep the remaining
public integration incomplete rather than enabling the experimental adapter.

Attachment checkpoint `4a81c86067e1248f0ee8faa42ab4b68cc76f36c0` is pushed and
verified on `feat/independent-view-bindings`. Worktree
`/tmp/bee-desktop-attachments-20260909` is clean. The private helper
`bee.client:attachments` reuses protected-owner grants, denies competing
controllers and implicit mode changes, and retains failed revocations for retry.
Full `make check` session 24361 exited 0; log
`/tmp/bee-desktop-attachments-final-full-check.log`. Standalone build 97503 and
native acceptance 83827 exited 0; logs
`/tmp/bee-desktop-attachments-final-standalone.log` and
`/tmp/bee-desktop-attachments-native-check.log`.

The commit also includes the separately verified graceful display-close fixture
below. Exact source/fixture/client-state changes were applied to shared source
with `git apply --check` before application. Shared native manifest pins were
preserved. No PR or main update. Default launch remains unchanged; retained
production supervisor composition is still required.

Earlier attempts 6751 and 45565 ended at the known native-type cache identity
failure. Preserved cache: `/tmp/bee-desktop-attachments-comment-failing-cache`.
Explicit strict cache reset passed, log
`/tmp/bee-desktop-attachments-final-reset.log`; the resumed full check then passed.
Initial logs `/tmp/bee-desktop-attachments-full-check.log` and
`/tmp/bee-desktop-attachments-standalone.log` retain the failure. No casts or type
weakening were used. `LINT_FLAGS` provides explicit recovery without changing
normal cached lint.

Checkpoint `212d941` proves a supported local composition before production
extraction: a supervisor retains the virtual desktop viewport, while replaceable
display actors use recipient-bound native mounts. After display actor termination
and observed exit/revocation, the same desktop/shell remains usable and a fresh
display actor sees retained shell state. Source/pack checks pass in both appearance
modes, log `/tmp/bee-physical-display-proof.log`; worktree
`/tmp/bee-physical-display-proof-20260909`. The fixture/docs are also applied to
shared source. This is all within one runtime using virtual display surfaces,
not a public client implementation or network reconnect proof.

An independent prerequisite is now synced as
`a9f45e1a98087f0d21e11eabcb98d42d335f3556` on `feat/independent-view-bindings`.
The clean validation worktree is
`/tmp/bee-durable-ack-20260909`: every successful session acknowledgement is
committed before presenter success. The source/pack regression withholds the
separate rename scene notification, verifies the stored label and recovers after
abrupt runtime exit. It fails against the previous client and passes with the
fix. Logs `/tmp/bee-layout-ack-before.log` and `/tmp/bee-layout-ack-check.log`.
Full `make check` passed in session 40085, log
`/tmp/bee-durable-ack-full-check.log`; standalone assembly and native acceptance
both pass, logs `/tmp/bee-durable-ack-standalone.log` and
`/tmp/bee-durable-ack-native-check.log`. The exact source, regression and client
state documentation changes are also applied to the shared checkout, with a
focused `make layout-ack-check` target. No PR or main update. This fixes local commit
ordering; owner extraction and durable reconnect request identity remain pending.

## Retained supervisor synced

Checkpoint `26594cd58418a7d8f62678170fbc91135b7b064d` is verified on
`feat/independent-view-bindings`. `/tmp/bee-retained-supervisor-20260909` is clean. Private `bee.launch:retained`
uses the existing supervisor lifecycle for one workspace/initial desktop, with
trusted owner bootstrap, durable import readiness, host admission/render handling,
qualified strict attachment requests and automatic recipient EXIT revocation.
It uses the default client store and initial 100 by 32 virtual display. Node-level
singleton/workspace selection remains required; do not start it per display.
Ordinary launch and native transport remain unchanged.

Source/pack focused session 65996 exited 0, log
`/tmp/bee-retained-supervisor-check4.log`: forged sender and competing controller
denial, display crash/rejoin, explicit detach/rejoin, same shell and negotiated
shutdown with runtime service-failure checks. Full gate 46789 exited 0, log
`/tmp/bee-retained-supervisor-full-check.log`; standalone 27958 exited 0, log
`/tmp/bee-retained-supervisor-standalone.log`. Native acceptance 95055 exited 0,
log `/tmp/bee-retained-supervisor-native-check.log`.
Exact reviewed changes are applied to shared source; the launch registry index
was merged around its independently added headless entry and compared to the
verified entries. Shared native manifest pins were preserved. No PR/main update.
No validation sessions remain live. Public startup/rendezvous is still pending.
Earlier fixture failures are preserved in check/check2 logs; the failure was
corrected through nil narrowing and the existing bounded wait pattern, no casts.

## Retained resource component synced

Checkpoint `9308a39c55c386ba38d9caf3a89d9389a2779171` is verified on
`feat/independent-view-bindings`. `/tmp/bee-retained-desktop-20260909` is clean.
It adds the private
`bee.client:desktops` library. A supervising actor supplies the existing host,
exact desktop store and scope. The component retains the virtual viewport,
client process and attachment records. It rejects duplicate store bindings in
that supervisor and releases resources only on matching desktop EXIT, never
physical-display EXIT. Caller operations must be serialized; this is not a
cross-supervisor lock or a public enrollment API. The fixture authenticates
readiness and still performs host admission/render selection itself.

Focused source/pack checks in both appearance modes passed: initial session
80960 and resource-cleanup session 89573 both exited 0. Logs
`/tmp/bee-retained-desktop-check.log` and
`/tmp/bee-retained-desktop-resources-check.log`. Full gate session 97600 exited 0,
log `/tmp/bee-retained-desktop-full-check.log`. Standalone session 70185 exited 0,
log `/tmp/bee-retained-desktop-standalone.log`. Native acceptance session 11504
exited 0, log `/tmp/bee-retained-desktop-native-check.log`. Exact reviewed source/fixture/client-state changes are applied to the shared
checkout after a successful patch check. The acceptance document had changed
independently, so its latest-checkpoint paragraph was merged manually; unrelated
content and native manifest pins were preserved. No PR/main update. Public local
launch and runtime transport are unchanged. No validation sessions remain live.

## Current coupling

The desired user contract is a named desktop retained by its owning node. A
physical client attaches to that desktop; closing or crashing the client is a
detach, not an application close. Rejoining the same desktop recovers its saved
window layout and attaches to applications still running at their owners. A
desktop may reference applications on other nodes without moving their execution
or state ownership. This remains a target contract, not public launch behavior.

Persist stable desktop and application identities, layout and supported app
checkpoints in their owners' stores. Do not persist native handles, live input
grants or PIDs as reusable authority. Transient rendering/input state is rebuilt
on attachment. Node restart restores supported durable state; it cannot restore
a native shell that died with the runtime.

`src/core/client/main.lua::run_client` opens the client database, starts the
session, routes host requests, owns the physical display and starts presenters.
Its cleanup closes the database and display and terminates the session. Moving
only the database path to a remote node would not separate these lifetimes.

`adopt` writes a session projection through the generation-checked client store
before publishing that projection. Since checkpoint `a9f45e1`, the client also
commits the complete projection carried in a successful session acknowledgement
before forwarding success. The separate scene channel is not required for that
commit. Existing abrupt-client recovery tests establish retained committed state
and application targets, not survival of every in-flight input or durable
deduplication across reconnects.

## Extraction sequence

### Supported composition choice

The `212d941` fixture narrows the first production change: reuse `bee.client:main`
as the durable desktop actor on a supervisor-owned virtual terminal. Its database,
session and presenter can remain together initially. A separate physical adapter
observes that virtual terminal through a recipient-bound mount and, only when
admitted to control, forwards input. Losing the adapter must not terminate the
virtual-terminal owner or desktop actor. This avoids duplicating the existing
desktop/session logic while changing the actual lifetime boundary.

The node supervisor must retain both the virtual viewport resource and the
desktop actor. The physical adapter must own neither. The existing
`bee.launch:supervisor` currently monitors its initiating client and tears down
the workspace when that client exits, so wrapping that entry unchanged is not
a retained-desktop implementation.

Do not spawn `bee.client:local_entry` once per retained desktop as a shortcut.
That entry starts its own workspace supervisor/host and selects the default
workspace store. Two desktops over one workspace would then duplicate the host
and compete over its store. Use `bee.client:main` against the already selected
host; the node supervisor retains each desktop's viewport and exact client-store
binding, while the workspace's supervisor remains the sole admission authority.
Desktop attachment must never implicitly create another workspace host.

Workspace admission stays with the workspace host's authenticated supervisor:
`bee.host.clients.control` does not grant authority from an arbitrary owner PID.
An extracted desktop component therefore reports readiness and renderer changes
to that supervisor, which performs admission/render operations under its existing
authority. Do not make the desktop component a second workspace owner or give
physical adapters direct host-control permission. Workspace permission grants
belong to the durable desktop actor; physical input rights belong to its current
attachment and are revoked independently.

The virtual terminal's controller is a desktop-wide capability: it can activate
menus and applications, unlike an application-specific observer mount. Expose
that distinction explicitly at admission. Start with one controller, bounded
observers, and explicit authorized transfer; do not translate an observer opening
a window into desktop control.

Public startup still needs node discovery/rendezvous and physical attachment from
the runtime lane. Implement and prove the retained supervisor composition locally
before wiring those APIs; do not infer a callable remote API from this design.

1. Retain database, session, qualified targets, host connections and application
   routing in a TTY-free desktop owner. Reuse the existing client identity as
   the durable identity; preserve its applied migration. Admission selects the
   exact database resource and permissions. Names are mutable labels.
2. Move physical events and display lifetime to an attachment actor. In the
   selected virtual-desktop composition, presenter restart stays with the
   retained desktop actor. Physical attachment loss retires only attachment
   grants and resources; it does not terminate the desktop owner, delete saved
   tabs or close applications.
3. Have the desktop owner authenticate and serialize layout commands. A visible
   committed projection and any durable-success reply must follow the database
   commit for the corresponding revision. Define retry identity and conflicting
   retry behavior before exposing these operations over a reconnecting channel.
   Do not turn an unacknowledged send into an automatic input retry.
4. Admit one controlling attachment per desktop initially. Additional viewers
   receive observe-only grants. Independent monitor layouts use separate durable
   desktop identities. Controller replacement requires owner authorization and
   successful retirement of the prior rights; opening a view cannot steal them.
5. Attach physical clients through the supported native-runtime surface once its
   entrypoints, authenticated identities and peer-loss events are handed off.
   Keep application execution at its application owner. A disconnected remote
   target stays in saved layout as unavailable until authoritative removal.

Public selection and supervisor routing can then use the same desktop-owner
operations for local and remote attachment. Runtime discovery descriptors and
desktop names grant no access. Registry state and application state keep their
existing separate owners; no centralized Hive database is introduced.

## Acceptance before activation

Follow-up fixture worktree `/tmp/bee-display-detach-20260909` supplied the
graceful display close/rejoin coverage now synced in `4a81c86`. The old
fixture forwarded the physical `close` event into the retained desktop and
failed with "Desktop or application exited with its physical client"; negative
gate 6126 exited 2, log `/tmp/bee-display-detach-before.log`. The fixture adapter
now decodes input and consumes close locally. Gate 57590 exited 0 from source
and pack in both appearance modes, log `/tmp/bee-display-detach-after.log`.
This is fixture evidence, not production physical-client transport. Do not
forward attachment lifecycle events into desktop shutdown in the future adapter.

- Kill a physical client after a committed layout reply; rejoin the same desktop
  with retained layout and the same live Terminal shell.
- Lose a reply after commit; reconnect with the same request identity and prove
  replay without applying the layout command twice. Conflicting retries fail.
- Kill the desktop owner during a layout transaction; restart with either the
  old or new complete revision, never a partial projection or false receipt.
- Attach two observers and one controller; deny observer input, resize and
  layout writes, and deny a competing controller without authorized transfer.
- Keep two independently named desktop layouts over one application owner.
- Disconnect a remote application owner; preserve its unavailable saved target
  and require fresh grants on rejoin. Never persist PIDs or mounts as authority.

Owner restart restores committed layout and supported application checkpoints.
It does not restore a native shell killed with its runtime. Physical-client
loss, desktop shutdown, application close and node shutdown remain distinct.
