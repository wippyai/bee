# bee.placement.docker

Docker placement implements the `bee.placement:placement` contract
(`bee.placement.docker.binding:binding`, `meta.placement_kind: docker`) on top of
the native placement's store, materialization, receipts and runner. A PTY
window and a streamed turn share that machinery. EOF-based input, including a
driver's empty batch stdin, reads a protected private-home file or `/dev/null`
so the container observes an actual EOF. `executor:terminal()` attaches the
container PTY to the application's granted surface.

| Namespace | Responsibility |
|---|---|
| `bee.placement.docker.binding` | The contract binding, one function per contract method, `prepare_environment`, and the `spec` and `methods` libraries |
| `bee.placement.docker.service` | `daemon` (Docker API through `curl` on the Unix socket `/var/run/docker.sock`), `execution`, `runner`, `window`, `image` and `image_owner` (on-demand service `image_owner_service`, including the sweep task), `environment`, `runtime_probe` |
| `bee.placement.docker.profiles` | The `coding` placement profile and its `coding_recipe` |
| `bee.placement.docker.env` | `environment_configuration` (`meta.type: bee.docker_environment`) |
| `bee.placement.docker.security` | Policies for Docker calls, the daemon socket, the image owner and the environment owner |

## Profiles

A `bee.placement_profile` selects either an immutable `image_ref` or a
host-owned `image_recipe_ref`, a non-root `user`, a named `network`, positive
`limits` (memory, cpu, pids) and `mounts` (resource, target, access). Drivers
prepare commands without naming executors. The private provider home mounts at
`/home/bee`, with only the resources admitted for the attempt.

Provider homes come from the credential broker. Declared `container_content`
replaces host config with a clean container config; `container_omit` drops
declared host hook and MCP settings before encoding. Other copied JSON or TOML
config is decoded and refused before child creation if it has commands,
includes, plugins, host paths or unresolved file or environment references.
Login bytes stay broker-owned and are never inspected by these checks.

For an explicit registry image, first launch fetches the admitted digest and
records `docker.image_fetching` and `docker.image_ready` evidence. A missing
local image ID is refused with a build instruction.

## Containers

One executor creates each container with `BEE_ATTEMPT_ID`. Reconciliation uses
the daemon inventory and inspection API to match that value, the projected
provider-home mount and the admitted image digest. Placement records the
immutable container ID once observed; later inspection, stop and removal act on
that exact ID. A missing post-dispatch container is uncertain and never invoked
again. Daemon exit evidence precedes removal; automatic removal is disabled so
a lost owner can still observe the outcome.

A failed create or start records `child.start_failed` with the original cause,
projected as `start_failure` in status and placement events, without an
invented exit code. Cancellation before runner claim records that no container
was dispatched. After dispatch, cleanup requires an observed container exit.
The runner follows the native startup timeline; `child.start_returned` records
the executor start result. The sweeper reconciles live attempts and stops
containers whose resource projections were revoked.

`capabilities` optionally accepts `placement_profile_ref` and `runtime_name`
and returns `image_readiness` (image and runtime artifact presence, container
platform, whether the recipe is buildable) and `network_readiness`, whose
`provisionable` field reports whether the host selects first-use provisioning.
An uncached, buildable recipe stays selectable and is built during launch.

## Coding profile and image owner

`bee.placement.docker.profiles:coding` selects `coding_recipe`
(`bee.runtime_recipe`, `schema_revision: bee.runtime-recipe@1`): a Node base pinned
by digest plus the Linux CLI artifacts of the Claude, Codex, agy, Grok, Muse and
OpenCode drivers, found through each driver's `executable_ref`. First use
measures each artifact's ELF platform and SHA-256, and copies only those into a
build context. Mixed or unsupported platforms are refused. A receipt under
`images/receipts` records the recipe digest, image ID, platform and progress;
build contexts are removed on completion or refusal.

The image owner process authenticates request senders against recorded requests
and verifies the current profile digest. It serializes builds and publishes the
derived executor and interactive route in its protected
`bee.placement.docker:runtime` overlay. `prepare` accepts an optional
`progress_recipient` for build output, excluded from the stored launch
identity. Owner exit or caller cancellation returns the cause with an unknown
outcome and no automatic retry; cancellation closes the build and removes its context.

## Environment provisioning

The `coding` profile names the network `bee-coding`. `environment_configuration`
selects that network, the gateway endpoint and listener
(`bee.gateway.api:gateway_endpoint`, `:gateway_listener`), a readiness policy
and an approval policy. Selecting the profile files one approval; after it is
approved the image owner creates the private bridge and moves the restricted
gateway listener onto its host address through supervisor stop, overlay update
and restart. The approval is consumed before provisioning, and a protected
receipt binds reuse to the selected profile and host configuration. Pending,
declined, expired and revoked admissions report distinct reasons without
launching. Docker preparation refuses host-loopback gateway addresses.

`bee.placement.docker.binding:prepare_environment` takes `placement_profile_ref`,
`workspace_id`, optional `progress_recipient` and optional `revoke`. Launch
admission invokes it before gateway projection. The profile editor's Ctrl+R
revokes the receipt and restores the host gateway configuration; it requires the
person-only `bee.placement.environment.revoke` grant. The sweeper stops admitted
containers when their environment is revoked.

Docker has one supervised owner, active for recorded image or environment
requests and eligible placement attempts. Requests for an absent owner start
it and receive an authenticated acceptance naming its PID. Build operations
remain serial; an independent guarded task reconciles attempts and enforces
revocation even while a build or environment approval waits. Active attempts
retain the existing supervision interval. Uncertain attempts and exited
attempts awaiting cleanup keep supervision active. Boot backlog recovery
starts the owner from durable attempts; monitored launch admission and runner
exit wake it. The owner stops after requests and supervision drain.

An authorized cleanup records a durable intent and demand-wakes this owner.
The sweep task performs container removal once, then records completion or
failure for waiting callers. Concurrent callers observe that same operation
through database changes; they do not run competing Docker removals. Cleanup
requested after a refused start is also eligible for supervised recovery.
