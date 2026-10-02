# Working on Bee

Read [the repository README](../../README.md), [development conventions](conventions.md),
and the [documentation map](../README.md) before changing Bee. Source
under the root and selected modules' `src/` directories is production code;
tests, fixtures and the legacy proof of concept in
`../bee-legacy/` are never runtime dependencies.

Bee-owned code and artwork are MIT. Preserve the upstream license for Wippy and
other dependencies when changing or copying runtime code. Keep core ownership,
standalone application processes, typed boundary decoders and host-selected
permissions intact. Registry metadata describes capabilities; it never grants
them. Native Terminal runs with the operating system user's authority.

Keep desktop responsibilities in the `src/` component folders (`src/host`,
`src/client`, `src/launch` and their siblings, one namespace per folder),
public application helpers and appearance values in
`modules/application/src`, and application UI in `modules/<module>/src/app` child namespaces. The
core desktop shell remains in `src/desktop` and `src/terminal`.
Use the [UI brand book](../guides/ui.md) and
[application visual style](../guides/app-style.md) for presentation and
interaction rules. The offline toolkit reference gives compact, tested examples
for `bee.app:frame` and `bee.app:viz`. Apps use
public contracts such as `bee.app:client` and
`bee.threads:authority_local`;
they do not import private broker or store modules.

The `bee/workspace` component owns the node catalog, application checkpoints,
display assignments, binding rows and its migration ledger. The root host owns
its resources, permissions, leases and recovery lifetime.
Registry configuration/history, thread records, approvals, resources and
credentials remain owned by their respective subsystems, even when stores
share a SQLite file. Never edit an applied migration, alter a migration
checksum, query another owner's tables, or reset a workspace database to hide
a migration failure. Use an owner operation for every state change.

Use typed values for every decoded message and request. Validate versions,
identities, strings, arrays, state and request IDs before changing state. A PID
is an execution address, not a credential. Authenticate the message sender and
the relevant instance, token or operation grant. A successful send means
queued; it does not mean ready, committed or stopped. Timeouts can leave an
unknown result and must not cause a blind retry.

Use the Makefile for development:

```sh
make setup
make lint
make check
make pack
make portable-deployment-check
make standalone
```

`make run` starts an editable source workspace. `make desktop-check` runs the
desktop acceptance against the built pack, and `make attachments-check` covers
host/client attachment grants and revocation. Use focused tests while editing,
then the checks required by the changed boundary. Documentation-only changes
need link and source consistency checks; they do not need a full terminal run.

Development loads the selected components' `src/` trees. `make native-pack` uses
`wippy pack --module` for the root and every physical component; `make portable-deployment-check`
boots their exact local vendor WAPPs with no source or replacements. Keep binaries, registry
stores, credentials, fixture data and temporary databases outside the pack. Inspect assembled packs
for test registrations and fixture dependencies. Do not add a local runtime
binary or legacy source to production, and do not edit registry tables directly
to work around source loading.

The desktop client may replace its presenter with F12. The session can pick up
changed code with a same-PID handoff; on an incompatible checkpoint, its client
restarts the session from the committed layout while retaining the desktop and
applications. See [process handoff](process-handoff.md). Workspace, broker,
host or application changes still require the owning process lifecycle and
recovery path. Admitted application definition and imported-library changes now
restart the execution behind its retained view through the broker's existing
checkpoint/resume path; incompatible state produces a visible fresh-start notice.
Preferences and opted-in application checkpoints persist in the
workspace database. Settings opts in to checkpointing; a dead native Terminal
does not become a portable checkpoint. See
[application contracts](../reference/applications.md) for launch, attachment,
checkpoint and close behavior.

The host keeps application execution independent from presentation. A producer
may be ready without a presenter, a client may observe a retained desktop, and
attachments carry recipient-bound observation, input and resize authority.
Detaching a client does not stop admitted applications. A stale attachment
loses its authority. The public client, local host and explicit Hive invite
join are implemented; remote workspace composition, automatic Hive enrollment
and discovery and destination Hub transfer/install remain unfinished. Managed
headless turns and Docker Sessions use the external executor and pull scheduler.
Docker first-use network/gateway admission uses one person approval; see
[Docker placement](../../modules/placement-docker/src/README.md).
Keep those operations labeled as proposals until their acceptance contracts
exist.

`bee observe` attaches a read-only display to a running local Bee and never
starts or displaces the controller. `bee recover` boots Bee's shipped bundle
with fresh registry history while preserving workspace and application state;
it does not select a managed launch by name. These commands keep the local
owner boundary and provide no remote enrollment. On a node without a folder
workspace (`bee daemon`),
`bee client` picks one of the node's workspaces and Ctrl+] returns to the
picker to switch; see [the workspace catalog](../reference/workspace-catalog.md).

## Managed agent containment

Managed CLIs run with the operating system user's authority. Every
batch worker opened through a session uses a private retained session home containing only
the provider login, configuration and conversation state its driver declares and the host
credential broker projects; the launch policy admits no host HOME inheritance
and no prompt-free permission mode. When a person chooses a named Codex profile,
the driver projects that one admitted profile file into the private home so
Codex resolves it with the selected profile. Each CLI further runs under its
own permission control where one exists and is proven: Codex
`--sandbox workspace-write`, Claude Code and Grok default permission
modes, Muse `on-request` approval, agy `--sandbox`. Grok and OpenCode
offer no workdir confinement Bee can select, so the host records those
batch routes as `unconfined`.

For an edit-capable profile with a write-granted workdir, the host-selected
Git worktree plugin resolves the repository's Git directory and shared common
directory from Git's metadata files. Placement passes those physical paths to the CLI sandbox only when both
remain within a host-admitted write root; this lets a worktree commit while
keeping the host's admitted roots as the outer boundary.

These controls are CLI permissions, not operating system confinement. A
managed CLI can still read any file the OS user can read outside its
workdir; only full OS confinement, a separate Wippy runtime feature,
removes that authority. Treat the worker brief, workdir and home as the
containment boundary and keep Hive keys, Bee state and other provider
logins outside every granted folder and home.

## Managed provider login

Each built-in Codex, Claude, agy, Grok, Muse and OpenCode window launch declares
its provider's login evidence as safe paths relative to its provider home, plus
a command to show the person. Native placement checks file existence in the
home selected for that attempt. Missing evidence yields a typed
`LOGIN_REQUIRED` notice in placement's prepare reply. The Agent window shows
the provider and command before starting the CLI; Enter continues to the
provider's own sign-in flow, and the title keeps a login hint. This is a
helpful observation, not an authentication decision: Bee checks existence
only and leaves sign-in to the provider.

The built-in window profiles select the machine home under their existing
host-selected `allow_host_home` policies, including Muse. Grok keeps its private
window home and declares `grok_login` for the host's first-use setup and broker
projection. Its selected retained session home holds login and conversation
state across turns, with `GROK_HOME` pointing into the same home on resume.
These selections keep catalog login evidence and the CLI's launch
home aligned: a saved machine login needs no second sign-in. A driver's window
descriptor and profile agree on the home selection. Batch profiles keep their
declared private homes and receive only broker-admitted login files.

Confined batch workers receive only their driver's declared files from the
machine home:

| Driver | Login | Ambient configuration | Child home selection |
|---|---|---|---|
| Claude Code | `.claude/.credentials.json` | `.claude/settings.json`; Bee creates the onboarding marker `.claude.json` only with a present login | `CLAUDE_CONFIG_DIR` points inside the attempt home |
| Codex | `.codex/auth.json` | `.codex/config.toml` | `CODEX_HOME` points inside the attempt home |
| Agy | `.gemini/antigravity-cli/antigravity-oauth-token` | `.gemini/antigravity-cli/cache/onboarding.json` | private `HOME` |
| Grok | `.grok/auth.json` | `.grok/config.toml` | `GROK_HOME` points inside the attempt home |
| Muse | `.config/muse/auth.json` | `.config/muse/settings.json` | private `HOME` |
| OpenCode | `.local/share/opencode/auth.json` | `.config/opencode/opencode.json`; declared `.config/opencode/towers.key` dependency | XDG config and data roots point inside the attempt home |

The machine login source selects the runtime's `owner_safe` link policy. On Unix,
external links resolve to regular files owned by the process UID or root;
the target and every canonical parent through filesystem root must also have
`mode & 022 == 0`, including sticky directories. Resolution is bounded to 40
symlinks and detects loops. Refusals retain the runtime's path and reason in the
broker and Agent catalog. This requires the runtime release containing
[runtime#890](https://github.com/wippyai/runtime/pull/890); the current pin safely
ignores the field and retains containment. Windows retains containment because
ownership/ACL evidence is unavailable. See the
[credential contract](../../modules/credentials/src/README.md#machine-login-links).

Only a provider's login file may be returned to its original path after the
child exits. The broker requires the active attempt projection and unchanged
source digest, so a newer machine login is left in place. Provider configuration
and other home files are not copied back. Codex `--profile NAME` keeps working
with the selected `NAME.config.toml` projected into that attempt's private home.

The local Hub can inspect, plan and apply host-authorized components. Governed
overlays can stage bounded content, freeze an immutable candidate, obtain an
exact approval, apply it through the owning host and recover after restart.
Hub discovery or installation alone does not publish an admission binding or
grant an application authority. Publication, public enrollment and destination
package transfer are separate authority boundaries; see
[package boundaries](package-boundaries.md) and [the system map](ownership.md).

When changing a behavior, update the relevant implementation contract and run
the checks for that owner. Preserve stable definition IDs independently of
versions and paths. Carry expected revisions, capability changes and recovery
information in activation requests. Describe whether an update supports live
rejoin, application checkpoint/restore or a full restart; do not describe a
proposal as a callable API.
