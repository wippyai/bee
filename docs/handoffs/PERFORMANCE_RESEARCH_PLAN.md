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
The previous checkpoint proves scoped workspace MCP authoring, fixture launch
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
- Milestone 1 remains in progress; no live-provider or dashboard claim yet.

Implementation in progress: `bee.gateway:catalog` strictly decodes bounded
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
