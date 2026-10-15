-- MIT. Model for the gateway authority.
local configuration = require("configuration")
local hooks = require("hooks")
local surface = require("surface")
local M = {}
M.ADMIT = "bee.gateway.admit"
M.MANAGE = "bee.gateway.manage"
M.MATERIALIZE = "bee.gateway.materialize"
M.INSTALLATION_WORK = "bee.gateway.installation_work"
M.LISTENER_SERVICE = "bee.gateway.env:listener_ref"
M.ENDPOINT = configuration.ENDPOINT
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_DRAIN_MS = 600000
M.DEFAULT_DRAIN_MS = 30000
M.TOKEN_BYTES = 32
M.MAX_RETAINED_HOOKS = 256
M.MAX_RETAINED_HOOK_BYTES = 524288
M.MAX_HOOK_CLAIM = 32
M.DEFAULT_MATERIALIZATION_MS = 60000
M.MAX_MATERIALIZATION_MS = 600000
M.MAX_TOOLS = 32
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Row = {[string]: unknown}
type Object = {[string]: unknown}
type OriginView = {view_id: string, instance_id: string}
type Binding = {agent_traits: {string}?, agent_profile_write: boolean?, binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, owner_incarnation: integer, carrier_epoch: integer,
    approving_grant_id: string?, tools: {string}, hooks: {string}, epoch: integer, credential_generation: integer, expires_at: string, revoked: boolean, sealed: boolean, policy_ref: string?, workspace_id: string?, workspace_name: string, origin_view: OriginView?}
type Generation = {epoch: integer, restarts: integer}
type BoundSurface = {configuration: surface.Surface, selection: surface.Selection, revision: integer, digest: string}
type RuntimeGrant = {access_approval_id: string, access_proposal_digest: string, surface_revision: integer, surface_digest: string}
type Drain = {draining: boolean, past_deadline: boolean}
type HookRecord = {event_id: string, event: string, occurrence: string, ambiguous: boolean, digest: string, fields: Object,
    provenance: string, sequence: integer, created_at: string}
type HookQueueItem = HookRecord & {status: string, claimed_epoch: integer, rejected_reason: string?}
type HookStatus = {status: string, event: string, occurrence: string, ambiguous: boolean, sequence: integer,
    claimed_epoch: integer, rejected_reason: string?}
M.READ_WORKSPACE = "bee.node.workspace.read"
M.MAX_DESCRIBED = 50
return M
