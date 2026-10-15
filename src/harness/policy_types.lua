local placement_types = require("placement_types")
local configuration = require("configuration")

-- The host enables a permission exchange by naming the adapter, the
-- acceptance record and the proven fixture digest here; a production
-- policy may only name the adapter the profile itself pins.
type PermissionExchange = {adapter_ref: string, acceptance_ref: string, fixture_digest: string, approver_policy: string, poll_ms: integer, ttl_ms: integer}
type EnvironmentResolver = (string) -> (string?, string?)
type Policy = {
    ref: string,
    digest: string,
    permission_exchange: PermissionExchange?,
    permission_answers: string,
    provider_ref: string?,
    instructions: string?,
    instruction_builder: configuration.InstructionBuilder?,
    prepare_options: {[string]: unknown},
    option_provenance: {[string]: unknown}?,
    required_cleanup: placement_types.Capability,
    required_exit_observation: placement_types.ExitObservation,
    stop_grace_ms: integer,
    drain_ms: integer,
    runner_drain_ms: integer,
    retain_ms: integer,
    executables: {[string]: string},
    environment: {[string]: string},
    host_environment: {[string]: string},
    allow_host_home: boolean,
    -- gateway_tools names the gateway tools a launch under this policy is
    -- admitted to; empty means the launch has no gateway binding.
    gateway_tools: {string},
    gateway_surface: {[string]: unknown}?,
    -- agent_model_map approves framework agent models for this route: each
    -- agent-declared model name maps to the driver model identifier the
    -- launch carries. An agent model without a mapping is refused.
    agent_model_map: {[string]: string},
    -- agent_delegates lists the framework agent references a run under this
    -- policy may delegate to. Empty means the run may delegate to nothing.
    agent_delegates: {string},
    -- gateway_ttl_ms bounds a gateway binding's life from admission.
    gateway_ttl_ms: integer,
    -- gateway_hooks names the hook events the launch reports to the gateway.
    gateway_hooks: {string},
    hook_command_ref: string?,
    fixture: boolean,
    placement_profiles: {string},
    placement_binding: string?,
    placement_options: {[string]: unknown}?,
    allowed_overrides: {string},
}

return {}
