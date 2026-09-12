# Hub module management

This optional Bee component uses the existing native Hub reader and registry
APIs. It has no Keeper dependency and requires no runtime changes.

The public `bee.hub:call` function accepts `{operation, request?, expected_digest?}`
and returns `{ok, value?, code?, message?, replayed}`. The host grants
`bee.hub.read` or `bee.hub.manage` for the requested component; the facade
validates and authorizes the operation before entering its fixed private scope.
Requests cannot select credentials, a registry URL, an actor or a host path.

Read operations are `catalog`, `details`, `inspect`, `state`, `files`, `read_file`
and `installed`. Catalog keyword defaults to `bee`; an empty keyword clears it.
`state` returns an exact uninstalled artifact's metadata, entries and resources.
`files` and `read_file` read its embedded resource filesystem. These operations
may populate the native verified cache but do not publish or start the package.
They expose packaged assets, not a reconstruction of its source repository.
See [the API and acceptance status](../../docs/HUB.md) for request examples.

Management operations are `plan`, `apply` and `status`. Planning preserves other
roots, resolves dependencies and measures the request, registry revision and
artifacts. Exact dependency pins do not list release history; ranges page lazily.
Apply replans in a private worker before publishing the dependency-root change
and an operation receipt to durable registry history. Status reads one receipt
by digest or pages through the caller's operation history with `{page = 1}`.
Modules opens that history with Operations (O); recovery reviews the stored
request and digest before a separate confirmation. The worker serializes Bee
Hub operations, not all registry writers.

Real install/update/uninstall, receipt persistence across restart and uninstalled
resource filesystem reads pass on the existing runtime. Modules confirmation,
input, F12 and resize have source/pack and executable acceptance. Publication
recovery verifies the original root and inventory. Migration `up` captures exact
definitions and verifies SQL ledger evidence across restart. Removal checks all
departing owners, including orphaned dependencies. Explicit `down` records its
work before reverting migrations, retains the root on partial failure, and
commits root removal with its receipt. Recovery checks the original definitions
and skips ledger work already committed. Database and function access require
exact host-selected grants. Targets must currently exist before installation;
newly installed database resources remain unfinished. SQLite acceptance covers
partial failure, retry and crashes before and after root removal.

Authored component overlays and application launch/sharing admission remain separate responsibilities.
