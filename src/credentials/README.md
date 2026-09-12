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
fixed destination, the materializer identity, an expiry and the workspace
authorization epoch. `check` re-checks the bindings without bytes;
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

The broker projects API keys into `ANTHROPIC_API_KEY` (Claude) or
`OPENAI_API_KEY` (Codex), or reads an admitted login file. File sources name a
host-selected `fs.directory` using `source.kind: fs_directory`; their filenames
are fixed by provider: `auth.json` for Codex and `.credentials.json` for Claude.
Callers cannot choose a path, filename or mount. The host's `bee:credential_file_policy`
grants filesystem access separately from source metadata and is attached only
to materialization. Registry source metadata in `bee:credential_sources` alone cannot
grant filesystem read: if a source ref is admitted by metadata but absent from
`bee:credential_file_policy`, materialization fails closed (`UNAVAILABLE`). Adding
another source requires an explicit host policy grant naming the login root.

Ordinary callers (workspace managers, projection subjects, and outsiders) cannot
directly read login files or invoke `check` or `materialize`. The broker methods
accessible to ordinary callers (`define`, `issue_projection`, `list`, `revoke`,
`revoke_all`, `capabilities`) and error replies carry only identifiers, digests
and status views; they never echo secret bytes. Secret file contents are strictly
absent from persisted database state: definitions, projections, generations,
epochs, and the schema migration ledger (`bee_credential_schema_migrations`) never
hold secret bytes. Only the admitted placement materializer holding
`bee:credential_materialize_policy` receives bytes once per generation key in a
transient RPC reply that nothing persists.

File reads stop after 64 KiB plus one byte, reject empty, oversized or invalid
JSON, and return bytes only in the authorized transient materialization reply.
Definition IDs/revisions accompany file replies so placement can bind retained
login state to the selected source without hashing its contents. The broker
never searches or exports the OS keyring: when credentials exist only there,
a file projection is unavailable. Provider-specific JSON fields are opaque.

Database migration 2 (`file_sources`) introduces `fs_directory` source and `file`
projection kinds by rebuilding `bee_credential_definitions` with strict SQLite
CHECK constraints (`provider IN ('claude', 'codex')`, `source_kind IN ('env_variable', 'fs_directory')`,
`projection_kind IN ('environment', 'file')`), while preserving all existing populated
definitions, projections, consumed generations, and migration ledger records.

Test suites enforce these invariants using synthetic workspace-scoped fixtures
(`.wippy/*-fixture`) and never touch actual host credential files or OS keyrings.

File projection is a broker capability only. Native placement refuses a file
projection before recording a launch intent until private-home delivery is wired;
file contents cannot enter the environment projection route. Automatic source discovery,
copying into a private writable session home, preserving harness token refresh
and Docker mounting are still being integrated. No file login is enabled by
default. `refresh` and `write_back` remain false; the broker neither refreshes
provider tokens nor writes changes back to the user's login files.

Revocation stops future materialization; a live attempt is stopped by placement at its next
reconciliation, which the placement sweeper schedules on a fixed delay and
which is reported as pending until the exit is proven, with
`credential.revoked` evidence; an environment value already inside a running
child cannot be scrubbed.

| Slice | Responsibility |
|---|---|
| `bee.credentials` | `broker`: the seven operations and the store opened through `bee.persist`; `sources`: host allowlist, provider destinations, linked references; contract `contract` with binding `local` |

Actions: `bee.credentials.manage` (define, list, revoke any, revoke_all;
`bee:credential_manage_policy`), `bee.credentials.issue` (issue for oneself;
`bee:credential_issue_policy`), `bee.credentials.materialize` (check and
materialize; `bee:credential_materialize_policy`, attached to placement
service and runner entries only).
