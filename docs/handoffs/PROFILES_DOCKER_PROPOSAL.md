# Agent profiles, per-profile environment, Docker placement with the full UI (scheduling proposal)

Written 2026-09-10 for Astra's review after the user's direction the same day: "we should also be able to add agent profiles like additional kits or anything like that, maybe different environment variables as well; make sure that we can easily run that in Docker and so on, Docker with proper full UI", and "is there a way to set the system prompt or something like that for all the agents when you run them". Astra (round 64): carry it forward at full scope, separate the acceptance cases, keep nonsecret profile environment apart from broker-projected secrets, and never let container logs stand for the full UI.

## September 11 implementation direction

The extra `bee.agent_profile` composition proposed below is superseded. A named
`bee.launch_definition` already selects the binding, driver profile, launch
policy and presentation. It is the user-facing agent profile; a second entry
repeating those references would duplicate ownership. The selected host policy
continues to own environment, executable bindings, driver options and gateway
configuration. Credentials remain separate broker projections. Profile selection
will list eligible launch definitions through the existing Agent application.
This selection UI and its public CLI wiring are still unimplemented.

The first prerequisites are implemented on the isolated profile branch:
definition, catalog and policy resolve from one registry snapshot, and managed
launch admission rejects caller environment before any thread/resource/credential
effect. The lower carrier and placement remain general execution primitives.
All 567 unit tests and managed-window acceptance pass for these boundaries.

The native environment-ownership follow-up passes all 20 focused native tests:
placement owns HOME, gateway destinations cannot collide, and credential
projections cannot overwrite existing values. Removing the overwrite guard makes
exactly the credential-collision regression fail. A focused real-child test also
passes for two named definitions sharing one Claude batch profile: each child
receives its selected environment and broker credential, excludes the other
profile's variables, and retains a successful receipt and answer without secret
bytes in thread records or placement evidence. The combined suite is pending.

Still required: a selector must carry its measured plan into start and refuse an
intervening definition or policy change. The current admission snapshot covers a
single call; it does not yet fence a prior UI selection. Shared instructions need driver-specific measured rendering
and real-executable checks. Docker placement and its full interactive UI retain
the acceptance below. No `profile_ref` replacement schema or extra presentation
decoder is needed for the existing launch definition.

The original proposal below is retained as design history. Its instructions,
Docker and acceptance requirements remain planned; its additional profile schema
and duplicated references must not be implemented.

## What exists that this builds on

| Piece | Where | What it already gives |
|---|---|---|
| Harness bindings and profiles | `bee.harness.catalog` classifies `harness.driver` bindings and their `harness.profile` entries (driver id, protocol, modes, permission adapter) | The catalog of harness kits: Claude Code and Codex today, a kit is one binding plus its profiles and driver library |
| Launch definitions | `bee.launch_definition` entries (`launch_id`, `binding_ref`, `profile_id`, `policy_ref`, `default_mode`, `allowed_overrides`, `workdir_policy`, `thread_policy`, `credentials`, `presentation`) | What the Start menu and the CLI resolve to one measured plan |
| Launch policies | `bee.launch_policy` (`executables`, `environment`, `prepare_options`, `permission_exchange`, `provider_ref`, `gateway_tools`, `gateway_hooks`, `gateway_ttl_ms`, cleanup and timing) | The host's authority over how a launch runs: bound executable, nonsecret environment, driver options, gateway |
| Credential broker | `bee.credentials` projections into the child's environment, bytes never in records | The secret side of the environment |
| Native placement | `bee.placement.native`, private home per attempt, protected configuration files, measured executable | The attempt's home, configuration adapters, hook and MCP credentials |
| Docker contract | Hub module `userspace/docker` 0.5.12 (`userspace.docker:narrow`, interactive routes) and the agreed design in [Placement, resources and subscriptions](../PLACEMENT_AND_SUBSCRIPTIONS.md) | Hardened container per attempt, placement profiles, workspace launch document |
| Desktop | Session, viewport, terminal, taskbar, Timeline, Inbox, Hive Manager, thread windows | The full UI that has to operate Docker attempts unchanged |

## Proposal

Three units, each with its own acceptance, in this order.

### A. Agent profiles: kits and environments (host-owned registry data)

An agent profile is a host-owned registry entry `bee.agent_profile` that composes what exists rather than adding a new authority: `{schema_revision, profile_id, title, binding_ref, harness_profile_id, policy_ref, environment: {name: value}, system_prompt_ref?, presentation}`. Its environment is nonsecret and goes into the launch policy's environment map path (placement `environment`), never into the launch request and never through the broker; secrets stay broker projections named by the launch definition's `credentials`. A launch definition selects a profile (`profile_ref`) instead of naming binding, harness profile and policy separately; the Start menu and the CLI list profiles. Adding a kit means adding a `harness.driver` binding with its profiles and a driver library that implements `bee.driver:driver` (prepare, dispatch, normalize, configure); the catalog already classifies them, the carrier already runs whatever binding the definition names. The first additional kit is the one the user names; until then the acceptance uses the fixture driver.

System prompt: `system_prompt_ref` names a host-owned `bee.agent_instructions` entry whose text placement renders into the private home as a measured file. The Claude launch line gains `--append-system-prompt-file <home>/.bee/instructions.md` (append, never replace); the Codex provider configuration gains `model_instructions` with the same text (or `experimental_instructions_file`, whichever the pinned version honors; verified on the executables before the acceptance). The text is host data: it reaches the plan digest, never the launch request.

Acceptance A: two profiles of one kit with different environments run two attempts whose children see exactly their profile's variables and the broker-projected secret, with no variable of the other profile; a fixture kit added as a third binding runs under the same carrier and settles; the instructions file is in the home, measured, referenced from the launch line or the provider file, and its text appears in neither records nor evidence; a launch request naming environment or instructions is refused at placement intent.

### B. Docker attempt placement

`bee.placement.docker` implements `bee.placement:placement` on `userspace.docker:narrow` exactly as agreed: `bee.placement_profile` entries with the immutable image digest, non-root user, limits, tmpfs, network policy, resource and credential requests; admission produces the attempt-specific resolved specification; the driver runtime is in the image; the private home, the MCP and hook configurations, the credentials and the gateway credentials are materialized into the container by the same runner logic as native placement, with the gateway reached over a restricted interface the profile's network policy admits (no `host.docker.internal`, no host networking). One process per turn until an acknowledged bidirectional attach path exists. Creation intent recorded before dispatch, reconciliation by exact attempt labels, terminal evidence captured before removal.

Acceptance B: the same launch definition runs an attempt natively and in Docker with identical records, identical settlement and identical gateway behavior (MCP read, hooks, revocation); the container is proven hardened by the narrow contract (a broader configuration fails closed); the project resource is mounted from its resource reference, writable only when granted; a lost container is reconciled by labels; cleanup removes the home and keeps the terminal evidence; the workspace launch document from the placement design (`bee.workspace-launch@1`) is the only configuration the user writes.

### C. The full Bee UI operating Docker attempts

The desktop must operate a Docker attempt exactly as a native one: start from the Start menu, the thread window shows the turn, input reaches the child (batch: the brief; session: the next turn), resize reaches the viewport, F12 and a client restart reconnect to the same attempt, termination and cleanup show their true outcome, Timeline and Inbox show the same records and approvals. Container logs are evidence, never the UI.

Acceptance C: `tests/tui_smoke.py` style proofs against a Docker attempt: start, input, resize, reconnect after a client restart, explicit termination, cleanup, with the same screens as native; plus the desktop check on a host without Docker showing the concrete error rather than a reduced UI.

## Amendments (Astra round 67, accepted before unit A starts)

1. Profiles compose configuration; the launch policy remains the ceiling. A profile-backed managed launch takes no caller-selected environment: the launch request's environment must be empty. The launch policy declares `profile_environment` constraints (allowed names or patterns, bounds on count and value size) and every profile value must satisfy them; a name the policy's own `environment` also sets is a collision and is refused, never resolved by precedence.
2. One measured resolution. The launch definition, the agent profile, the harness binding and profile, the launch policy and the instructions entry are resolved from one registry snapshot; their entry measurements, the effective environment (names and digests) and the instructions digest are bound into the plan digest. The plan is revalidated before materialization and before start; recovery before start refuses changed inputs; a takeover of a running attempt keeps its recorded measurements.
3. The environment boundary. Variable count, names and value sizes are bounded. Reserved names and prefixes are refused for profiles: `PATH`, `HOME`, `USER`, `SHELL`, `TMPDIR`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, the gateway and credential destinations, loader and preload variables (`LD_*`, `DYLD_*`, `NODE_OPTIONS`, `PYTHON*`), runtime configuration variables (`XDG_*`, `BEE_*`, `ANTHROPIC_*`, `OPENAI_*`). A profile cannot override a policy, placement, adapter, gateway or broker-owned value. Records and evidence carry variable names and value digests, never values.
4. Instructions stay adapter-owned. The `bee.agent_instructions` entry has bounded text and a measured digest; the text never enters the launch request, records, evidence or diagnostics: placement reads the entry itself by reference, verifies the digest the plan recorded, and writes the file with protected creation at the driver adapter's exact destination in the private home. Claude Code's append behavior (`--append-system-prompt-file`) and Codex's model-instruction behavior are distinct semantics, each proven with the pinned executable.
5. Definitions and presentation stay host-controlled. A caller selects a launch definition; the definition selects `profile_ref`; registry discovery authorizes nothing. A profile a definition marks headless stays out of the desktop unless the definition's presentation admits it.
6. The third fixture kit proves the extension boundary only; a production kit needs its own measured executable, binding, profile and catalog checks, configuration adapter and real-driver acceptance.

Units B and C are separate review units after A.

## Order and dependencies

A first (it needs nothing new below it and it answers both of the user's questions), then B (build sequence step 11, needs `userspace/docker` pinned as a dependency and a digest-pinned image with the Claude Code and Codex runtimes), then C (needs B). Docker windows, ACP and RPC stay at step 15. The hook and gateway work carries over unchanged: a container child reaches `/mcp` and `/hook` on the restricted interface with the same credentials.
