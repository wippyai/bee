# Application Threads client

`bee/application-threads` supplies the opt-in `bee.app.threads:client` library.
Applications select this package explicitly alongside `bee/application` and
import its client directly. Imports grant no application or thread authority.

`request(launch, operation, arguments)` queues a bounded request through the
launch's authenticated broker execution and returns `request_id, error?`.
Listen on `bee.app.thread.result` before sending. A successful send means queued.
`result(launch, sender, operation, payload)` returns a decoded reply only for the
bound broker, instance, execution generation and expected operation. Callers
also match the request ID before accepting a result.

Operations are `read`, `post`, `subscribe`, `page`, `ack_page`, `resume` and
`unsubscribe`. The broker supplies the durable thread and stable application
actor, authenticates execution and membership, and enforces host-selected
permissions. Applications cannot select another thread or actor in the request.
The decoder lives at `bee.app.threads.types:protocol`; request/reply schemas,
`bee.app.thread.*` topics, application principals and durable bindings retain
their existing identities. Consumers refresh through their supported process
lifecycle; publishing a library does not replace active closures.
