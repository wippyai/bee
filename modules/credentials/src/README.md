# bee.credentials

The owner-local credential broker. A definition names a credential in a
workspace from a source the host admits (`bee.credentials.env:credential_sources`: an
`env.variable` entry, the workspace or `*`, the audience or `*`, a provider,
the projection kinds allowed); its digest covers configuration and source
identity, never bytes, and redefining it moves to the next revision so
existing projections stop resolving. `define` accepts `expected_revision`: zero
creates only when absent; a positive revision replaces only that exact definition.
The revision check, write and returned view share one transaction. A mismatch
returns `CONFLICT` without invalidating projections. Omission preserves explicit
unconditional replacement. First-use setup must use zero and inspect a conflict
rather than replace an existing login configuration. The allowlist is checked again at
every `check` and `materialize`, so removing a source or an audience takes
effect for projections already issued. A projection binds the authenticated subject, an audience, one
attempt, the profile, binding and launch-policy digests, the provider's
frozen declared destination, the materializer identity, an expiry and the workspace
authorization epoch. `check` re-checks the bindings without bytes and reports
file-source `source_present` from a stat when its host-selected source is
available; an unavailable source leaves this field absent.
`availability` is a manager-only metadata probe for an existing file
definition and reports whether its admitted login file is present;
`materialize` re-checks them for an admitted materializer and returns the
value once, in a reply nothing persists, recording the generation key, the
generation and the materializer's actor. A generation key is accepted once
per projection: a lost reply is never repaired by a silent second read; the
runner refuses the attempt instead. The source is read at materialization,
so a rotation at an unchanged reference reaches the next materialization. A
value that an environment cannot carry (NUL, line breaks, over 8 KiB) is
refused without being echoed. Materializer authentication is entry-scoped:
the materialize action is attached to the placement service and runner
entries and to no caller-selectable scope.

`define` accepts `optional: true` for file and environment sources. A missing
optional source consumes the generation and returns its definition metadata
with `present: false` and no `value`; the next generation can try again.
Populated projections return `present: true` and the optional flag alongside
their bounded bytes. Optional environment absence also carries its fixed
destination and UTF-8 encoding so placement can validate the reply before
omitting the variable. Missing required sources, permission failures, invalid
JSON and other source failures remain errors.
File materialization opens the admitted path directly and treats only a
`NOT_FOUND` open error as absence. An existence probe cannot distinguish a
missing file from an unreadable path; permission-denied open errors refuse an
optional projection too.

The host's `data.formats` map selects reviewed component-owned registry entries
whose data declares an environment destination or a relative login layout.
Claude and Codex declare their API-key destinations and JSON login files;
Agy declares an opaque file. File sources name a host-selected `fs.directory`
using `source.kind: fs_directory`. The host source row selects the source path;
when omitted, it uses the declared login basename.
Callers cannot choose a path, filename or mount. A file source may also carry one
host-selected setup declaration: `setup_path`, an optional retained
`setup_destination`, and `setup_content_format` (`json` or `opaque`). The
`setup_initialize_empty` flag admits an empty opaque base only where the driver
composes generated configuration into that file. Ordinary optional settings
files stay absent when their source file is missing. `write_back: true`
separately admits the broker to return a changed login file to that exact
source path; read access alone never grants this capability. A source may also
list exact-path rules in `auxiliary_files` using a source prefix, destination
prefix, suffix and content format. A private driver may request an individual
file matching such a rule; the broker reads only that path and includes it in
the transient home format. Each driver request marks the file optional or
required: an absent optional file is omitted, while an absent selected Codex
named profile refuses the launch. These rules cover named-profile files such
as `.codex/ds-flash.config.toml`; they do not scan the source tree.
Materialization reads that optional path from the same source. JSON setup is
bounded to 4 KiB; opaque setup is bounded to 64 KiB. It appends the bytes to the
transient returned format as an initializer that may be installed even when an
optional login is absent. The setup declaration and its contents are never
stored in a definition or projection, and a missing setup file is allowed. The
host's `bee.credentials.security:credential_file_policy` grants filesystem
access separately from source metadata for availability, checks and bounded
materialization reads. Only the `write_back` binding receives the separate
`credential_file_write_policy`. Write-back serializes the source comparison and
atomic replacement, revalidates the projection, attempt, generation, provider
path and original source digest, and replaces only that login file. A newer
source login causes a conflict and remains untouched. Configuration and state
files are never written back.
Registry source metadata in `bee.credentials.env:credential_sources` alone cannot grant filesystem
read: if a source ref is admitted by metadata but absent from
`bee.credentials.security:credential_file_policy`, availability and materialization fail closed
(`UNAVAILABLE`). Adding another source requires an explicit host policy grant
naming the login root.

Ordinary callers (workspace managers, projection subjects, and outsiders) cannot
directly read login files or invoke `check` or `materialize`. The broker methods
accessible to ordinary callers (`define`, `issue_projection`, `list`, `availability`,
`revoke`, `revoke_all`, `capabilities`) and error replies carry only identifiers, digests
and status views; they never echo secret bytes. Secret file contents are strictly
absent from persisted database state: definitions, projections, generations,
epochs, and the schema migration ledger (`bee_credential_schema_migrations`) never
hold secret bytes. Only the admitted placement materializer holding
`bee.credentials.security:credential_materialize_policy` receives bytes once per generation key in a
transient RPC reply that nothing persists.

Login file reads stop after 64 KiB plus one byte; supplemental JSON and opaque
setup reads stop after 4 KiB and 64 KiB plus one byte respectively. Login and
present setup files reject empty or oversized content. An explicitly admitted
empty opaque composition base is the only exception.
JSON formats additionally require a JSON object or array; opaque formats preserve
arbitrary bytes and report encoding `bytes`. Both return bytes only in the
authorized transient materialization reply.
Definition IDs/revisions accompany file replies so placement can bind retained
login state to the selected source without hashing its contents. The broker
never searches or exports the OS keyring: when credentials exist only there,
a file projection is unavailable. Provider-specific JSON fields are opaque.

Database migration 2 (`file_sources`) introduces `fs_directory` source and `file`
projection kinds by rebuilding `bee_credential_definitions` with strict SQLite
CHECK constraints (`provider IN ('claude', 'codex')`, `source_kind IN ('env_variable', 'fs_directory')`,
`projection_kind IN ('environment', 'file')`), while preserving all existing populated
definitions, projections, consumed generations, and migration ledger records.

Migration 3 (`optional_files`) adds the constrained `optional` flag to
definitions with a default of false; it is additive and preserves existing
definitions, projections and the applied migration ledger.

Migration 4 (`declared_providers`) removes the storage-level Claude/Codex enum
while retaining a bounded, nonempty provider label and the other constraints.
The populated upgrade proof preserves definition identities, projection receipts,
consumed generations and earlier migration records across reopen. Provider declarations do not authorize source reads.

Migration 5 (`frozen_formats`) adds nonsecret `format_json` to definitions and
projections and backfills the historical Claude/Codex layouts without reading
registry declarations or credentials. Existing definition digests, identities,
receipts and retained-home markers are preserved. Unknown historical formats
remain unbound and are refused. New definitions freeze the decoded host-selected
layout; projections copy it. Issue, availability and use compare the saved layout
with the current declaration; use also checks the projection's saved layout.
Changing the declaration requires explicit redefinition and fresh projection.
It cannot redirect a previously admitted credential.

The pure `formats` decoder bounds paths, environment names and initialization
files, rejecting traversal, sparse arrays, duplicate files and file/directory
collisions. Native placement admits only the broker's frozen format and refuses
its reserved identity-marker path. The component owns its layout; callers still
select a credential name and never supply a materialization path.

Test suites enforce these invariants using synthetic workspace-scoped fixtures
(`.wippy/*-fixture`) and never touch actual host credential files or OS keyrings.

Built-in private batch routes use the following home-relative files from the
machine home. Placement projects only these admitted files into a fresh attempt
home; it never walks or exposes the rest of the user's home. Bee's generated
provider configuration is composed separately by the selected driver.

| Provider | Login file | Ambient configuration/state | Private CLI home |
|---|---|---|---|
| Claude Code | `.claude/.credentials.json` | `.claude/settings.json`; Bee initializes `.claude.json` only when login bytes are present | `CLAUDE_CONFIG_DIR` points to the attempt's `.claude` |
| Codex | `.codex/auth.json` | `.codex/config.toml`; one selected `.codex/<name>.config.toml` when a named profile is used | `CODEX_HOME` points to the attempt's `.codex` |
| Agy | `.gemini/antigravity-cli/antigravity-oauth-token` | `.gemini/antigravity-cli/cache/onboarding.json` | private `HOME` |
| Grok | `.grok/auth.json` | `.grok/config.toml` is the private composition base | `GROK_HOME` points to the attempt's `.grok` |
| Muse | `.config/muse/auth.json` | `.config/muse/settings.json` is the private composition base | private `HOME` |
| OpenCode | `.local/share/opencode/auth.json` | `.config/opencode/opencode.json` is the private composition base | private XDG config and data roots |

The host source allowlist admits token write-back for these login files only.
When a child refreshes its login, the runner returns the changed file after
exit; the broker requires the same active projection generation and an
unchanged original source digest. Codex private routes preserve
`--profile NAME` by projecting only `.codex/NAME.config.toml` through its
host-admitted auxiliary-file rule.

The host links the exact placement binding persisted on new projection receipts;
an unlinked materializer fails projection issuance closed, and caller or artifact
input cannot select it. Existing projection rows retain their recorded binding.

Native placement accepts file projections only with a selected retained session
home or a driver's declared private attempt home. Retained homes preserve
provider-refreshed bytes when the recorded definition identity matches;
attempt homes are disposable and return token changes through guarded
write-back. Changed identity or a partial retained seed refuses reuse. See
[native placement](../../placement-native/src/README.md) for the delivery and
filesystem guarantees. File contents never enter the environment projection
route.

First-use harness setup can create definition-declared credential names from
host-selected source configuration, without reading the secret. Built-in batch
definitions for all six providers select optional login files under the host's
existing home directory. An absent login leaves the private destination empty
and the window keeps its existence-only login hint; host credential directories
are never created. Agy may import its onboarding JSON, and Grok may import only
`.grok/config.toml` into retained `.grok/.bee-global-config.toml`. Placement
structurally inserts Bee's scoped MCP subtree into the private
`.grok/config.toml`; it never writes the machine or project trees. The host allowlist owns the relative source path; callers cannot supply
it. Source metadata and path are bound in the definition digest and rechecked
before availability or projection use. A changed source requires explicit
redefinition. Existing definitions with an older digest are refused rather than
silently retargeted. Fixture acceptance covers each driver's declared files and
a confined worker whose attempt home excludes unrelated machine-home files.
The standard test gates use synthetic logins and fixture CLIs; they never
discover or consume a host account. Docker delivery is unimplemented.

Revocation stops future materialization; a live attempt is stopped by placement at its next
reconciliation, which the placement sweeper schedules on a fixed delay and
which is reported as pending until the exit is proven, with
`credential.revoked` evidence; an environment value already inside a running
child cannot be scrubbed.

| Slice | Responsibility |
|---|---|
| `bee.credentials` | `persist/broker`: the nine contract operations and the store opened through `bee.persist`; root `sources`: host allowlist, provider destinations, linked references; contract `contract` with binding `local` |

Actions: `bee.credentials.manage` (define, list, revoke any, revoke_all;
`bee.credentials.security:credential_manage_policy`), `bee.credentials.issue` (issue for oneself;
`bee.credentials.security:credential_issue_policy`, only in the workspace the caller's host-issued
identity is bound to through `actor.meta.workspace_id`),
`bee.credentials.materialize` (check and materialize;
`bee.credentials.security:credential_materialize_policy`, attached to node-level placement service
and runner entries, which serve every workspace; an application that runs its
own placement holds `bee.credentials.security:credential_materialize_workspace_policy`, limited to
its bound workspace), and `bee.credentials.write_back` (runner-only return of
an admitted provider login file through the same materialization policy).

OpenCode declares `.config/opencode/towers.key` as an optional auxiliary file
under the host-admitted OpenCode `.key` rule. The broker projects that exact
requested file without interpreting its bytes or writing it back. Placement
rewrites a configuration reference only when this file is materialized; a
configuration naming a missing or undeclared dependency refuses before start.

## Machine login links

Bee selects `link_policy: owner_safe` only on `bee.env:machine_login_source`.
The existing broker availability/check and projection reads use that directory;
there is no separate absolute-path credential reader. On Unix, external symlink
chains have a 40-link limit and loop detection. The canonical target must be a
regular file. Its owner and every canonical parent's owner through filesystem
root must be the process UID or root, and every mode must satisfy `mode & 022 == 0`.
Sticky directories have no exemption. This uses the owner/mode rule from
[OpenSSH `misc.c` `safe_path`](https://github.com/openssh/openssh-portable/blob/master/misc.c).

Runtime refusals name the path and cause. Availability, projection checks and
materialization retain that reason; the Agent catalog shows it in the login-needed
state. A successful metadata probe checks presence only, without opening login
contents. Projection still reads only the provider's host-admitted files.
Writes, creates, renames and deletes retain root containment. Windows keeps the
contained behavior because equivalent ownership/ACL evidence is unavailable.

External-link support requires the runtime release containing
[wippyai/runtime#890](https://github.com/wippyai/runtime/pull/890). Bee's current
runtime pin remains unchanged: it safely ignores the new field and retains
containment, so external links remain unavailable until the runtime is upgraded.
The proof-only `BEE_RUNTIME=/path/to/local/tool make login-links-check` exercises
synthetic accepted and refused files through broker, locate and the Agent model.
