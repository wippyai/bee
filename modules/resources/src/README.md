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

| Slice | Responsibility |
|---|---|
| root `bee.resources` | Definition, `target_db`/`target_roots` requirements, linked references, contract `contract`, and stable `local` binding |
| `persist/` | Immutable resource schema migrations and `authority`, the SQL-owning association and grant authority opened through `bee.persist` |
| `binding/` | Existing stable operation entry sources for associate, grant, revoke, revoke-all, resolve, list, and capabilities |
| `registry/` | The linked database/root reference reader, including the narrow environment resolution used to digest admitted roots |

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
