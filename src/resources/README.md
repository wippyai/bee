# bee.resources

The owner-local resource authority. An association binds a workspace name
to an `fs.directory` root the host admits, with a subpath and the widest
access the workspace allows; replacing it moves the association to the next
revision. `associate` accepts an optional `expected_revision`; zero is an
atomic create-if-absent check, and a nonzero value fences a replacement.
A grant binds the authenticated subject, an audience (the
placement owner), the exact association revision and root digest, a subpath,
an access mode, a purpose, an optional attempt scope, an expiry and the
workspace's authorization epoch. `resolve` re-checks all of it for a
placement that admitted the subject and audience itself, and refuses with
`REVOKED`, `EXPIRED`, `DENIED`, `CONFLICT` (association replaced or root
changed: re-admission, never silent retargeting) or `RESOURCE_NOT_LOCAL`
(another node owns the resource; nothing is copied).

| Slice | Responsibility |
|---|---|
| `bee.resources` | `authority`: the six operations and the store opened through `bee.persist`; `resources`: linked references (store, host roots) with env-backed roots resolved before identity hashing; contract `contract` with binding `local` |

Actions: `bee.resources.manage` (associate, list, revoke any, revoke_all;
host policy `bee:resource_manage_policy`), `bee.resources.grant` (take a
grant as oneself; `bee:resource_grant_policy`), `bee.resources.resolve`
(placement services only; `bee:resource_resolve_policy` is attached to the
placement service entries). Resource root path interpolation uses the narrow
`bee:resource_environment_policy` and resolves before the root digest is
stored or checked; unrelated environment variables remain inaccessible.
Revocation stops future authorization; an
attempt already holding a materialized resource is fenced by the placement
at its next reconciliation, which the placement reports as pending
enforcement until then.

## Acceptance

The Lua suite `tests/lua/resources` proves the association ceiling, subpath containment at association time, grant binding to subject, audience and attempt, every resolve refusal, `RESOURCE_NOT_LOCAL` and the authorization epoch. `tests/resources.py` proves the runtime-level guarantees: the `fs.directory` provider contains a symlink escape, a symlink directory and a parent traversal at open time, and an association, grant and credential definition survive a restart with no secret in any exported listing. It runs the shipped runtime with `run` (no `wippy lint`), so it is not blocked by the supervisor lane's pinned lint failure; `make check` still gates it behind that lint.
