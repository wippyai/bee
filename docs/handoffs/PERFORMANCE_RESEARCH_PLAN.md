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

1. **One complete live experiment.** Select one small repository and repeatable
   benchmark. Prove Gemini launch, then the minimum host-admitted app-tool MCP
   path and documentation trait needed by the authoring Agent. Have the Agent
   author and freeze the dashboard/tool component, review/apply it through
   Governance, and run a baseline plus a candidate experiment through Gemini.
   Render recorded values in a real Bee dashboard. Keep benchmark identity,
   source revision, units, sample count and outcome with each measurement;
   report regressions honestly. Completion evidence must include the actual
   provider/tool exchange, approved artifact digest, persisted measurements
   and rendered UI. Fixture output alone does not complete this milestone.
2. **Recovery and boundaries.** Reconnect the dashboard and restart its
   coordinator. Prove retained experiment state, subscription continuation,
   duplicate-request handling and explicit uncertain outcomes. Prove a foreign
   actor cannot run or read the experiment, an unadmitted tool cannot execute,
   and Agent authoring cannot bypass review/apply. Include bounded execution
   and cancellation of the benchmark.
3. **One extension and delivery.** Add one independent consumer of the same
   typed thread records without changes to the research producer. Run affected
   source/pack and release gates, inspect packs for fixtures, build/install
   global Bee, verify the installed workflow and document exact user steps and
   remaining limits.

Work on one milestone at a time. Within milestone 1, finish the provider probe,
then tool admission, then authored application and the combined live proof;
do not open unrelated harness, Hub or mesh work. Use Luna High or Agy children
for bounded implementation/review while the primary agent owns integration.
Reuse managed launches, Governance, application lifecycle and thread delivery.
No research-specific scheduler, new mesh or general automation framework.

## Current evidence

- Goal attachment read; objective retained in full.
- Clean checkpoint and current guide/status/development conventions inspected.
- Existing autoresearch and Timeline contracts inspected.
- Gemini/Agy current implementation and POC inspection delegated, read-only.
- Milestone 1 remains in progress; no live-provider or dashboard claim yet.
