# Bee sessions

`bee.sessions` owns the public session contracts, executor selection, readiness
location and work scheduling. Threads owns the durable session journal and
transactional work, claim, turn and result records; Sessions never writes its
tables. Executors are selected by the host and operate through the fenced
worker contract.

A launch definition may select `session_profile_id` for structured executor
turns. Sessions admission pins that driver profile while native manual windows
retain the definition's window profile. Catalog readiness measures the same
structured route that `open` admits. The real owner and catalog bindings are
defaults; the kit starts the pull scheduler against the Threads journal.

Provider login checks use the home selected by each profile; file existence
is an observation and the provider owns authentication.

Session reads and list pagination include home-workspace sessions plus workspaces explicitly admitted by `bee.threads.workspace`. Cross-workspace mutations require separate exact host grants: `bee.sessions.workspace.send`, `bee.sessions.workspace.cancel`, and `bee.sessions.workspace.close`. Visibility alone grants no mutation authority. List filters accept workspace, definition, lifecycle and activity.
