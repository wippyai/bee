# Proposal: shared agent definitions and Bee execution

This document is a **proposal**, not a callable Bee contract. It describes how
applications, the Wippy agent framework, Kickside components, Bee managed
harnesses and native Dataflow can share one agent definition vocabulary. The
source survey below records current behavior; every other section proposes
future behavior.

Source citations use paths from the Bee repository root. `../framework` and
`../dataflow` are sibling Wippy repositories; `../../kickside/main` is the
Kickside reference tree. Line numbers refer to the surveyed source trees.
The sections "Implemented: framework closure and CLI admission",
"Implemented: workspace agent selection", and "Implemented: agent run as a
function and cancellation contract" describe the implemented Bee contract in
present tense; every other non-survey section remains a proposal.

## Implemented: framework closure and CLI admission

A launch definition carries an optional `agent_ref` naming one `agent.gen1`
registry entry; the definition never copies the agent body
(`modules/harness/src/launch/definition.lua`).
`bee.harness.launch:agent_resolver`
(`modules/harness/src/launch/agent_resolver.lua`) resolves that reference
from the same pinned registry snapshot as the driver binding and launch
policy into a hashed launch spec closure: the agent digest, each trait
digest with its full prompt, member function tools, context and required
behavior, contract, wrapper, hook, option and delegate semantics, each
function tool digest with its `llm_alias`, description and input/output
schemas, delegate digests, the composed prompt and context, the agent model
and the tuning hints with the owner-permitted declinable set. A missing
entry is refused (`NOT_FOUND`); an unknown agent, trait or tool field is
refused (`INVALID`).

A CLI harness route (Claude, Codex, agy, Grok or Muse) admits the closure
only through the route check in launch admission
(`modules/harness/src/launch/admission.lua`). The route honors the exact
agent identity, the composed prompt and context, the selected trait and tool
schemas, the admitted delegates and the host-approved model mapping from the
launch policy's `agent_model_map`
(`modules/harness/src/carrier/policy.lua`). A tuning hint passes only as a
declined entry when the agent owner lists it as declinable; required memory,
trait behavior, contracts, wrappers, hooks or options are refused
(`UNSUPPORTED_CAPABILITY`), so a trait is never reduced to its prompt.
Delegates outside the policy's `agent_delegates` are refused (`FORBIDDEN`).
Codex takes no model input, so an agent that names a model is refused on a
Codex route. The plan pins the closure digest, the exact gateway tool
aliases, the mapped model and the declined hints; a changed agent, trait,
tool, delegate or contract reference returns `CONFLICT` before any grant or
credential projection. The closure's composed text travels through the
profile instruction channel, so an agent route needs `profile_instructions`;
`bee.harness.profiles:agent_preferences`
(`modules/harness/src/profiles/protocol.lua`) narrows a saved profile inside
the closure and refuses tools outside it or an option claiming `model`
(`FORBIDDEN`).

`bee.gateway:catalog.from_framework`
(`modules/gateway/src/catalog.lua`) projects the closure's selected function
tools and traits into gateway declarations: each function id becomes one MCP
tool under its `llm_alias` adapter alias with its input schema, and each
trait keeps its prompt with those aliases. The alias carries no authority;
the host supplies one policy list per function id, and selection still
refuses any tool outside the admitted ceiling. The function still executes
under a host-selected scope.

## Implemented: workspace agent selection

A workspace stores the selected framework agent reference (`agent_ref`), the
owner-issued component revision (`owner_component_revision`) and the computed
spec digest (`spec_digest`) in workspace-keyed state (`bee:saved_profiles`).
Selection, validation and saving execute under the caller's workspace authority;
access across workspaces is refused without explicit cross-workspace authority
(`DENIED`, `CROSS_WORKSPACE_FORBIDDEN`).

`bee.harness.profiles:protocol` (`modules/harness/src/profiles/protocol.lua`)
resolves the referenced agent through `bee.harness.launch:agent_resolver` from
a single pinned registry snapshot, computing the 64-hex SHA-256 digest of the
canonical spec and its trait, tool, delegate and contract closure. Saving a
profile records that `spec_digest` alongside the owner component revision.
Admission re-verifies the component revision and spec digest before granting
any resources or projecting credentials; a concurrent edit or mismatched
revision returns `CONFLICT`, requiring replanning. Both the saved profile
revision and the owner component revision are pinned in the attempt plan and
returned in durable attempt identities. The wire decoder `agent_protocol.decode`
(`modules/application/src/agent_protocol.lua`) and `agent_launch.decode_launch`
validate these optional fields at the typed boundary.

## Implemented: agent run as a function and cancellation contract

A managed agent can be executed as an ordinary function through the
application facade `bee.harness.launch:agent_call`
(`modules/harness/src/launch/agent_call_method.lua`,
`modules/harness/src/launch/agent_call_backend.lua`) and the Lua application
library `agents` (`modules/application/src/agents.lua`).

1. **Prompt durable receipts:** `operation = "run"` (`agents.run`) starts an
   admitted child and returns a durable receipt promptly:
   `scope = "attempt"`, `thread_id`, `action_id`, `attempt_id`, `state`,
   `status`, `idempotency_key`, and the nested attempt `receipt`. An idempotent
   replay with the same key returns the identical attempt receipt.
2. **Lifecycle operations:** Standard `status`, `wait` and `cancel` operations
   accept the attempt and thread identifiers. `wait` observes thread records
   up to a bounded `wait_ms`.
3. **Idempotent cancellation and carrier settlement:** `operation = "cancel"`
   (`agents.cancel`) records an idempotent Bee cancel intent.
   - An attempt cancelled before start (admitted without a running carrier) is
     settled directly as cancelled with `state = "ended"` and `outcome = "cancelled"`.
   - When `wait_ms` is provided, cancellation requests placement stop and
     waits up to `wait_ms` for the terminal carrier record before reporting
     settlement.
   - When called without `wait_ms` on a child that has not started yet,
     cancellation returns typed `NOT_STARTED` to allow retry loops until running.
4. **Dataflow `func` node contract:** A durable Dataflow `func` node invokes
   `operation = "run"`, checkpoints the durable receipt and deterministic
   idempotency key before bounded waits, observes terminal status via `wait`,
   and triggers cancellation with an idempotent intent that awaits terminal
   carrier records. Recovery reconciles an uncertain stop under the attempt's
   fenced epoch without requiring an agent-specific node type.

## Current state informing the proposal

| Area | Verified current state and design consequence |
|---|---|
| Wippy agent | `agent.gen1` entries carry prompt, traits, tools, delegates, memory, context, model hints and options. Use this as the agent definition, rather than making a second Bee agent schema. (`../framework/src/agent/src/discovery/registry.lua:3-26`, `../framework/src/agent/src/discovery/registry.lua:59-60`, `../framework/src/agent/src/discovery/registry.lua:82-102`) |
| Wippy traits | `agent.trait` has prompt, tools, build/prompt/step functions, behavior and contract bindings, wrappers, options and context. The compiler gathers prompt/tool contributions, delegates and function hooks. (`../framework/src/agent/src/discovery/traits.lua:30-68`, `../framework/src/agent/src/discovery/traits.lua:86-87`, `../framework/src/agent/src/compiler/compiler.lua:871-881`, `../framework/src/agent/src/compiler/compiler.lua:914-953`, `../framework/src/agent/src/compiler/compiler.lua:960-1008`) |
| Wippy runner | The framework registers `wippy.agent:agent` as a library, and its runner exposes `new` and `step`; it does not itself define a Bee launch. (`../framework/src/agent/src/_index.yaml:26-40`, `../framework/src/agent/src/agent.lua:421-470`) |
| Native Dataflow | The Flow builder has a function operation and an agent operation. Its agent configuration accepts an agent id, arena settings, active traits and active tools; the agent node applies those selections before loading the agent. A Bee run can therefore enter a Flow through the existing function operation. (`../dataflow/src/flow/flow.lua:76-100`, `../dataflow/src/flow/flow.lua:103-147`, `../dataflow/src/node/agent/node.lua:1996-2009`) |
| Kickside components | Product modules own contracts; bindings map contract methods to function ids, and host requirements supply dependencies. Agent components use a `wippy.agent:resolver` binding and may contribute `agent.gen1` entries. (`../../kickside/main/app/src/app/docs/kickside-development/02-contracts-and-ports.md:15-25`, `../../kickside/main/app/src/app/docs/kickside-development/02-contracts-and-ports.md:87-115`, `../../kickside/main/app/src/app/docs/kickside-development/16-conventions.md:45-85`, `../../kickside/main/app/src/app/docs/kickside-development/06-agents-skills-models.md:264-306`) |
| Kickside traits/tools | Components contribute `agent.trait` entries and `function.lua` tools with `meta.type: tool`, schema and model-facing metadata. Public tools can be projected as virtual function Blocks. (`../../kickside/main/app/src/app/docs/kickside-development/06-agents-skills-models.md:20-43`, `../../kickside/main/app/src/app/docs/kickside-development/06-agents-skills-models.md:81-135`, `../../kickside/main/app/src/app/docs/kickside-development/18-blocks-flows-workflows.md:73-83`) |
| Bee launch | `bee.launch-definition@1` identifies a binding, profile and policy, with mode, workdir, thread, session, credentials and presentation rules, plus an optional `agent_ref` naming one `agent.gen1` entry. An agent route resolves the framework closure from the same snapshot and pins its digest, exact gateway tools, mapped model and declined hints in the measured plan. (`modules/harness/src/launch/definition.lua`, `modules/harness/src/launch/agent_resolver.lua`, `modules/harness/src/launch/admission.lua`) |
| Bee profile | Saved profiles select a launch definition and contain driver options, MCP tool names and instructions capped at 4,096 bytes. These are not a framework agent definition; on an agent route `agent_preferences` narrows a saved profile inside the admitted closure and refuses tools outside it or an option claiming `model`. (`modules/harness/src/profiles/protocol.lua`) |
| Bee gateway | Its catalog uses local tool names, operation ids and policy refs, plus traits of prompt and tool names. `catalog.from_framework` projects an admitted closure's function tools (under their `llm_alias` adapter alias) and traits into the same declarations. Selection checks the host tool ceiling; tool execution uses a scoped subject executor. (`modules/gateway/src/catalog.lua`, `modules/gateway/src/api/mcp_method.lua:48-53`) |
| Bee child launch | `thread_launch` and the application facade `agent_call` share one request (`bee.application:agent_protocol`: definition or saved profile, brief, retry key, workspace, working directory, thread, placement) and one launch path (`caller_launch`). Workdir, thread and placement choices apply only where the definition and its launch policy both allow the override; a `docker` placement is refused with `PLACEMENT_UNAVAILABLE`. (`modules/application/src/agent_protocol.lua`, `modules/harness/src/launch/caller_launch.lua`, `modules/harness/src/launch/admission.lua`) |
| Bee drivers | Claude and Codex prepare declarative CLI launches; their model/effort and permission/sandbox options differ. Driver bindings also exist for Agy, Grok and Muse. (`modules/driver-claude/src/launch.lua:13-19`, `modules/driver-claude/src/launch.lua:89-112`, `modules/driver-codex/src/launch.lua:4-17`, `modules/driver-codex/src/launch.lua:65-105`, `modules/driver-agy/src/_index.yaml:71-72`, `modules/driver-grok/src/_index.yaml:62-63`, `modules/driver-muse/src/_index.yaml:74-75`) |
| Bee driver execution | Current catalog compatibility accepts `stream-json` for batch/session and `pty` for windows; an in-process Wippy profile needs a new execution path. (`modules/harness/src/catalog/classify.lua:46-47`) |
| Bee placement | The host policy names an optional placement binding and options. The resolver defaults to the native binding, and the native module supplies that binding. A migration admits a `docker` value; the surveyed implementation is native. (`modules/harness/src/carrier/policy.lua:237-251`, `modules/placement/src/resolver.lua:10-17`, `modules/placement-native/src/_index.yaml:271-289`, `modules/placement-native/src/migrations/migrations.lua:92`) |
| Bee workspaces | The node catalog migration gives `workspaces` a `workspace_id` primary key and keys workspace state by that id; catalog indexes support ordered label and path search. The current host manager also starts a workspace host on demand, capped at 64 live hosts. (`src/storage/store.lua:149-174`, `src/storage/store.lua:255-262`, `src/_index.yaml:169-181`) |

## Proposal: identity and composition

An **application** is a standalone component. It owns its own contracts and
publishes only the parts other components may use: agent ids, traits, function
tools, resolvers or run functions. Other applications, Bee and Dataflow consume
those stable registry ids or contracts. Dependencies and host inputs use
`ns.dependency` and `ns.requirement`; no consumer imports another app's private
store or duplicates its agent definition.

Keep the framework vocabulary authoritative:

1. An agent is a `registry.entry` with `meta.type: agent.gen1` and the
   framework's prompt, traits, tools, delegates, memory, context and model
   fields. A component may instead supply an agent through the framework's
   `wippy.agent:resolver` contract, as the Kickside component pattern does.
2. A capability is an `agent.trait`. Its prompt, member function tools,
   context and behavior bindings compose with any other framework trait.
3. A callable tool is a `function.lua` entry with `meta.type: tool`,
   `llm_alias`, `llm_description`, input/output schemas and any descriptive
   `mcp.required_scopes`. The implementation calls its owner's contracts.
4. An application interface is `contract.definition` plus
   `contract.binding`, with method schemas and function ids. Contracts
   expose useful agent parts and execution services independently of any UI.

Use registry ids as references, never copy a trait or tool body into a Bee
profile. Resolve exact entries at admission. Keep app version, agent id and
content digest separate so upgrades can be reviewed and existing runs can
recover against their admitted version.

### Proposed entries and fields

The following YAML is **illustrative proposal syntax**, not a loadable Bee
manifest. Existing framework agent fields keep their framework meanings.

```yaml
# App-owned, framework-shaped definition.
- name: reviewer
  kind: registry.entry
  meta: {type: agent.gen1, title: Reviewer}
  prompt: "Review the supplied change."
  traits: [acme.review.traits:repository]
  tools: [acme.review.tools:report]
  delegates: []
  memory: []
  model: review-model

- name: repository
  kind: registry.entry
  meta: {type: agent.trait, title: Repository}
  prompt: "Use the approved repository tools."
  tools: [acme.review.tools:read_file]

- name: report
  kind: function.lua
  meta:
    type: tool
    llm_alias: ReportReview
    llm_description: Return a review through the app contract.
    input_schema: '{"type":"object"}'
    output_schema: '{"type":"object"}'
    mcp: {required_scopes: [review.write]}
  source: file://report.lua
  method: handle

# Bee execution route: references the agent; does not redefine it.
- name: reviewer_launch
  kind: registry.entry
  meta: {type: bee.launch_definition}
  schema_revision: bee.launch-definition@2
  agent_ref: acme.review:reviewer
  harness: {requested_binding_ref: bee.driver.codex:binding,
            profile_id: batch}
  placement: {requested_kind: docker, image_class: review-worker}
  workdir_policy: {kind: required}
  thread_policy: {kind: new}
  default_mode: batch
```

The proposed route adds `agent_ref` and separate `harness` and `placement`
requests. It retains `launch_id`, mode and override rules, workdir/thread and
session policies, and presentation fields from version 1. Its `policy_ref` is
a host-linked policy reference. Credential names and concrete image or
executable selections move into protected host policy. App contracts use
`contract.definition.methods` with schemas and `contract.binding.contracts`
with method-to-function mappings; the app may expose the agent id, tools and
run function through those methods.

The route's requested harness and placement are **requirements or
preferences**, not authority. The host admits an activated driver binding,
profile, launch policy, placement binding and resource mapping. `agent_ref` is
required for a framework-defined managed run;
legacy routes remain version 1 until deliberately migrated. Do not place an
executable path, credential value, Docker image address or secret in the agent
entry or route.

## Proposal: converge Bee's existing pieces

| Bee piece | Convergence rule |
|---|---|
| Gateway trait | Resolve an `agent.trait` id and its full framework metadata. Use its prompt and admitted function tools for MCP presentation; preserve build/prompt/step/binding/wrapper semantics for the native Wippy driver. Refuse an unsupported required behavior on a CLI driver. |
| Gateway tool | Describe a `function.lua` id with `meta.type: tool` and schemas. The MCP name is an adapter alias for that id, not a second tool definition. The function still executes under a host-selected scope. |
| Instructions | Compose framework `prompt`, trait prompt contributions and run brief into the harness's instruction channel. Remove the saved-profile 4 KiB ceiling as a definition limit; keep explicit per-driver transport bounds and fail if exceeded. Saved instructions become an optional, reviewable override layer. |
| Driver options | Map `model`, `thinking_effort` and compatible options into a driver's declared profile. Refuse unknown or unrepresentable options; never silently drop agent semantics. |
| Delegates | Resolve framework delegate references. A Bee child launch tool may implement a delegate only when the host admits its launch route; delegation never copies the parent's grants. |
| Memory and contracts | Resolve framework memory, lifecycle, checkpoint and tool-wrapper bindings for the native Wippy driver. CLI drivers must advertise and prove equivalent behavior before accepting a definition that requires it. |
| Workdir and thread | Keep these Bee run inputs, resolved from admitted resource and thread references. They do not become `agent.gen1` fields or filesystem paths supplied by a definition. |
| Profile editor | Edit/select framework agent and trait/tool references alongside driver preferences. Store user choices by workspace id; do not fork the app-owned agent record. |

The convergence should be an internal compiler/resolver over framework entries,
not a permanent Bee trait/tool mirror. A capability unsupported by the chosen
harness yields a structured `UNSUPPORTED_CAPABILITY` result naming the entry
and field. No implicit prompt-only fallback.

## Proposal: orthogonal execution choices

The **harness/driver** decides how the agent performs a turn. Claude and Codex
are CLI bindings; a **native Wippy agent driver** calls the framework compiler
and runner directly. It needs an in-process profile and carrier adapter rather
than a CLI executable. The native driver must use the same admitted agent digest,
trait/tool selection and contract bindings as a direct framework call. It
supports framework prompt functions, step functions, wrappers, memory,
lifecycle, checkpoint and delegation semantics where corresponding bindings
are available. It emits Bee thread action, result and usage records through
the ordinary carrier path, with stable attempt and retry ids. It runs as the
admitted actor and scope, and resolves app contracts through their bindings.

**Placement** decides where that harness runs. Native placement starts a host
selected executable or native Wippy execution context. A proposed Docker
placement implements `bee.placement:placement` with the same prepare, start,
status, stop, reconcile, cleanup, evidence, attach, capabilities,
measure_executable and close_stdin methods. Selection of Claude, Codex or
native Wippy does not itself select native or Docker placement. A native Wippy
driver in Docker requires a runnable Wippy environment there; admission must
reject a host that lacks one.

For Docker, the host policy maps `image_class` to an immutable image digest,
registry/trust rule, platform, entrypoint, mounts, network policy, credentials
and cleanup requirement. The agent definition may describe a desired image
class; only host policy supplies the concrete image and authorizes the
container. Admission pins the selected image digest and placement binding in
the plan and durable attempt. A tag change or unavailable digest is a conflict
or refusal before start. Placement verifies the image at preparation and
recovery, records evidence, and makes no host credential available solely
because an image or tool requested it.

## Proposal: admission and authority

Definitions describe; they never authorize. For tools, traits, delegates,
resource access and launch routes, compute **effective = requested ∩ host
policy**, then apply the caller's authenticated actor and scope. Host policy
owns executable bindings, image digests, credentials, gateway tool ceilings,
resource roots, placement bindings and activation. Keep Native Terminal's
operating system user authority; a framework scope is not an OS sandbox
(`docs/development/conventions.md:85-89`).

Resolve `agent_ref` from the same pinned registry snapshot as the launch
route. Add its exact id, version/content digest and resolved trait, tool,
delegate and required contract closure to the admission digest. Refuse changed
or missing entries before granting a resource, projecting a credential or
starting a carrier. Record the same measurements in the durable attempt so
retry and recovery cannot substitute a different definition. Validate all
requested refs, schemas, bounds and capability support at the typed boundary.

Treat overlays and their registry entries as node-level. Allow actors to live
at node level and serve several workspaces. Workspace separation is for state,
threads, resource associations, grants and user selections keyed by
`workspace_id`; it does not create per-workspace overlays, actors, databases or
processes. Admission binds each run to one workspace id. Catalog and picker
reads should be indexed and paginated for many apps and workspaces, without
one resident process or copy of the definition per app/workspace pair.

## Proposal: an agent run as an ordinary function

Expose a versioned application or Bee run contract whose `run` method maps to
one `function.lua` entry. Proposed input: `{agent_ref, workspace_id,
thread_ref?, brief, harness_request?, placement_request?, workdir_ref?,
idempotency_key, expected_plan_digest?}`. The authenticated caller supplies
authority through context; `workspace_id` and refs are checked against it.
Proposed result: `{thread_id, action_id, attempt_id, status, result?}` or a
typed refusal. An admitted asynchronous run returns durable identities;
waiting for completion is a separate bounded operation. An app can expose its
own run function through its contract while delegating admission to Bee.

A native Dataflow node calls this function through the existing `func` node
operation. It passes explicit input/context, records the returned attempt
identity, and waits or resumes through the run contract as required. No Bee
specific Dataflow agent node type is required. A native Dataflow `agent` node
may continue to use the same framework agent directly. Both paths resolve the
same agent/trait/tool registry ids; host admission still governs a Bee run.

## Proposal: phased delivery

1. **Contract and parity:** specify the version 2 route, agent closure digest,
   app-owned contract shape and a compatibility matrix for every driver.
   Add negative cases for unsupported trait behavior and changed references;
   plan migration away from one resident host per open workspace.
2. **Framework convergence:** resolve `agent.gen1`, `agent.trait` and function
   tools from pinned entries; present admitted tools through the gateway;
   migrate one Bee trait, tool and instruction source without duplicate data.
3. **Native Wippy driver:** implement its binding and contract behavior, with
   thread records, retries, memory and checkpoint tests under real admission.
4. **Function run surface:** expose the typed contract/function, prove a
   Dataflow `func` node can start, observe, resume and cancel an admitted run,
   and let app components contribute agent pieces through their own contracts.
5. **Docker placement:** add the host image policy and placement binding,
   evidence and cleanup tests; prove each admitted driver/placement combination
   or reject it explicitly. Extend pickers for many apps and workspaces.

Each phase updates its implementation contracts and tests before describing
the new operation as callable. Version 1 routes remain readable during a
deliberate migration; no applied migration is edited.

## Open questions for the proposal

1. Which framework fields are mandatory parity for CLI drivers, and which
   optional fields may a route explicitly decline before admission?
   (Answered for CLI routes by the implemented closure and admission above:
   exact identity, composed prompt and context, trait and tool schemas,
   admitted delegates and a host-approved model mapping are mandatory; only
   owner-declinable tuning hints may pass as declined.)
2. Should app-owned run contracts standardize one result/wait/cancel envelope,
   or can they wrap a small Bee execution contract with domain-specific output?
3. How should a workspace select a user agent supplied by a resolver while
   pinning both component state revision and the resulting framework spec?
   (Answered by the implemented workspace agent selection: stored `agent_ref`,
   `owner_component_revision` and `spec_digest` in workspace state, resolved
   under workspace authority from one snapshot, re-verified before admission,
   and pinned in the attempt plan.)
4. Which image identity and attestation evidence must Docker admission pin,
   including multi-platform manifests and image updates?
5. What is the exact cancellation and checkpoint handshake between a durable
   Dataflow function node, the Bee attempt and the native Wippy driver?
   (Answered by the implemented function run lifecycle: `run` returns a durable
   receipt promptly, checkpointed by Dataflow before bounded waits; `cancel`
   records an idempotent Bee cancel intent, stops the attempt, and waits for a
   terminal carrier record; recovery reconciles uncertain stops.)
