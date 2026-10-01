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
| `bee.harness.permission` | Decodes permission requests and runs the shared durable approval exchange for carriers, external turns and interactive hooks. Host-selected acceptance pins the adapter and executable; driver descriptors declare answer transports. |
| `bee.harness.launch` | Decodes `bee.launch_definition` entries, measures admission plans, admits the authenticated caller, prepares declared workspace resources and resolves component-owned CLI command names. The `locate_probe` entry measures activated descriptor drivers for the Sessions catalog; it reads login-file existence only. |
| `bee.harness.profiles` | Stores bounded workspace preferences in the node-owned profile feed. Reads and writes still require the caller's workspace authority. |
| `bee.harness.app` | Runs the Sessions application. Its list reads the public sessions contract and reopens stable addresses, including closed sessions. Its new-session picker reads `bee.sessions:catalog`, opens an idle session, and sends each input as one work item. `M` keeps the explicit PTY attach path. |

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

Saved profiles use `bee.agent-profile@2`, owned by the existing Harness/Sync profile feed. Stock resolved defaults and saved copies share this shape:

- Identity: `schema_revision`, `definition_ref`, `driver_binding_ref`, `name`; optional `agent_ref`, `owner_component_revision`, `spec_digest` fence the closure. Revisions stay in the CAS store envelope.
- `provider`: `model`, `effort`, `permission_mode`, `tool_allow`, `tool_deny`, `system_prompt_append`, `env`, `options`. Driver-specific values such as Codex sandbox and config profile use descriptor-declared `options` keys.
- `bee`: scoped `mcp`, `files`, `workspaces`, `credential_refs`, `approval_leases`, `permission_answers` (`provider`, `ask`, `deny`). References describe requested authority and never grant it.
- `placement`: `{kind="native", home="private"|"machine"}` or `{kind="docker", profile_ref=Ref, overrides?}`; `presentation`: `headless` or `window`; optional `workdir`, `thread`, `budgets={turn?,session?}`, `supervision={quiet_period_ms?,on_stall?}`.

The gateway checks saved MCP scopes against every decoded call, including nested Session definitions. Cross-workspace scopes name an admitted owner operation and destination; the tool owner authorizes the destination on every call. Resources issues attempt-bound, narrowed file grants; gateway revalidates their revocation, expiry and association identity. These private gateway grants remain independent of placement workdir grants, including repeated resource names. Credential selectors contain only definition-admitted references. Descriptor-declared environment renders deliver literals through the frozen placement delivery; credential references retain the broker's exact environment destination and cannot retarget secrets. Runtime lease references belong to the existing Approvals owner and require the same authenticated subject/workspace at admission and consumption. Copying a profile transfers no authority. Machine home requires host permission; native execution retains OS-user authority.

`bee.driver.cli-descriptor@3` declares each configurable field's canonical path, value schema, label, section, order, contexts, support evidence and renders. The generated Basic/Advanced form intersects these fields with canonical host `profile_restrictions`; locate reports version/help support and launch checks explicit saved values again. A supported version range is `>=major.minor.patch`. Config-only support names the descriptor's schema evidence. The catalog accepts `definition_ref`, `query` and stable `sort="name"|"driver"`; the picker exposes search and sorting without a catalog-wide page cap. Customize copy creates a fresh ID at revision zero. Conflicts preserve the draft and offer reload/copy; an uncertain save retries the same key.

Prompt additions stay in the placement's private home. Claude uses `--append-system-prompt-file` and `--strict-mcp-config`, Grok uses `--rules`, Codex reads additive `developer_instructions` from private projected TOML, OpenCode references the prompt file through projected `instructions`; agy and Muse declare private-home guidance files. Real installed-harness consumption is separately validated by acceptance evidence. The turn brief remains separate.

Docker uses the existing reusable `bee.placement.docker` templates. Overrides narrow host memory bytes, CPU millicpus, pids and admitted mounts, or retain the exact pinned image/non-root user. Network/tmpfs/directory/environment overrides reject when the template has no admitting mechanism. Revoke Docker access is an Advanced action. Passive readiness never provisions an image. Version and root/subcommand help run in an isolated, networkless probe container only for a cached immutable image. Capabilities cache by image and descriptor digest; Refresh runtime options preserves the draft and reloads image status/help. Missing images show the first-launch build requirement.

A transactional migration rewrites historical payloads to v2 once for the profile owner. Unknown fields, missing definitions, unsupported options and conflicting aliases produce `bee.agent-profile-migration@1` with original source, editable draft and reasons. Diagnostics block launch and repair through normal CAS. Projection revisions, tombstones, receipt/event bytes and other owners remain intact; feed cursors advance and fence old snapshots. Applied SQL migrations remain unchanged. Session snapshots carry `effective_profile`, `profile_digest` and durable `budget_consumption`. Cost limits reject with the exact budget field and usage codec because the shipped codecs have no trustworthy cost accounting. Window budgets reject at profile configuration because hook accounting cannot prove enforcement. Saved profiles with missing/invalid definitions, policies or descriptors retain their source and CAS revision in the JSON repair form.

## Boundaries

The carrier and placement contracts remain separate. A successful session send
means work is queued; it does not mean a CLI is running or a result is ready.
The external executor starts one CLI invocation per reserved turn and leaves
the session active after that invocation exits. Native Terminal continues to
run with the operating system user's authority.

Child exit does not end carrier output delivery. The carrier monitors the
placement runner and consumes its acknowledged output until stream EOF or a
terminal envelope. Placement owns the bounded pipe drain and output retention;
the carrier's fallback drain starts only after runner loss and consumes already
queued output before its deadline can settle a missing envelope.

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

The conversation restores durable Work history, provider metadata and live
turn events from the session thread. A quiet accepted turn appears as `stalled`
with its turn ref and quiet-period evidence; this view does not cancel or fail
the Work. A budget-limited Work displays its settled `budget exceeded` result.
Manual `M` attach remains in the catalog.
The unavailable Setup action explains the owner-reported reason and the
install/sign-in/refresh steps; it executes no provider commands.

Stock definitions offer Customize copy. Name, admitted folder, model, effort,
placement and presentation are basic fields. Advanced uses named turn/session
limits, a quiet period and stall action, and Docker memory/CPU/process limits
with explicit units. Empty limits inherit the host defaults. Ctrl+P opens Advanced permissions for instructions, conversation
selection, other options and tool grants with human-readable names. Saving uses
the existing profile revision and operation keys and grants no new authority.

Docker profiles with host-selected environment provisioning can be ready before
the network exists. The Sessions turn admission requests the existing person
approval, provisions the owned bridge and reachable restricted gateway, and then
uses the same external executor. The Agent conversation shows preparation
progress. In a Docker profile editor, Ctrl+R and Enter revoke this admission;
Escape cancels. This control belongs to the app namespace and requires the
host's person-only revocation grant.

Sessions opens as the empty desktop's landing page. The people-facing catalog
uses the `presentation:start_menu` feature, while programmatic definitions stay
callable through the Sessions contract. Conversation text preserves paragraphs
and wraps at spaces; tool activity is compact, and CLI diagnostics and technical
references are in Details. Tool results and diagnostics remain available when
historical work has settled, without replacing its final answer with streamed
fragments. Lists refresh activity during work and name sessions
with their first prompt. Closed conversations show history and offer a fresh
session using the agent definition's defaults. CLI write refusals explain that
they are separate from Bee approvals. Advanced Docker profiles expose Revoke
Docker access with the existing confirmation and Ctrl+R shortcut.

Starting a new session from a closed conversation reuses its saved profile ID and
revision, presentation and workspace through the public Sessions open operation.
Admission revalidates the saved revision; a changed or removed profile refuses
the new session instead of falling back to definition defaults.
