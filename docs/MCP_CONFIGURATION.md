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
