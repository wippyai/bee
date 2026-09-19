# Security Model - Process Isolation, Capability Control, and Data Boundaries

_Path: en/concepts/security-model_

> How Wippy controls what your code can access, what it cannot, and who enforces those boundaries. Covers process isolation, registry-based capability control, multi-tenant enforcement, and agent security.

## Table of Contents

- Security Model

## Content

# Security Model


Wippy's security model defines what your code can access, what it cannot, and who enforces those boundaries. It is worth reading before you build, because it works at two layers that most frameworks collapse into one: the runtime isolates each process so dangerous capabilities are simply absent, and an attribute-based policy layer governs which registry capabilities a process is allowed to use. Understanding both changes how you structure an application.



## Trust Model


Wippy's isolation layer gives a process no ambient authority. A fresh Lua or WASM process cannot touch the file system, the network, the host OS, or other processes' memory, because those capabilities are not present in its environment. Capabilities arrive only through the registry: functions, tools, connections, and configuration the process is explicitly granted.

On top of that, access to registry capabilities is governed by attribute-based access control (ABAC). Every guarded operation is checked against the current actor's security scope, a set of policies that allow or deny an action on a resource, optionally conditioned on actor and resource metadata. This is declarative: you define policies in configuration, not in application code.

When a process runs with both an actor and a scope, access is deny-by-default: a request is allowed only if a policy explicitly permits it and none denies it. **Strict mode** governs the incomplete case, when no actor or scope is established. It is **on by default**, so an incomplete context is denied; setting `security.strict_mode: false` in the runtime config opts into the permissive behavior instead. The consequence to plan for is that a process with no declared security context fails every check under the default — give such a process a `security:` block on its entry, or start it through a path that supplies one. Combined with least-privilege policies, this gives you fail-closed authorization on top of deny-by-absence isolation. See the [Security reference](system/security.md) for policy syntax, evaluation rules, and the shape of the `security:` block.



## Process Isolation


Every unit of execution in Wippy runs in an isolated process with its own embedded interpreter (Lua or WASM).

**What a process has:** its own memory space (a baseline overhead of ~13 KB for Lua). A scoped view of the registry. An actor identity and a security scope. A supervised lifecycle with crash recovery and restart limits.

**What a process does not have:** access to the file system (except through registry-controlled filesystem entries). Access to the network (except through granted HTTP client or tool modules). Access to other processes' memory. Access to the Go runtime hosting it. Access to environment variables (except through granted environment entries).

**How isolation is enforced:** each Lua process starts from a minimal standard library. File I/O, OS process access, dynamic code loading, and networking are never loaded, so they are not present in the environment, and the process cannot restore what does not exist. Module loading is restricted: `require` resolves only the modules and registry entries the process is explicitly granted, with no file system search path. WASM processes achieve equivalent isolation through WASI: only the host functions and mounted filesystem entries configured for that entry are reachable.

This is not sandboxing via runtime permissions (like seccomp or AppArmor). It is sandboxing via absence. Dangerous capabilities are never loaded, so they cannot be exploited, bypassed, or escalated.



## Capability Control


The registry is Wippy's capability store, and security policies are its authorization layer.

**Every capability is a registry entry.** Functions, tools, agent definitions, database connections, environment references, configuration values, and scheduled tasks are all registry entries with a declared kind, schema, and metadata. Entries are validated by their kind handler when registered.

**Entry IDs are namespaced.** An ID has the form `namespace:name` with a single colon, and namespaces are hierarchical via dot-separated segments, for example `tenant_acme.tools:read` (namespace `tenant_acme.tools`, name `read`). Policies match actions and resources, and resource patterns can target a namespace prefix, so a single rule can cover an entire namespace.

**Policies decide access.** Each capability access (a registry lookup, a function call, a database handle, a file open) is checked against the actor's scope. A policy declares the actions and resources it covers, an allow or deny effect, and optional conditions on actor and resource metadata. Evaluation happens per access, not once at startup: if any policy denies, access is denied; if at least one allows and none denies, it is allowed; if no policy matches, access is denied. (When the context has no actor or scope at all, that incomplete case is resolved by strict mode rather than by policy evaluation.)

**A context is declared, not inherited from thin air.** Functions inherit the caller's actor and scope. A spawned process inherits them too: its frame is forked from the spawner's, and the `security:` block on its own entry then modifies that inherited context — an `actor` it names replaces the inherited actor, and the policies and policy groups it lists by registry ID are merged into the inherited scope. Resolution is atomic — if any named policy or group is missing, the spawn fails rather than proceeding with a partial scope. A CLI command can additionally declare `meta.command.security`, applied only on the trusted launch path where the operator started the command themselves.

**Tool arguments are schema-shaped.** A tool declares a JSON Schema for its inputs. That schema is given to the model so it generates conforming arguments, and access to the tool is policy-checked before the call runs.



## Data Boundaries


**Database connections are registry entries.** A process does not assemble its own connection string. It requests a connection by registry ID, and that request is policy-checked before a handle is returned. A process whose policies do not grant Tenant B's database entry cannot obtain a handle to it.

**LLM API keys live in the environment system.** Keys for Claude, GPT, and other providers are read from the environment system (for example OS environment variables exposed through an `env.storage.os` entry, referenced by `env.variable` entries whose reads are policy-checked via the `env.get` action). The provider reads them internally; they are not passed in process arguments or returned to calling code.

**File and blob storage follow the same model.** A process reads or writes through filesystem or cloud-storage registry entries, each access policy-checked. WASM processes access files only through filesystem entries explicitly mounted for that entry.



## Agent Security


Agents are LLM-powered processes with tool use. They make decisions at runtime that your code does not directly control, so their boundaries matter. Wippy handles this through the same registry and policy mechanisms as any other process.

**Tool access.** An agent can only invoke tools listed in its definition, and each tool execution runs through `funcs.call`, which is policy-checked. A denied call fails before the tool function runs. An agent designed to read customer data but not delete it either has no delete tool in its definition or is denied that action by policy.

**External and MCP tools.** Wippy can consume external tools and expose its own over the Model Context Protocol. Consumed tools run through the same function-call path and policy checks as native tools. Tools Wippy exposes to external MCP clients are gated by scoped, revocable access tokens that limit which actions a client may perform.

**Structured output.** The LLM module can request schema-constrained (structured) output using the provider's native structured-output support, so an agent's output can be held to a declared shape.

**Observability.** With OpenTelemetry enabled, LLM provider calls and tool invocations are traced, and token usage is recorded through the usage-tracker contract. This gives you an audit trail of what an agent called and what it spent. See [Observability](guides/observability.md).

**Self-modification boundaries.** An agent permitted to create tools in one namespace can be denied write access to its own definition in another. Registry writes are policy-checked actions, so a deny policy on the agent's own namespace prevents it from editing itself or granting itself new access.



## Multi-Tenant Enforcement


For deployments where multiple customers share a single Wippy instance, isolation is enforced by policy evaluation before any operation runs, not by application code checking tenant IDs.

**Tenant isolation is policy-enforced.** Give each tenant an actor and a scope whose policies cover only that tenant's namespaces. With strict mode on, a tenant's process is denied access to resources outside its scope before its code runs. Effective isolation depends on writing those per-tenant policies; the runtime enforces them, but it does not infer tenancy for you.

**Cross-tenant access is explicit.** A capability shared across tenants lives in a shared namespace that each tenant's policies allow. Sharing is opt-in per namespace.

**Concurrency is bounded at the host.** Process hosts bound concurrency through worker pools. Process groups (`pg.scope`) provide isolated, cluster-wide membership and broadcast namespaces and can cap group and member counts. Per-tenant CPU or memory ceilings are not a built-in runtime feature; enforce those at the infrastructure layer.

A dedicated Multi-Tenant Architecture guide is planned.



## Scope and Limitations


Wippy's security model covers process isolation, capability control, and data boundaries. The following are outside the runtime's scope and remain your infrastructure's responsibility.

**Data encryption at rest.** Database, disk, and blob-storage encryption are handled by the underlying infrastructure (PostgreSQL TDE, disk encryption, and similar). Wippy assumes the storage layer handles encryption.

**Network-level isolation.** Process isolation happens at the application layer. Network segmentation between Wippy and its dependencies (database, LLM APIs, external services) is handled by infrastructure: VPCs, security groups, firewalls.

**Identity management.** Authentication (verifying who a user is) is handled by your auth layer. Wippy's security model starts after authentication: it controls what an authenticated user's processes can do, not who the user is. Tokens that carry an actor and scope can be issued and validated through a token store.

**Infrastructure audit logs.** Wippy's tracing covers process-level operations: function calls, tool calls, process activity. Infrastructure-level access (SSH to the server, database admin operations) should be audited by infrastructure tools.



## Common Questions


**Can one tenant's agent access another tenant's data?**
Not when each tenant's resources are scoped by policy. With per-tenant policies and strict mode, the runtime denies access to resources outside the tenant's scope before the agent's code runs.

**Can an agent escalate its own permissions?**
Only if its policies allow writing to its own definition. Registry writes are policy-checked, so a deny policy on the agent's own namespace prevents self-modification. An agent that can create tools in one namespace cannot grant itself access to namespaces its scope does not already cover.

**How do I see what an agent did?**
With OpenTelemetry enabled, LLM and tool calls are traced, and token usage is recorded through the usage-tracker contract. See [Observability](guides/observability.md).

**What happens if an agent behaves unexpectedly?**
It is contained by the sandbox: no file system, no network, no OS, no access to other processes beyond what it was granted. It can only call tools in its definition that policy permits, and those calls are logged.

**Is tenant isolation enforced by my code or by the runtime?**
By the runtime. The policy engine evaluates each access before the operation runs. Your job is to write the per-tenant policies; the runtime enforces them.

**How are external MCP tools secured?**
Tools consumed over MCP run through the same function-call path and policy checks as native tools. Tools Wippy exposes to external MCP clients are gated by scoped, revocable access tokens. Connecting an MCP service does not bypass the security model.



## Security Reference


| Concern | Wippy's approach |
|---------|------------------|
| Process isolation | Separate interpreter per process (Lua or WASM), no shared memory |
| Default access | Unmatched policies deny when both an actor and a scope are set; strict mode, on by default, denies when no actor or scope is established |
| Context declaration | `security:` block on the entry (actor, policies, groups); resolution is atomic and fail-closed |
| Supply chain | Module packs verified by digest at install and at boot; a mismatch refuses the module |
| Node-to-node trust | Mutually authenticated internode mesh; ed25519 identity per node, explicit trusted-peer map |
| Workflow propagation | Actor and scope carried to Temporal as a signed, audience-bound header; verification failure fails the execution |
| Capability control | Registry entries governed by attribute-based security policies (actor, scope, action, resource) |
| Data boundaries | Connections and storage are registry entries; each access is policy-checked by entry ID |
| API key management | Stored in the environment system, read internally by providers, not exposed to process code |
| Agent tool control | Tools limited to the agent's definition; each call checked via `funcs.call` policy |
| External tools (MCP) | Same function-call path and policy checks; exposed tools gated by scoped tokens |
| Agent audit trail | OpenTelemetry tracing (when enabled) plus usage-tracker records |
| Multi-tenant isolation | Per-tenant policies and scopes evaluated by the runtime before each operation |
| Concurrency limits | Bounded by host worker pools; no per-tenant CPU/memory ceilings built in |
| Self-modification | Deny policies on registry-write actions prevent agents from editing their own definitions |



## See Also


- [Security reference](system/security.md) - Policies, scopes, actors, token stores, and the `security:` block
- [Dependency Management](guides/dependency-management.md#integrity-verification) - Module digest verification
- [Cluster](guides/cluster.md#internode-identity) - Internode identity and peer trust
- [Temporal Workflows](temporal/workflows.md#security-context) - Signed context propagation
- [Registry](concepts/registry.md) - The capability store
- [Process Model](concepts/process-model.md) - Process isolation and lifecycle
- [Agents](framework/agents.md) - Agent definitions and tool use



## Navigation

Previous: "Registry" (concepts/registry)
Next: "Process Model" (concepts/process-model)
