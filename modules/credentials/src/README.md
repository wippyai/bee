# bee.credentials

The owner-local credential broker. A definition names a credential in a
workspace from a source the host admits (`bee:credential_sources`: an
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
authorization epoch. `check` re-checks the bindings without bytes;
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

The host's `data.formats` map selects reviewed component-owned registry entries
whose data declares an environment destination or a relative login layout.
Claude and Codex declare their API-key destinations and JSON login files;
Agy declares an opaque file. File sources name a host-selected `fs.directory`
using `source.kind: fs_directory`. The host source row selects the source path;
when omitted, it uses the declared login basename.
Callers cannot choose a path, filename or mount. A file source may also carry one
host-selected setup declaration: `setup_path`, an optional retained
`setup_destination`, and `setup_content_format` (`json` or `opaque`).
Materialization reads that optional path from the same source. JSON setup is
bounded to 4 KiB; opaque setup is bounded to 64 KiB. It appends the bytes to the
transient returned format as an initializer that may be installed even when an
optional login is absent. The setup declaration and its contents are never
stored in a definition or projection, and a missing setup file is allowed. The host's `bee.security.credentials:credential_file_policy`
grants filesystem access separately from source metadata and is attached to
availability for a stat-only check and to materialization for bounded reads.
Registry source metadata in `bee:credential_sources` alone cannot grant filesystem
read: if a source ref is admitted by metadata but absent from
`bee.security.credentials:credential_file_policy`, availability and materialization fail closed
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
`bee.security.credentials:credential_materialize_policy` receives bytes once per generation key in a
transient RPC reply that nothing persists.

Login file reads stop after 64 KiB plus one byte; supplemental JSON and opaque
setup reads stop after 4 KiB and 64 KiB plus one byte respectively. Both reject
empty or oversized content.
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

The host links the exact placement binding persisted on new projection receipts;
an unlinked materializer fails projection issuance closed, and caller or artifact
input cannot select it. Existing projection rows retain their recorded binding.

Native placement accepts file projections only with a selected retained session
home. It seeds the frozen declared destination and preserves provider-refreshed
bytes when the recorded definition identity matches; changed identity or a
partial seed refuses reuse. See [native placement](../../placement-native/src/README.md)
for the delivery and filesystem guarantees. File contents never enter the
environment projection route.

First-use harness setup can create definition-declared credential names from
host-selected source configuration, without reading the secret. Default Claude,
Codex, Agy and Grok window definitions select optional machine-login files under the
host's existing home directory. An absent provider directory/file permits normal
CLI sign-in in the private retained home; host credential directories are never
created. Agy may import its onboarding JSON, and Grok may import only
`.grok/config.toml` into retained `.grok/.bee-global-config.toml`. Placement
structurally inserts Bee's scoped MCP subtree into the private
`.grok/config.toml`; it never writes the machine or project trees. The host allowlist owns the relative source path; callers cannot supply
it. Source metadata and path are bound in the definition digest and rechecked
before availability or projection use. A changed source requires explicit
redefinition. Existing definitions with an older digest are refused rather than
silently retargeted. Source-free executable acceptance proves Claude/Codex/Agy/Grok present and absent
login with disposable host homes and fixture CLIs. Real authenticated provider
turns remain unverified.
Docker delivery is unimplemented. Broker `refresh` and
`write_back` remain false: it neither refreshes provider tokens nor copies
session changes back to the user's original login files.

Revocation stops future materialization; a live attempt is stopped by placement at its next
reconciliation, which the placement sweeper schedules on a fixed delay and
which is reported as pending until the exit is proven, with
`credential.revoked` evidence; an environment value already inside a running
child cannot be scrubbed.

| Slice | Responsibility |
|---|---|
| `bee.credentials` | `persist/broker`: the seven operations and the store opened through `bee.persist`; `registry/sources`: host allowlist, provider destinations, linked references; contract `contract` with binding `local` |

Actions: `bee.credentials.manage` (define, list, revoke any, revoke_all;
`bee.security.credentials:credential_manage_policy`), `bee.credentials.issue` (issue for oneself;
`bee.security.credentials:credential_issue_policy`, only in the workspace the caller's host-issued
identity is bound to through `actor.meta.workspace_id`),
`bee.credentials.materialize` (check and materialize;
`bee.security.credentials:credential_materialize_policy`, attached to node-level placement service
and runner entries, which serve every workspace; an application that runs its
own placement holds `bee.security.credentials:credential_materialize_workspace_policy`, limited to
its bound workspace).
