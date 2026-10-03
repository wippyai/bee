# Client component

`bee/client` owns the desktop attachment actor and local commands in
`bee.client.service`, desktop catalog operations, retained desktop attachments
and asynchronous owner readers in `bee.client.binding`, qualified layout and
handoff values in `bee.client.types`, and SQL repositories and immutable
migrations in `bee.client.persist` and `bee.client.migrations`.

The host selects the component through `bee.deps:client`, supplies its private
boundary imports, command host, actor and policies, and catalog policies. The
host retains client lifetime, application admission, attachment grants, physical
display ownership and the existing `bee.env:client_db` resource. Metadata and
layout values grant no authority. The catalog checks the caller's read or
allocation permission before opening its selected database.
The client storage policy grants registry reads of that same database descriptor
for SQL resource validation, alongside database access.

The client uses the common `bee.persist.persist:ledger` runner with the existing
legacy ledger shape. Migrations 1–3 and their checksums, `client_state`,
`client_desktops`, `client_layouts`, desktop/workspace/view/instance identities,
qualified layout versions, topics and version-one handoff checkpoints remain
unchanged. No row rewrite accompanies this extraction. A composition restart
selects the moved actor definitions and reissues host grants; live PIDs and
viewport handles are never migrated. Subsequent actor changes use the existing
acknowledged supervised replacement and committed-layout fallback.
