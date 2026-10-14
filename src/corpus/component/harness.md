# bee.harness

The harness owns host-selected CLI definitions, launch admission, window
presentation and process preparation. `component/sessions` owns the durable
session contracts and the public catalog; Threads owns the durable records.
Driver packages own provider arguments, codecs and readiness descriptors.

## Namespaces

| Namespace | Responsibility |
|---|---|
| `bee.harness` | `types` and the `profiles` contract |
| `bee.harness.catalog` | Reads one registry snapshot, classifies driver bindings (`meta.type: harness.driver`) as compatible or not, and marks them activated only when `bee.harness.launch:harness_activation` names them. Compatibility and activation describe capabilities; neither authorizes a launch |
| `bee.harness.launch` | Decodes `bee.launch_definition` entries, measures admission plans, admits the authenticated caller, prepares declared workspace resources, resolves framework agents (`agent_resolver`) and managed runs, and measures readiness (`locate`, `readiness`, `probe_cache`). The `locate_probe` function measures activated drivers for the Sessions catalog; it reads login-file existence only. Entries `harness_activation` (the activated driver bindings) and `harness_setup` (first-use roots and credentials keyed by definition-declared resource names) |
| `bee.harness.carrier` | Runs one admitted attempt as a machine over injected IO: checkpoint, hooks, hook records, delivery, interrupted-attempt recovery, settlement of the thread receipt through the typed driver and placement contracts |
| `bee.harness.permission` | Decodes permission requests and runs the shared durable approval exchange for carriers and interactive hooks; driver descriptors declare answer transports |
| `bee.harness.binding` | Functions `call` (the profiles facade), `capabilities`, `resolve`, `admit`, `start`, `locate_probe`, `setup`, `present`, `present_restore`, `present_type`, `present_activity`; the `profiles_local` binding of `bee.harness:profiles`; `windows`, the window constructor for each admitted placement binding |
| `bee.harness.profiles` | The typed saved-profile protocol (`bee.agent-profile@3`) |
| `bee.harness.profiles.binding`, `.persist` | Profile validation against pinned driver definitions and descriptors, and the Sync profile feed with CAS revisions, tombstones and receipt replay |
| `bee.harness.service` | `presentation` and its owner and executor processes, and the `open`, `restore`, `type`, `activity` functions through which Sessions drives a window; `carrier` process; `session_idle_stop` |
| `bee.harness.api` | HTTP endpoints for gateway hooks: `POST /hook/:action`, `GET /hook/:action/:event`, `POST /hook/:action/mcp` |
| `bee.harness.app` | The Sessions application (`bee.harness.app:app`, command `agent`) |
| `bee.harness.migrations` | Probe output cache table |

Driver metadata and registry entries never select an executable path, login
source, placement grant or permission policy. Launch admission pins the
definition, driver binding, driver profile, policy and placement plan. The
Sessions app and the `bee claude`, `bee codex`, `bee agy`, `bee grok`,
`bee muse` and `bee opencode` commands (`bee.app_command` entries naming
`bee.harness.app:app` with the driver's `default_window` profile) pass the selected
definition back through admission before execution.

`BEE_SESSION_IDLE_STOP` (default `24h`) is how long an agent nobody uses keeps
running after its last turn ended with nothing waiting; empty keeps agents running
until their session closes.

## Session catalog and readiness

The new-session picker calls `bee.threads.sessions:catalog.list`. The Sessions owner
lists registered definitions and saved profiles, checks each route with launch
admission, then asks the host locator to measure the driver's executable,
version, platform and login-file presence. Ready entries appear by default;
`include_unavailable` adds entries that need attention with their reason. The
locator never reads login contents, and catalog results grant no launch
authority. Opening a session performs admission again under the caller's
host-selected policy.

## Saved profiles

Saved profiles use `bee.agent-profile@3`, stored in the Sync feed
`harness.profiles:<workspace digest>` with `harness.profile.changed` events.

- Identity: `schema_revision`, `definition_ref`, `driver_binding_ref`, `name`; optional `agent_ref`, `owner_component_revision`, `spec_digest`. Revisions stay in the CAS store envelope.
- `provider`: `{schema_ref, schema_revision, values}`. Values use descriptor option IDs. Legacy named fields and `options` flatten into that map; unknown or invalid values retain their source in a repair diagnostic. Role, context and traits remain profile fields.
- `bee`: scoped `mcp`, `files`, `workspaces`, `credential_refs`, `approval_leases`, `permission_answers`. References describe requested authority and never grant it.
- `placement`: `{kind="native", home="private"|"machine"}` or `{kind="docker", profile_ref, overrides?}`; optional `workdir` and `thread`. Every session runs in an interactive window, so a profile names no presentation, budgets or supervision.

Copying a profile transfers no authority; machine home requires host
permission. The gateway checks saved MCP scopes against every decoded call.
`bee.driver.cli-descriptor@4` declares each configurable field's canonical path,
ID, value schema, label, description, group, security class, defaults, contexts,
support evidence and mappings. `bee.driver.descriptor:effective` compiles these
with installed capabilities and host constraints for the editor, admission and
rendering. Rights narrow by subsets, denies combine by union, limits take minima,
and permission modes compare declared capabilities. Person-only values require
a person write; consent never raises host ceilings. The catalog accepts `definition_ref`, `query`
and `sort` (`name` or `driver`). A saved profile that no longer validates keeps
its source and CAS revision in a JSON repair form (`bee.agent-profile-migration@1`
diagnostic) and blocks launch until repaired. Docker overrides narrow memory,
CPU, pids and admitted mounts, or keep the pinned image and non-root user.

## Sessions application

The Sessions list shows each session's title, state (idle, working, stalled,
needs you, stopped, closing, closed) and last reply. Enter opens a session's live
terminal, N opens the new-session picker, X closes a session, W toggles current
workspace or all, C shows closed sessions, R refreshes. The picker has search (`/`),
unavailable entries (U), setup (S), sort (Ctrl+S), edit or customize copy (E) and
new profile (N). Esc goes back. Closing the window leaves its sessions running
and addressable; each Sessions window is a separate application instance.

The profile editor has Basic and Advanced fields (Ctrl+P), saves with Ctrl+S under
the existing profile revision and operation keys, and shows Revoke Docker access
(Ctrl+R) for Docker profiles. Saving grants no new authority.

Docker profiles with host-selected environment provisioning can be ready before
the network exists; admission then requests the person approval described in
`component/placement:docker`. Starting a new session from a closed one
reuses its saved profile ID and revision; a changed or removed profile refuses the
session instead of falling back to defaults.
