# Capability model

`bee.capability:catalog` is the host-owned review vocabulary: capability ids
(for example `workspace.files.read`) with revision, parameters, review text,
confirmation level, the policies and resources each grant renders to, and a
`never` list of capabilities no application may request. Declarations are not
grants.

The pure `bee.capability:model` library decodes the catalog (`decode`), normalizes
and resolves capability requests (`normalize`, `resolve`, `render`), compares
grant scopes (`scope_contains`, `contains`) and installed against proposed
declarations (`compare`), and builds revocation reports (`revocation_report`).
Gateway, Gov and their stores import it and keep their own grant records.

Catalog meanings do not grant authority. Each owner checks and records grants
under its host-selected permissions.
