# bee.credentials

The owner-local credential broker. A definition names a credential in a
workspace from a source the host admits (`bee:credential_sources`: an
`env.variable` entry, the workspace or `*`, the audience or `*`, a provider,
the projection kinds allowed); its digest covers configuration and source
identity, never bytes, and redefining it moves to the next revision so
existing projections stop resolving. The allowlist is checked again at
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

Phase 1 projects environment values only: `ANTHROPIC_API_KEY` for Claude,
`OPENAI_API_KEY` for Codex. These are API-key paths, not subscription
logins. File projections, refresh, write-back and provider-side revocation
are unsupported and reported as such by `capabilities`. Revocation stops
future materialization; a live attempt is stopped by placement at its next
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
