# Desktop component

`bee/desktop` owns the pure scene model, layout and reducer (`bee.desktop`),
bounded commands, projection decoding, status associations and version-one
handoff values (`bee.desktop.types`), and the committed projection actor and
asynchronous status readers (`bee.desktop.service`). It is distinct from the
managed-work owner `bee.sessions`.

The host selects this package through `bee.deps:desktop`, supplies its application
protocol and exact session policies, and retains application admission, client
lifetime, physical display ownership and resource selection. The session accepts
commands and status bindings only from its authenticated attachment owner.
Metadata and decoded associations confer no authority.

The component has no store or migrations. Desktop/workspace/view/instance IDs,
qualified client layouts, desktop topics and version-one handoff checkpoints
remain unchanged. The projection actor is `bee.desktop.service:main`; its old
implementation ID is not stored in owner tables or client layouts. A composition
restart selects the moved actor and reissues grants. Subsequent code changes use
the existing same-PID session handoff, with client replacement on incompatible
checkpoints; moving the namespace does not migrate a live PID.
