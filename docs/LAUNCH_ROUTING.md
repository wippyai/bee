# Launch routing, topology and lifecycle

Status: design contract agreed on 2026-09-08 between Claude and Astra (Codex CLI
design thread `01a077f7-3266-7280-8dd5-a6c7b1cf35ea`), fifth round. It replaces
the hard-coded harness commands on the Terminal descriptor with one canonical
route: `bee claude`, the Start menu, `thread_launch` over MCP and another agent
all resolve a launch definition, which selects an admitted driver profile and a
placement; the resulting action owns the work and a window is only an
attachment to it. Nothing here is implemented.

Today's route, for reference: `bee.console` declares
`meta.application.commands: [{name: claude, arguments: [claude], fullscreen: true}, ...]`
and runs the binary in a PTY through `exec.native`. That stays only as a facade
over launch ids during migration.

## Astra's proposal in full

**Make `bee claude` resolve to a launch definition, not a Terminal command alias.** The definition selects an admitted driver profile and placement; the resulting action owns the work. A desktop window is an attachment to that action.

All additions below remain proposed until accepted.

## 1. Canonical routing

Use `registry.entry`, `meta.type: bee.launch_definition`.

| Field | Type / rule |
|---|---|
| `schema_revision` | `bee.launch-definition@1` |
| `launch_id`, `title` | Stable ID and display name |
| `command_names` | string[]; e.g. `[claude]` |
| `driver_profile_ref` | Exact profile entry reference |
| `default_mode` | `window|session|batch` |
| `default_placement` | `{kind:native|docker, node_selector:string}` |
| `allowed_overrides` | Explicit subset of mode, placement, node, workdir, thread |
| `argument_policy` | `{schema_ref, mapper_ref}`; typed arguments and measured argv mapper |
| `workdir_policy` | `{kind:caller_workspace|declared_resource|required, resource_ref?:string, relative_path?:string}` |
| `thread_policy` | `{kind:new|caller|named, thread_ref?:ThreadRef}` |
| `presentation` | `{start_menu:boolean, fullscreen:boolean, reuse:action|never}` |
| `required_context`, `required_grants` | Names of required context and grants; declarations grant nothing |

Do not offer unrestricted passthrough arguments on a managed-agent launch. Flags that replace MCP configuration, credentials, sandboxing or trust settings must not bypass the profile. Raw binaries remain available through **Native Terminal**, with its explicit OS-user authority.

Resolution:

1. Workspace/project selection.
2. User selection.
3. Installed module default.

Selections reference launch definitions; runtime preferences live in the database. Authored project definitions still pass publication. Within one tier, duplicate command claims return `AMBIGUOUS_COMMAND`; installation order never decides. Every selected definition is revalidated against the caller’s authority.

The CLI, Start menu, MCP `thread_launch`, and another agent all call:

`launch.resolve` → `launch.start`.

MCP exposes the typed argument schema with bound context removed. The gateway derives caller/thread identity.

A Hub driver module contributes a launch definition and profile. Start discovers admitted definitions directly; no console implementation changes.

**Deprecate Terminal’s harness `commands` entries.** During migration, keep command names as facades to launch IDs, never as a second executable route. Terminal retains only its own ordinary terminal-launch behavior.

## 2. Remote topology

For `bee claude --on forge`, distinguish the client attachment from operation ownership.

| Piece | Location |
|---|---|
| CLI and desktop presenter | Mac |
| Initial catalog resolution | Mac’s Bee host |
| Execution admission and supervision | Forge |
| Thread owner | Forge for a new thread; existing caller thread retains its explicit owner |
| Carrier, placement, child PTY/process | Forge |
| Child’s scoped gateway | Forge |
| Authoritative viewport | Forge |
| Physical terminal surface | Mac |

An existing thread on another owner is supported only through that owner’s authenticated contract. It is not migrated implicitly. The simplest remote launch creates its thread on Forge, allowing it to continue while the Mac sleeps.

Sequence:

1. **Resolve:** Mac authenticates the requester and resolves the launch definition, profile and destination. No action exists yet.
2. **Prepare destination:** Forge verifies delegation, exact compatible artifacts, resource mappings and its own admission policy. A Mac path is not a Forge workdir.
3. **Admit thread/work:** The thread owner creates/selects the thread and commits `action.admitted`, including execution owner, pinned launch/profile references and budget.
4. **Prepare execution:** Forge creates scoped credentials, gateway readiness and placement resources. Record durable control/effect intent before external launch.
5. **Start attempt:** Placement returns execution identity; owner commits `attempt.started`. Ambiguous launch becomes uncertain, not an automatic second process.
6. **Admit turn:** For a supplied brief, commit `turn.request`; deliver only after the profile’s readiness condition. A window opened without a brief may remain ready without a turn.
7. **Observe:** Stream, hook and MCP evidence becomes observations. Carrier settlement commits `turn.end`; logical messages and delivery marks remain distinct.
8. **Attach:** Mac receives an authorized viewport subscription and current scene/status. Attachment changes do not admit another action.
9. **Finish:** Carrier reconciles terminal evidence and placement cleanup, then commits attempt/action receipts.

Across the mesh send **typed control/input events and versioned viewport snapshots/deltas**. PTY bytes stay between the child and Forge’s terminal emulator. Clients should not independently interpret the same terminal stream into competing screen states.

When thread and execution owners differ, delivery uses durable outboxes and idempotent owner operations. Loss of the thread authority gates new work; it does not justify an unfenced local substitute.

## 3. Lifecycle

Do not put all proposed words into one mutually exclusive enum.

- Execution: `launching|ready|busy|waiting|idle|draining|ended|uncertain`.
- Admission gate: `open|pausing|paused`.
- Attachment: `attached|detached|reconnecting`.

A busy action can be detached. A disconnected client does not make execution uncertain.

Use existing lifecycle records plus a **core-owned, registered observation schema** `bee.lifecycle.control@1` for command intent/outcome: command ID, action/attempt, operation, requested/result phase, owner epoch and reason. Only the owner writes these control facts; vendor extensions cannot impersonate them.

| Transition | Trigger / authority | Evidence |
|---|---|---|
| → launching | Admitted user/agent request | `action.admitted`, owner launch-control intent |
| launching → ready | Placement and verified driver readiness | `attempt.started`, readiness observation |
| ready/idle → busy | Owner admits next input | `turn.request`, delivery evidence |
| busy → waiting | Correlated inbox request or registered thread wait | Approval reference or wait-control observation |
| waiting → busy | Authorized response/input accepted | Approval projection, delivery mark/control outcome |
| busy → idle | Session/window turn settles | `turn.end` |
| busy → ended | Batch completes and action settles | `turn.end`, receipts |
| → pausing → paused | Authorized pause; owner closes turn gate and reconciles current turn | Pause-control intent/outcome |
| paused → ready/idle | Authorized resume | Resume-control outcome |
| → draining | Stop/revocation/shutdown policy | Stop-control intent; cancellation evidence |
| → ended | Reconciled terminal state | Attempt/action `receipt` |
| → uncertain | Ambiguous launch, effect or terminal outcome | Uncertainty evidence; receipt only when that scope is settled |
| attachment change | Presenter/session supervisor | Attachment state projection; no execution receipt |

### Pause semantics

- **Window:** pause means close Bee’s input/delivery gate and request a supported harness interrupt. Report paused only when the turn is quiescent. Without reliable interruption, return `UNSUPPORTED_OPERATION`. Input hold alone is not pause.
- **Session:** stop admitting subsequent turns. An active turn drains; show `pausing` until it settles. A separately supported interrupt may shorten that drain.
- **Batch:** no generic pause. Offer cancel; continuation requires an explicit checkpoint-capable batch contract.
- **No SIGSTOP-based pause.** It can freeze locks and network calls while grandchildren continue.
- **Resume:** reopen the gate and use the same live session or verified resume reference. It does not undo a cancellation or recreate lost in-memory state.

Detach drops an attachment, never the action. Reconnect attaches to the live owner viewport; if no live viewport survives, show replay/status and explicitly indicate that the terminal instance ended or was reconstructed.

## 4. Status surface

Status is a projection of admitted lifecycle and evidence, not a parser’s guess from a spinner.

| Surface | Contents / source |
|---|---|
| Bar button | `Claude Code @ forge ●`; action title, execution owner and current status |
| Window title | Same identity; attachment warning separately |
| Collapsed recap | State/duration; current tool/task summary; last bounded answer/progress |
| Hive Manager | Action, thread, owner, mode, placement, execution/gate/attachment states |
| Inbox badge | Number of pending requests the principal may answer; owner-labelled |
| Timeline | Records in thread order, preserving observation versus authority and source |
| Disconnected window | Last frame plus “Forge unreachable; last confirmed busy” |

Glyph/token vocabulary:

| Status | Glyph | Theme role |
|---|---|---|
| Busy | `●` | accent |
| Waiting on this viewer | `◐` | warning |
| Waiting elsewhere | `◐` | muted |
| Ready/idle | `○` | muted |
| Pausing/paused | `‖` | warning/muted |
| Reconnecting | `⟳` | accent |
| Succeeded | `✓` | success |
| Failed | `!` | danger |
| Cancelled | `×` | muted |
| Uncertain | `?` | warning |

Text accompanies status; color is supplementary. “Ended” alone must not show a success check.

Project on committed changes, coalesce active presentation updates, and use recap checkpoints to bound replay. No idle one-second polling. Relative durations may refresh only while visible; reconnect animation is attachment-local.

## 5. Useful capability support

The inventory describes potential surfaces, not accepted Bee bindings. Publish capabilities only after testing the pinned profile.

| Harness/profile | Session gate/resume | Mid-turn interruption | Headless remote / thread integration |
|---|---|---|---|
| Claude | Per-process resume; later persistent stream | Protocol-specific support must be proven; PTY interruption is not inferred from hooks | Headless yes; MCP |
| Codex | Exec resume; later app-server | Prefer tested app-server cancellation; exec termination ends attempt | Headless yes; MCP |
| Agy | Conversation resume / persistent input | Do not promise until tested | Headless yes, but auth isolation/readiness need proof; MCP |
| Gemini, Cursor, Copilot, Goose, Grok, Kiro | Tested per-process or ACP profile | Advertise per protocol/profile only | Headless generally available; MCP; ACP useful for structured control |
| OpenCode | Session/server profiles | Tested server/ACP cancellation | Headless yes; MCP |
| Amp | Cloud resume or persistent stream | Steering is not automatically cancellation | Headless yes; MCP short waits or steering |
| Cline | Do not use broken JSON resume | ACP profile must prove cancellation | ACP recommended; MCP startup/call ceilings constrain pull |
| pi | RPC/session-tree resume | Test RPC abort semantics | Headless RPC; Bee tools require an admitted extension bridge |

Session gating works independently of vendor interruption. Batch pause remains unavailable across this table unless a specific checkpoint contract says otherwise. Every remote **window** profile still needs a real destination PTY.

Initial order: **Claude window/session, Codex window/session, then Agy session if useful; ACP afterward.** Keep other bindings absent rather than claiming breadth through raw command launchers.

## 6. Deliberate remote experience

Start shows “Claude Code.” Launch opens a node picker containing only authorized, compatible destinations. Selecting Forge also resolves a destination workspace/resource; no hidden home-directory fallback.

The bar shows `Claude Code @ forge ●`. Clicking attaches/focuses its viewport. Closing the laptop removes the attachment while Forge keeps supervision. Reopening discovers the persisted action and reattaches after authorization.

An inbox item says “Claude Code · forge” and identifies the requested operation. The decision returns to Forge’s approval owner. Timeline shows both the request/decision reference and the later execution outcome.

Presenter-facing operations:

| Operation | Status |
|---|---|
| Launch-definition list/resolve; destination compatibility | New catalog/admission API |
| `launch.start` and `launch.status` | New managed-action route |
| Action list/subscribe | New owner-scoped projection API |
| Viewport attach/detach/snapshot/subscribe/input | Existing local concepts; remote authenticated binding is new |
| Pause/resume/interrupt/cancel | New capability-checked owner operations |
| Inbox list/subscribe/decide | Proposed approval subsystem |
| Thread read/subscribe | Evolved thread boundary |
| Focus/base/fullscreen/geometry | Existing desktop-local responsibilities |

The presenter never needs executor handles, hook secrets, native PIDs or direct thread SQL.

## 7. Build first

### Local replacement

Implement one launch definition for `bee claude`, one profile, native placement and the thin thread/carrier path. Keep the console reusable as a terminal view; remove its ownership of the managed child’s lifetime.

Acceptance:

- CLI and Start resolve the same definition/digest.
- Launch creates a thread/action and one attempt.
- Readiness gates the brief; status comes from records.
- A correlated turn produces observations, `turn.end` and the correct reply.
- F12’s existing desktop behavior and client restart neither spawn a duplicate child nor end the action.
- Reattach restores current viewport/status; malformed arguments cannot replace the managed gateway configuration.
- Explicit termination cleans the owned process group and records its actual outcome.

### Remote placement

Reuse the same definition with Forge selected; add destination admission, resource mapping, owner control and remote viewport attachment.

Acceptance:

- Child, carrier, gateway and PTY demonstrably run on Forge.
- Mac sleep/disconnect leaves work running.
- Reconnect shows current frames and missed timeline records without replaying the prompt.
- Remote approval is decided once at its owner.
- Forge restart, lost launch acknowledgment and revoked attachment are distinguished; none triggers blind duplicate execution.

Start locally with the canonical route and lifetime separation. Remote execution then becomes another admitted placement and attachment path, not another launcher architecture.
