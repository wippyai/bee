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

Docker execution requires upstream runtime support for `exec.docker`
`labels_from_env`. This label ownership and reconciliation work depends on
[runtime#894](https://github.com/wippyai/runtime/pull/894), which is open and
unmerged. The current runtime pin lacks that support; this source
change remains dependent on the upstream runtime fix and its integration gates.
The executor mapping selects Bee's host-supplied node, state and attempt values
at creation. Placement uses the existing node identity and a SHA-256 digest of
the canonical placement root, without adding an identity store.

Reconciliation uses the vendored `userspace.docker:docker_client` inventory and
inspection API with exact `bee.owner`, `bee.node_id`, `bee.state_id` and
`bee.attempt_id` labels. It rechecks labels, the attempt environment, the projected
provider-home mount and the admitted image digest before recording an immutable
container ID. Inspection, stop and removal use that ID. Missing post-dispatch
containers remain uncertain and are never silently invoked again. Labels scope
ownership; host admission still authorizes each operation.

A failed create or start records `child.start_failed` with the original runtime
error, including its operation, deadline or daemon cause. Public attempts expose
that evidence as `start_failure`; placement events carry it and Sessions reports
a failed launch with the same cause. `exited` requires an observed container exit. Existing false runner exits
without an exit result are projected as uncertain when start-failure evidence
exists; stored rows and schemas remain unchanged.

Failed and cancelled starts remove only exactly label-owned Created containers
and confirm their absence before removing attempt scratch. A container that ran
requires stop and exit observation first. The sweeper checks node/state-owned
Created containers after owner loss and restart, including containers that appear
after an earlier cleanup observation. Recovery errors are logged. Legacy
unlabelled containers cannot be selected or removed by this ownership mechanism.
Automatic removal is disabled for attempts so a lost owner can observe outcomes.

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

The built-in `bee.placement.docker.profiles:coding` profile appears in the Agent placement
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

The coding profile names `bee-coding`. The host's `environment_provisioning`
requirement selects that network, the existing gateway endpoint/listener and
readiness policy, and a person approval policy. `image_owner_policies`
selects the owner's grants. Its module default grants image preparation; the host
adds approval, gateway overlay and supervisor lifecycle authority. Selecting the profile opens one
recorded approval in Needs you before provisioning. Approval authorizes the
existing image owner to create an owned private bridge and move the existing
restricted gateway listener onto its host address through supervisor stop,
overlay update and restart. No additional listener or runtime owner is created.
The approval is consumed before provisioning; a protected environment receipt
binds reuse to the selected profile and host configuration. Pending, declined,
expired and revoked admissions report distinct reasons without launching.

`bee.placement.docker.binding:prepare_environment` takes
`placement_profile_ref`, `workspace_id`, optional `progress_recipient` and
optional `revoke`. The existing host admission invokes it before gateway
projection. Sessions runs Docker turns through the same external executor and
scheduler as native turns; restricted MCP can open/send Docker child Sessions,
and both transcripts belong to Threads. The Agent conversation shows launch
progress and directs the person to the approval inbox. The profile editor's
Ctrl+R, followed by Enter, revokes the receipt and restores the host gateway
configuration; Escape cancels. Revocation requires the host's person-only
`bee.placement.environment.revoke` grant. The sweeper stops admitted containers
when their environment is revoked. The owned network remains a host cache.

`capabilities.network_readiness.provisionable` reports whether the host selects
this first-use admission path. Existing manually admitted reachable networks
remain usable. Docker preparation refuses host-loopback gateway addresses.

For explicit registry images, first launch fetches the admitted digest with
`docker.image_fetching` and `docker.image_ready` evidence. A missing local image
ID is refused with a build instruction. `make docker-runtime-image` also builds
from explicit Linux CLI artifacts without mounting login sources.

Daemon-free boundary tests cover create deadlines and daemon errors, exact failed
start status/events, cancellation, observed exits, foreign and unlabelled
container exclusion, and late Created recovery. Live proof diagnostics and
cleanup use the same ownership labels and recorded attempt IDs.
The real suites cover start/replay, foreign-owner denial, quoted stdin and EOF,
owner SIGKILL/restart, exact-ID cancellation and evidence-before-removal. Live
provider probes use `make docker-placement-live-check` with an explicit image,
provider, mode and evidence directory; the probe removes its containers/network.
Scheduler and child probes audit retained Sessions, successful Work results,
both Threads transcripts, immutable container identities and completed cleanup.
`tests/docker_environment_live.py --evidence PATH` exercises the native desktop
first-use approval. Each provider result belongs in the lane's acceptance report.
