# Bee sessions

`bee.sessions` owns the public session contracts, executor selection, readiness
location and work scheduling. Threads owns the durable session journal and
transactional work, claim, turn and result records; Sessions never writes its
tables. Executors are selected by the host and operate through the fenced
worker contract.

The shipped session and catalog contracts select the owner and catalog bindings
by default. The application SDK opens those contracts without choosing an
implementation; the bindings retain the host-selected admission policies.
