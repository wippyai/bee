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
and an operation receipt to durable registry history. The worker serializes Bee
Hub operations, not all registry writers.

Real install/update/uninstall and receipt persistence across restart have passed
on the existing runtime. Migration execution, interrupted-operation recovery,
resource filesystem acceptance and full Modules confirmation/apply UI acceptance
remain incomplete. Basic Modules input, F12 and resize pass from source and pack.
This source is not yet the globally installed release. Authored component
overlays and application launch/sharing admission remain separate responsibilities.
