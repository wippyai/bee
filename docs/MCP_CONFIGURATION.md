# Configurable managed MCP

The protected launch policy may supply `gateway_surface` alongside
`gateway_tools`. The latter is the independent tool ceiling for the launch.
The carrier passes the measured configuration to gateway admission; changing
the configuration changes the launch policy digest. Admission freezes the surface declaration with
the binding. Referenced native policies currently resolve at each call; this
does not freeze their compiled definitions across a host policy update. Component metadata alone grants neither invocation nor scope.

`gateway_surface` contains:

- `tools`: component tool descriptions (`name`, `operation`, `description`,
  `policies`, `schema`, `annotations`). Built-in tools are included automatically;
  duplicate names and the reserved `session`/`call_tool` names are refused.
- `traits`: `{id, title, prompt, tools}` declarations; multiple may be active.
- `base_tools`: always selected within the launch's tool ceiling.
- `active_traits`: initially selected trait IDs.
- `fixed_context`: host-selected native context data.
- `dynamic_keys`: context keys this binding may set itself.

The endpoint must independently have invocation permission for each admitted
operation. Tools run as the binding's subject with the named host-approved
policies. Tools retain their own strict boundary decoders and domain checks.
The endpoint's context/actor/scope construction rights are not given to tools.

`session` with `{operation: "read"}` returns the revision, admitted traits,
active traits, dynamic context, allowed context keys and current tool schemas.
`{operation: "select", expected_revision, active_traits, context}` replaces
the selection atomically. A stale revision is refused. Fixed context cannot
be overwritten; unknown dynamic keys are refused. Context is ordinary native
`ctx` data and does not select security actors or permissions. Native
`with_context` overlays these values on the endpoint's inherited context; it
does not clear ambient keys. Host endpoint composition therefore also controls
what inherited context tools can see. Native Terminal retains OS-user authority;
MCP scopes do not sandbox its filesystem.

For each tool invocation the gateway supplies native context key
`bee.gateway.binding` with `binding_id`, `thread_id`, `action_id` and `attempt_id`
from the authenticated binding. Host configuration and agent-selected context
cannot declare or replace this reserved key. Its four bounded identifiers are
separate from the configurable context quota. Custom tools can use this record
to attribute results without accepting thread/attempt IDs from tool arguments.
It grants no authority: the executor's actor and scope, endpoint invocation
permission and destination owner checks still apply. Tools exposed through
other call paths must authorize those callers too; a context value alone does
not authenticate a direct function caller.

The built-in `workspace` tool's read-only `guide` operation returns this
destination's application authoring contract and one minimal example, generated
from the rule tables preflight enforces; it names no workspace and grants
nothing. Its create/list/read/put/remove/freeze operations accept up to 65,536
bytes of inline text or
87,384 bytes of canonical padded base64 (at most 65,536 decoded bytes) per
file. The HTTP MCP endpoint caps each complete JSON request body at 524,288
bytes, leaving room for JSON escaping and the bounded request envelope.
Governance continues to enforce its own larger file limit and validates that
base64 is canonical; the MCP limits are transport bounds for one tool call.

Clients that cache MCP discovery can use the stable `call_tool` tool with
`{name, arguments}` after selecting traits. It uses the same active-tool check
and invocation path as a direct call. Selecting a trait does not grant a tool
outside the independent ceiling. Use `session` read to get current schemas and
trait instructions; the gateway does not rewrite a running harness's system
prompt. Credential rotation retains binding-owned selection, while revocation
invalidates access to both selection and tools.

The 1010-case Lua suite, 17-case managed-carrier suite, HTTP fixture lint,
production lint, pack and bundle checks pass. The real HTTP probe demonstrates two active traits,
native fixed/dynamic context, denied host-key replacement and foreign traits,
stale revision refusal, separate binding state, denied gateway database/scope
access from a tool, credential rotation preserving selection and context, and
credential revocation. Storage acceptance proves state
across reopen. Two concurrent HTTP selection requests prove one committed
winner and one stale-revision conflict. The real managed-carrier MCP child also
activates two traits, dispatches a newly selected tool, and rejects fixed-context
overwrite. A same-binding HTTP test also proves that a host policy replacement
affects subsequent tool calls after native policy publication converges. The performance dashboard remains the next milestone.

For example, a protected launch policy can keep thread reads available and let
its agent activate waiting when coordinating work:

```yaml
gateway_tools: [thread_read, thread_wait]
gateway_surface:
  tools: []
  traits:
    - id: research:coordination
      title: Research coordination
      prompt: Read the thread and wait for new results before continuing.
      tools: [thread_wait]
  base_tools: [thread_read]
  active_traits: []
  fixed_context: {project: selected-project}
  dynamic_keys: [experiment]
```

The client reads `session`, then selects `research:coordination` with that
revision and `{experiment: "baseline"}` as context. It can call `thread_wait`
directly or through `call_tool`. An unlisted trait, an unadmitted tool or a
caller-provided `project` value is refused. This configuration belongs to the
host's protected launch policy; passing it as ordinary tool arguments cannot
admit it.

## Agent-requested access

A protected surface can declare `access: {workspace_id, policy, traits}`. These
trait IDs are requestable, initially unavailable capabilities. They cannot also
be initially active, in base tools, or exposed through a freely selectable trait.
The declaration selects the approval workspace and approver policy; an agent
cannot supply either, executable targets, tool scopes, or fixed app context.

The built-in `session` tool accepts `request_access` with `idempotency_key`,
`traits` and a bounded `reason`. It creates an ordinary durable approval request
bound to the agent's gateway binding, action, attempt, thread, configuration
digest and fixed context. The client Approvals inbox uses its existing owner
feed and decision operation. The agent polls `access_status` with the returned
`approval_id`; an approved decision is consumed under a stable effect key before
the gateway records and activates the traits for this binding. No other binding
changes, even when two agents share the same subject identity.

The approval owner remains the decision authority. A gateway receipt records
only the applied effect, atomically with its surface revision. Replaying a status
read does not duplicate the grant or reactivate a later-deselected trait. If the
owner restarts before consumption, the gateway verifies the exact proposal and
configuration before revalidation. A crash after consumption but before applying
can replay that same effect. Request expiry limits consumption; a completed grant
lasts for its binding, whose revocation/credential lifecycle still governs every
MCP call. Receipt capacity is bounded and exhaustion refuses new grants.

An application target must be host-fixed in context and enforced by its tool's
own decoder and native policy. Merely including an app identifier in context is
not a replacement for target authorization. This integration does not grant
arbitrary registry publication or permission for an agent to approve itself.
Production and HTTP-fixture lint pass, as do 1015 Lua cases. The real HTTP
fixture in two native runtimes proves pending inbox visibility, request replay,
explicit approval, recovery of an already-consumed effect before gateway apply,
unchanged revision on grant replay, preserved deselection, fixed-context refusal,
and denial for another binding or a denied request. Store reopen/rollback checks
cover durable effect receipts. The explicit live Agy gate also passes: Gemini requests the trait itself, the
fixture operator approves the exact inbox request, and Gemini uses its grant
to commit the verified thread message. This is not yet a full provider/client
restart proof or the default-profile setup UI. Client-wide automatic notifications and
discovery across approximately 100 Bees remain separate work.
