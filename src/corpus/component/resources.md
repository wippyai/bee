# bee.resources

The owner-local resource authority. An association binds a workspace name
to an `fs.directory` root the host admits, with a subpath and the widest
access the workspace allows; replacing it moves the association to the next
revision. `associate` accepts an optional `expected_revision`; zero is an
atomic create-if-absent check, and a nonzero value fences a replacement. An
exact replay keeps the association identity and revision. A manager may replay
the same logical association after its admitted root definition changes; the
new root digest advances the association once and invalidates earlier grants.
A grant binds the authenticated subject, an audience (the
placement owner), the exact association revision and root digest, a subpath,
an access mode, a purpose, an optional attempt scope, an expiry and the
workspace's authorization epoch. `resolve` re-checks all of it for a
placement that admitted the subject and audience itself, and refuses with
`REVOKED`, `EXPIRED`, `DENIED`, `CONFLICT` (association replaced or root
changed: re-admission, never silent retargeting) or `RESOURCE_NOT_LOCAL`
(another node owns the resource; nothing is copied).

| Namespace | Responsibility |
|---|---|
| `bee.resources` | The contract `contract` |
| `bee.resources.binding` | One function per contract method (associate, grant, check_grant, revoke, revoke_all, resolve, renew_attempt, list, capabilities, describe, search) and the `local` contract binding |
| `bee.resources.persist` | `authority`, the SQL-owning association and grant authority over `bee:db` |
| `bee.resources.env` | `resource_roots`, the `bee.resource_roots` entry listing the admitted roots (`root_ref`, `access`), `roots_ref` and the `resources` reader that resolves path variables to digest admitted roots |
| `bee.resources.security` | The policies below |
| `bee.resources.migrations` | Immutable schema and lease migrations |

Actions: `bee.resources.manage` (associate, list, revoke any, revoke_all;
host policy `bee.resources.security:resource_manage_policy`), `bee.resources.grant` (take a
grant as oneself, only in the workspace the caller's host-issued identity is
bound to through `actor.meta.workspace_id`; `bee.resources.security:resource_grant_policy`), `bee.resources.resolve`
(placement services and scoped Gateway dispatch; `bee.resources.security:resource_resolve_policy` is attached to
those host entries). `grant` accepts an optional normalized `subpath` within the association's admitted path;
it can narrow that path and is included in the idempotency digest. `bee.resources.grant_thread`
(`resource_grant_thread_policy`) lets an admitted caller write a thread-bound grant for a thread actor.
`describe` (a workspace's associations as `{title, items [{label, detail}], total}`, at most 50) and
`search` (associations whose name starts with `text`) answer callers holding
`bee.node.workspace.read` on the workspace. Resource root path interpolation uses the narrow
`bee.resources.security:resource_environment_policy` and resolves before the root digest is
stored or checked; unrelated environment variables remain inaccessible.
The private `check_grant` binding validates an association, its admitted root
and the requested access without writing a grant. Gateway elevation calls it
before filing approval and again before consuming an approved decision.
Revocation stops future resolution. Both `revoke` and `revoke_all` report their
fenced attempts and ask the placement owner to recheck recorded grants and stop
each attempt that lost access. Placement reconciliation remains the enforcement
backstop until exit is proven.
