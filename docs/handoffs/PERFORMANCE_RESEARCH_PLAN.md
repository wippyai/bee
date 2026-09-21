# Performance research acceptance

## Objective

A user asks an Agent to optimize a selected repository using Gemini through
its normal harness. The Agent authors a Bee application with a live experiment
dashboard, scoped MCP benchmark tools and Bee documentation traits. Baseline
and subsequent measurements persist and appear in charts. Durable threads
coordinate the work and provide typed contracts for other applications.
Application changes follow stage → review → apply. Finish with a verified
global Bee installation and reproducible use instructions.

## Working checkpoint

Use `feat/global-persisted-hive-20260915`, starting at `e4365f7` (PR #11).
The shared `bee` checkout has unrelated uncommitted work; do not modify it.
The previous checkpoint proves scoped overlay MCP authoring, fixture launch
fan-out and durable subscriptions. It does not prove this application workflow.

Initial inspection: the MCP catalog in `src/gateway/mcp.lua` is a closed table
of four tools, and gateway admission accepts only those names. App-owned
benchmark tools therefore require an explicit host-admitted extension path.
Registry metadata alone must never grant function or execution authority.
Timeline provides an existing app/subscription pattern. The Agy driver and
external `bee-legacy/driver-agy` POC are references for Gemini execution; POC
code must not become a dependency.

## Milestones

1. **Configurable MCP, context and traits.** Implement the complete bounded
   tool path first, following the user's updated order. Host configuration
   admits component-owned function tools and multiple selectable traits.
   Trait activation selects instructions/tools within an Agent's admitted
   ceiling; it does not create permissions. Tool execution uses the bound
   subject and explicit native scopes. Native `ctx` supplies read-only context
   to callees via `funcs.Executor:with_context`; fixed host context cannot be
   overwritten by caller-selected values. Dynamic context keys are explicitly
   admitted. Preserve trait selection and context across credential rotation
   for the same binding, isolate bindings, and fence stale configuration.
   Prove real HTTP discovery, activation of two traits, context delivery,
   denied activation/invocation, revocation, and concurrent caller isolation.
   Keeper's MCP surface/traits/dispatch are source references only. Reuse its
   distinction between selectable traits, visible tools and actual permission.
2. **One complete live experiment.** Select one small repository and repeatable
   benchmark. Prove Gemini launch, then the minimum host-admitted app-tool MCP
   path and documentation trait needed by the authoring Agent. Have the Agent
   author and freeze the dashboard/tool component, review/apply it through
   Governance, and run a baseline plus a candidate experiment through Gemini.
   Render recorded values in a real Bee dashboard. Keep benchmark identity,
   source revision, units, sample count and outcome with each measurement;
   report regressions honestly. Completion evidence must include the actual
   provider/tool exchange, approved artifact digest, persisted measurements
   and rendered UI. Fixture output alone does not complete this milestone.
3. **Recovery and boundaries.** Reconnect the dashboard and restart its
   coordinator. Prove retained experiment state, subscription continuation,
   duplicate-request handling and explicit uncertain outcomes. Prove a foreign
   actor cannot run or read the experiment, an unadmitted tool cannot execute,
   and Agent authoring cannot bypass review/apply. Include bounded execution
   and cancellation of the benchmark.
4. **One extension and delivery.** Add one independent consumer of the same
   typed thread records without changes to the research producer. Run affected
   source/pack and release gates, inspect packs for fixtures, build/install
   global Bee, verify the installed workflow and document exact user steps and
   remaining limits.

Work on one milestone at a time. Within milestone 1, finish tool/context
validation, then bound state and dispatch, then the combined HTTP proof;
do not open unrelated harness, Hub or mesh work. Use Luna High or Agy children
for bounded implementation/review while the primary agent owns integration.
Reuse managed launches, Governance, application lifecycle and thread delivery.
No research-specific scheduler, new mesh or general automation framework.

Self-modification and installation use the existing approval inbox: request
approval for an exact measured change, wait for its recorded decision, and
reuse that receipt on retries. Changed content requires a new decision when
the user selects review on every change. Agents cannot decide their own
requests. Standing approval was suggested in conversation but is not assumed
implemented or required to bypass these checks; inspect the existing authority
before proposing any additional approval mode.

## Current evidence

- Goal attachment read; objective retained in full.
- Clean checkpoint and current guide/status/development conventions inspected.
- Existing autoresearch and Timeline contracts inspected.
- Gemini/Agy current implementation and POC inspection delegated, read-only.
- Milestone 1's bounded MCP acceptance is complete at `7070137`: 1011 Lua
  cases including native policy characterization, real HTTP and managed child
  proofs, typed lint and pack pass. The wider foundation/release checks continue;
  host-index fixture repairs are pushed at `3d34ad1`.
- The Agy caller-thread batch route now uses the existing structured profile,
  normal user HOME, Gemini Flash with explicit high effort, and retained MCP
  configuration. Its 54 focused driver/launch cases pass. A real managed Gemini
  run selected both configured traits and committed the exact requested thread
  message under its bound actor/action/attempt. No dashboard claim yet.

Implemented: `bee.gateway:catalog` strictly decodes bounded
tool/trait configuration and computes an active tool set within an independent
admission ceiling. `bee.gateway:context` validates and copies fixed/dynamic
context. Both are now connected to HTTP admission and dispatch; the carrier
passes protected launch-policy configuration into admission.
Binding-owned selection storage now has an append-only migration and a
transaction-local compare-and-set operation. Its immutable surface description
is separate from the active-trait/context values; callers must authorize and
decode these before opening the transaction. Storage tests exercise the real
migrations, reopen, stale revision refusal and independent bindings.
The real HTTP probe passes two-trait activation and component-tool dispatch,
native fixed/dynamic context delivery, host-key/foreign-trait refusal, stale
revision refusal, binding context isolation and revocation. `call_tool` gives
clients a stable route when their discovery cache predates trait activation.
The native scope separately denies the tool gateway-store and scope-creation
rights. Concurrent HTTP selections now prove one winner and one conflict at
the same expected revision. A read-only review found no additional verified
authorization or concurrency defect. Credential rotation rejects the old token
and preserves the selection, native context and tool dispatch for the new one.
The managed-carrier child proves configuration delivery, two-trait selection,
newly activated tool dispatch and fixed-context refusal through its actual
projected credentials. Native policy inspection found that registry definitions
and compiled security policies update through separate paths, so a Lua digest
comparison cannot safely pin them. The default keeps native policy-reference
semantics: governed host policy updates affect subsequent calls, while the
binding keeps its copied tool/trait/context configuration and admission ceiling.
A same-binding HTTP test proves the existing token observes a replacement
policy after native publication converges. Strict policy pinning would need
native compiled-policy identity if the user chooses that stronger behavior.
See [MCP configuration](../MCP_CONFIGURATION.md) for the implemented contract.

## Updated user requirements (September 15)

An Agent must request additional MCP tools and selected app-state access through
MCP itself. The existing durable approval inbox presents the exact agent, Bee,
application target and requested access to the user. Approval enables only that
Agent's access on subsequent calls, without relaunching it or changing other
Agents. Retrying a request reuses its recorded decision; denial, revocation,
restart and uncertain delivery must remain explicit. A shared native policy
replacement is not an agent-specific grant. The access-request backend now passes 1015 Lua tests and real HTTP checks,
including isolation, decision denial, idempotent consumption/application handoff
and fixed-context refusal. The live Gemini test requests access itself and writes
its verified result only after a test-operator approval through the durable inbox.
Normal profile setup, client-wide notifications and grant recovery into a
replacement binding remain product acceptance; do not infer them from this proof.

The client must eventually switch authorized Bees/workspaces/displays without
relaunching and present cumulative pending approvals across a Hive of roughly
100 Bees independently of the viewed workspace. Current inbox source enrollment
is explicit and limited to 16; automatic authorized discovery and bounded paging
across 100 owners are unverified work. Preserve per-owner decision authority,
show unavailable/stale sources, and do not infer an empty inbox from disconnects.
Keep this client-scale unit separate from the immediate per-agent request flow.

### Selected experiment and baseline — September 15

Use an isolated copy of this repository's
`src/threads/records/canonical.lua`, with benchmark identity `canonical-json@1`.
Keep production source untouched while Gemini authors the candidate. The
offline `make research-benchmark-check` prerequisite stages only a small fixture
and the exact source, validates it with the selected native runtime, and records
seven samples over four fixed representative values with a source SHA-256.
The artifact includes the correctness verdict and first mismatch; measurement
completion is not a claim that the measured implementation is valid.

The native baseline fails the exact-output corpus for integer `2^53`: its `%g`
formatting returns `%!g(lua.LInteger=09007199254740992)`. The same corpus passes
under plain Lua 5.4/LuaJIT, so native execution is required for candidate checks.
Keep this case. Gemini's candidate must pass the complete corpus before its
performance can be accepted. No production encoder or runtime change was made.

The fixture starts three deliberate CPU loops, observes their startup messages,
cancels their futures and completes a baseline call; its external runner enforces
a 15-second runtime deadline. This is a cancellation smoke test, not proof of
per-call memory limits or individual worker retirement before runtime shutdown.
The MCP benchmark boundary still needs end-to-end cancellation acceptance.

Next: expose the selected source, benchmark contract and Bee authoring docs through
host-admitted MCP tools/traits, then have Gemini author the candidate and dashboard
in its Governance overlay. Use the existing measured-artifact review/apply
flow. Do not substitute direct filesystem authoring or fixture-generated charts
for the requested live MCP workflow. Persist actual benchmark results through
the thread owner with trusted run attribution before rendering them.

## Measured artifact checkpoint — September 15

The reviewed Gemini artifact is retained outside production in
`tests/fixtures/research_artifacts/canonical-json-v1.json`, with its original
author digests and explicit host review changes. `make research-measurement-check`
now proves exact governed installation, real native HTTP MCP measurements,
same-record replay, trait/argument/revocation denial and source/producer/action
attribution. Measurements use the existing typed observation extension, source
`mcp` and the fixed host-admitted member `bee.research.measurement`. The ordinary
agent's deliberately fabricated one-nanosecond message remains a message.
The updated dashboard accepts observations only and versions its checkpoint.

The second-boot gate requires automatic restoration of the exact approved
artifact; its explicit recovery fallback is diagnostic and cannot pass the gate.
Evidence `/tmp/bee-research-delivery-1488229448` passes that gate. The baseline
is still invalid and the candidate is correct; no qualified speedup is claimed.
Normal desktop launch has not yet displayed the recovered app, so UI rendering,
real Gemini invocation of the measurement tool, UI recovery and independent
consumer acceptance remain next. Global Bee is unchanged.

### Governed dashboard acceptance — September 15

The measured artifact `dde4264479b2cd3d01472690d7f550183228f38c487d60f28e7611e0ec36e818`
passes native HTTP measurement, automatic approved-overlay recovery and physical
desktop acceptance. The ordinary menu discovers the recovered application; both
median values match its producer-authenticated observations, remain visible at
70×24, and return automatically after clean exit and restart. The baseline is
incorrect, so its timings do not establish a valid speedup. Core fixes compare
the effective catalog independently of history and keep saved automatic apps
pending until their admitted definitions become available. No runtime patch.
Evidence: `/tmp/bee-research-delivery-2296074133`,
`/tmp/bee-late-app-restore-check.log`. Real Gemini invocation of these measurement
tools, cancellation, the independent consumer and global installation remain.

### Managed Gemini measurement milestone — September 15

`make research-live-measurement-check` now passes in
`/tmp/bee-research-delivery-408383754`, log
`/tmp/bee-gemini-measurement-setup-fix.log`. Gemini Flash through the managed Agy
batch requested the measurement trait via MCP. The separate fixture operator
approved the exact requesting action/attempt through the durable approval inbox;
Gemini selected the trait and ran baseline and candidate. The fixture verified
both new fixed-producer MCP observations under that action and attempt. The
physical dashboard then displayed those newest measured medians and automatically
restored them after restart. The earlier Gemini authorship provenance remains in
the reviewed artifact. This completes the first live experiment milestone;
measurement cancellation, an independent consumer, the full release gates and
global installation remain. The baseline correctness failure still precludes a
qualified performance win.
