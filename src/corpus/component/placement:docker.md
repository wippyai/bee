# bee.placement.docker

Docker placement ports the lineage PoC's container PTY transport and retained
provider homes onto Bee's placement contract. EOF-based input, including
OpenCode's empty batch stdin, uses a protected private-home file or `/dev/null`
for empty input so the container observes an actual EOF. The runtime's current
`executor:terminal()` replaces the PoC's `child:attach_terminal()` and attaches
the container PTY to the application's granted virtual surface.

A `bee.placement_profile` selects either an immutable `image_ref` or a host-owned
`image_recipe_ref`, a non-root user, named network, positive limits and resource
targets. Explicit images select an interactive route; recipes produce it through
the image owner.
Drivers prepare commands without naming executors. Both PTY windows and streamed
turns share the native placement's materialization and receipt mechanism.
Private provider homes come from the existing credential broker. Declared
`container_content` replaces host config with a clean container config;
`container_omit` drops declared host hook/MCP settings before encoding. Other
copied JSON/TOML config is decoded and refused before child creation if it has
commands, includes, plugins, host paths or unresolved file/environment references.
Login bytes remain broker-owned and are never inspected by these config checks.
Claude and Codex use their own login files with clean container settings. OpenCode can receive the
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

The built-in `bee.placement.docker:coding` profile appears in the Agent placement
form and selects `coding_recipe`. First use discovers the installed Linux CLI
artifacts from host-selected executable references, measures their ELF platform
and SHA-256 digests, and copies only those code artifacts into a build context.
The recipe pins its Node base by digest. Mixed or unsupported artifact platforms
are refused. Docker build output and per-artifact steps appear on the Agent
surface. A bounded receipt under placement's `images/receipts` records the recipe
digest, observed image ID, platform and progress. Temporary build contexts are
removed on completion or build refusal; image layers remain a host-owned cache.

The lifecycle-owned image process authenticates request senders against recorded
requests and verifies the current host profile digest. It serializes builds and
publishes only the derived executor and interactive route in its protected
`bee.placement.docker:runtime` overlay. Applications receive no publication
permission. Cached tags must match the recipe, artifact labels and platform;
placement freezes the actual immutable image ID into each attempt. Docker
`prepare` accepts an optional bounded `progress_recipient` for display output,
excluded from the stored launch identity. Image-owner loss or reply timeout
returns an unknown outcome, with no automatic retry. Owner cancellation closes
the active build process and removes its context.

The coding profile names `bee-coding`; the host must admit that network and bind
the gateway to a restricted interface reachable from it. Network readiness is
reported before launch, and preparation refuses host-loopback gateway addresses.
Automatic network/gateway provisioning remains a proposal. The default native
loopback gateway does not make this Docker profile ready by itself.

For explicit registry images, first launch fetches the admitted digest with
`docker.image_fetching` and `docker.image_ready` evidence. A missing local image
ID is refused with a build instruction. `make docker-runtime-image` also builds
from explicit Linux CLI artifacts without mounting login sources.

Validation covers real start/replay, foreign-owner denial, quoted stdin and EOF,
owner SIGKILL/restart, exact-ID cancellation and evidence-before-removal. Live
provider probes use `make docker-placement-live-check` with an explicit image,
provider, mode and evidence directory; the probe removes its containers/network.
Each provider result and remaining scheduler dependency belongs in the lane's
acceptance report.
