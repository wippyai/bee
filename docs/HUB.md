# Hub installation

Bee's Hub installer is in progress. The implemented first operation reads one
exact artifact and its declared requirements. Installation, dependency resolution,
confirmation, migrations and activation are not yet exposed by this component.

`bee.hub:inspect.read({component, version, parameters})` uses the native Hub
reader with the caller's existing permission for that module. `parameters` is
a list of qualified requirement names and bounded JSON values. Native scalar,
object and array values retain their types. Requests cannot select
another registry, token, actor, security scope or host path. The result carries
the actual version, a SHA-256 digest and requirement bindings. Missing values
are reported; declaring a requirement does not grant access to its value.

This reads package entries without publishing or starting them. The native Hub
reader may download an artifact to its verified cache. The result describes one
artifact, not the final dependency graph or an approved installation.

`make hub-inspect-check` runs an explicit live-Hub proof against public
`userspace/docker@0.5.12`, with fresh local state and no inherited credentials.
It requires a measured result, a permission denial for another package and
registry publication, and unchanged registry history. Ordinary unit checks cover
malformed requests, missing bindings and bounded declarations without Hub access.

The intended complete operation remains small: resolve the requested dependency
through the runtime, show exact changes and missing bindings, obtain confirmation,
then apply through the authorized owner and record migration results. Keeper's
Hub flow is a reference; Bee does not import Keeper or duplicate its Lua dependency
solver. Existing Bee preflight and approvals supply their respective checks.

On pinned runtime `291f5c6`, dependency resolution and expansion exist in native
boot code but have no read-only Lua preview operation. Registry changes expose
apply without the expected-base guarantee required by Bee's existing acceptance
probe. These native contracts must be established before the installer is enabled.
Catalog metadata and a Lua read immediately before apply do not supply them.

The intended storage split is durable registry history for Hub and system
installations, with authored component changes persisted in Bee's separate
database and reconstructed as overlays. Application start and sharing must obtain
user confirmation; sharing must preserve admission at the destination. These are
installation and activation requirements, not guarantees supplied by inspection.
