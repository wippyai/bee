# bee.placement.docker

Docker placement ports the lineage PoC's container PTY transport and retained
provider homes onto Bee's placement contract. The runtime's current
`executor:terminal()` replaces the PoC's `child:attach_terminal()` and attaches
the container PTY to the application's granted virtual surface.

A `bee.placement_profile` selects an immutable image, non-root user, named
network, positive limits, resource targets and interactive executor route.
Drivers prepare commands without naming executors. Both PTY windows and streamed
turns share the native placement's materialization and receipt mechanism.
Private provider homes come from the existing credential broker. Declared
`container_content` replaces host config with a clean container config;
`container_omit` drops declared host hook/MCP settings before encoding. Other
copied JSON/TOML config is decoded and refused before child creation if it has
commands, includes, plugins, host paths or unresolved file/environment references.
Login bytes remain broker-owned and are never inspected by these config checks.
Codex uses its own auth.json with a clean config. OpenCode can receive the
host-admitted OPENAI_API_KEY by name with a clean config; its CLI selects the
provider. Private Grok/OpenCode turns publish their admitted config even without
gateway tools. Docker mounts
the private home at `/home/bee` and only the resources admitted for the attempt.

One unpatched runtime executor creates each container with `BEE_ATTEMPT_ID`.
Reconciliation uses the vendored `userspace.docker:docker_client` inventory and
inspection API to match that environment value, the projected provider-home
mount and the admitted image digest. Placement records the immutable container
ID immediately after observing it; later inspection, stop and removal act on
that exact ID. Missing post-dispatch containers are uncertain and never silently
invoked again. Daemon exit evidence precedes removal; automatic removal is
disabled so a lost owner can still observe the outcome.

The Agent application lives in `bee.harness.app`; its placement constructor
uses the existing terminal lifecycle and hook processing. The Docker sweeper
reconciles live attempts and enforces revoked resource projections.
Window close stops the recorded container through the Docker API. Terminal
finalization verifies daemon exit before removing that container and the private
attempt home. A close acceptance alone does not prove cleanup has completed.

`capabilities` optionally accepts `placement_profile_ref` and `runtime_name`
and returns `image_readiness`: image presence, runtime artifact presence and
container platform. This is a read-only observation. The Sessions catalog
passes a saved profile's placement selection through the host locator.

First launch fetches a missing registry image by its admitted digest, with
`docker.image_fetching` and `docker.image_ready` evidence. A missing local image
ID is refused with a build instruction. `make docker-runtime-image` builds a
digest-recorded image from explicit Linux CLI executable artifacts without
mounting login sources. Automatic local artifact discovery/build and live
per-layer download progress remain proposals.
The built-in `bee.placement.docker:coding` profile is not published; hosts must
admit an explicit image profile and its interactive executor route.

Validation covers real start/replay, foreign-owner denial, quoted stdin and EOF,
owner SIGKILL/restart, exact-ID cancellation and evidence-before-removal. Live
provider probes use `make docker-placement-live-check` with an explicit image,
provider, mode and evidence directory; the probe removes its containers/network.
Each provider result and remaining scheduler dependency belongs in the lane's
acceptance report.
