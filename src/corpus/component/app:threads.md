# bee.app.threads

The optional `bee.app.threads:client` library, the application-to-broker thread
facade. An application imports it alongside `bee.app:client`. Imports grant no
application or thread authority.

`request(launch, operation, arguments)` queues a bounded request on
`bee.app.thread.request` through the launch's authenticated broker execution and
returns `request_id, error?`. A successful send means queued.
`result(launch, sender, operation, payload)` returns a decoded reply only when
the sender is the launch's broker and the reply carries the launch's instance and
execution generation. Callers also match the request ID before accepting a
result.

Operations are `read`, `post`, `subscribe`, `page`, `ack_page`, `resume` and
`unsubscribe`. The broker supplies the durable thread and stable application
actor, authenticates execution and membership, and enforces host-selected
permissions. Applications cannot select another thread or actor in a request.
The request and reply schemas live in `bee.app.threads.types:protocol`.

`bee.app.threads.client:status_reader` maintains a bounded status projection
(`new`, `bind`, `unbind`, `update_intent`, `read_intent`, `watch_intent` with
matching `apply_*` calls, `value`) and fences stale generations.
`bee.app.threads.types:status_surface` decodes status snapshots for badge and
presenter values. Neither library grants thread access.
