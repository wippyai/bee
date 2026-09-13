-- MIT. Placement values: what a launch asks for, what an attempt is, and
-- what a runtime can promise about cleanup. Nothing here runs anything.
local driver_types = require("driver_types")
local preferences = require("preferences")
type Preferences = preferences.Value
type Capability = "direct_process" | "process_group" | "contained_tree"
-- How a runtime lets the runner learn the exit: independently of the pipes,
-- or only once both streams end.
type ExitObservation = "independent" | "eof_gated"
type ExecutionState = "intended" | "starting" | "running" | "stopping" | "exited" | "uncertain"
type CleanupState = "pending" | "complete" | "uncertain"
type Access = "read" | "write"
type Purpose = "project" | "output" | "cache" | "session"
type StopMode = "cooperative" | "forced"
-- One admitted resource: an fs.directory root the host admits, a subpath
-- inside it, and the access the owner granted. grant_ref is the owner's
-- reference for that decision; placement records it, never interprets it.
type ResourceGrant = {name: string, grant_ref: string, root_ref: string, subpath: string, access: Access, purpose: Purpose}
-- drain_ms bounds how long a runner keeps reading after an independently
-- observed exit while descendants hold the pipes open; expiry closes the
-- streams and is recorded as output.drain_elapsed. retain_ms bounds how
-- long unacknowledged output is kept after the child exited and both
-- streams ended; expiry is recorded as output.lost.
type Timeouts = {start_ms: integer, stop_grace_ms: integer, drain_ms: integer, retain_ms: integer}
-- A generated configuration file for the private home: reviewed content
-- rendered by the driver at admission, written with protected creation.
type Configuration = {revision: string, path: string, content: string, digest: string, provider_ref: string}
type ConfigurationDelivery = {arguments: {string}, files: {Configuration}}
-- The plan's measurement of the launch executable, verified by the runner
-- immediately before exec.
type ExecutableMeasurement = {revision: string, kind: string, digest: string}
-- The gateway binding a launch carries: the admitted tool set, the
-- host-approved endpoint and credential destinations, and the
-- environment destination the runner fills with the materialized token.
-- The binding itself is resolved by attempt and carrier epoch at
-- materialization; no token or binding id travels in the request.
type Gateway = {endpoint: string, tools: {string}, destination: string, hooks: {string}, hook_destination: string?}
type LaunchRequest = {
    preferences: Preferences?,
    idempotency_key: string,
    owner_id: string,
    owner_incarnation: integer,
    action_id: string,
    attempt_id: string,
    binding_ref: string,
    policy_ref: string,
    profile_id: string,
    binding_digest: string,
    profile_digest: string,
    launch: driver_types.Launch,
    configuration_digest: string?,
    -- Placement-owned output, never accepted by the request decoder.
    delivery: ConfigurationDelivery?,
    executable: ExecutableMeasurement?,
    gateway: Gateway?,
    resources: {ResourceGrant},
    environment: {[string]: string},
    environment_refs: {[string]: string},
    projections: {string},
    session_ref: string?,
    required_cleanup: Capability,
    required_exit_observation: ExitObservation,
    timeouts: Timeouts,
}
type Exit = {code: integer?, signal: integer?}
-- The projection of an attempt's evidence: execution and cleanup are
-- separate so a finished cleanup never hides how the process ended.
type Attempt = {
    attempt_id: string,
    action_id: string,
    owner_id: string,
    owner_incarnation: integer,
    request_digest: string,
    execution_state: ExecutionState,
    cleanup_state: CleanupState,
    capability: Capability,
    required_cleanup: Capability,
    exit_observation: ExitObservation,
    exit_source: string?,
    attachment_generation: integer,
    exit: Exit?,
    session_ref: string?,
    home_ref: string?,
    runner: string?,
    evidence_count: integer,
    created_at: string,
    updated_at: string,
}
type Evidence = {sequence: integer, at: string, kind: string, detail: string}
type EvidencePage = {attempt_id: string, evidence: {Evidence}, next_after: integer?}
-- One live observation, separate from the recorded state.
type Liveness = {observed: boolean, alive: boolean?, at: string, detail: string}
type Status = {attempt: Attempt, liveness: Liveness}
local M = {}
-- The host launch policy entry type; placement authorizes a request's
-- host-selected parts against the policy the request names.
M.LAUNCH_POLICY_TYPE = "bee.launch_policy"
M.CAPABILITIES = {"direct_process", "process_group", "contained_tree"}
M.EXECUTION_STATES = {"intended", "starting", "running", "stopping", "exited", "uncertain"}
M.CLEANUP_STATES = {"pending", "complete", "uncertain"}
M.EXIT_OBSERVATIONS = {"independent", "eof_gated"}
M.ACCESS = {"read", "write"}
-- What an executable measurement covers: a native image, a script file
-- without its interpreter, or bytes of no known form.
M.EXECUTABLE_KINDS = {"elf", "script", "other"}
M.PURPOSES = {"project", "output", "cache", "session"}
M.STOP_MODES = {"cooperative", "forced"}
-- Capability order: a runtime that controls a group also controls the
-- direct process; a contained tree covers both.
function M.rank(capability: Capability): integer
    if capability == "contained_tree" then return 3 end
    if capability == "process_group" then return 2 end
    return 1
end
function M.satisfies(available: Capability, required: Capability): boolean
    return M.rank(available) >= M.rank(required)
end
function M.observes(available: ExitObservation, required: ExitObservation): boolean
    return available == "independent" or required == "eof_gated"
end
return M
