local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local application = require("application")
local app_identity = require("app_identity")
local supervisor = require("supervisor")
type Object = {[string]: unknown}
local function handle(request: supervisor.Request): Object
    local turn = request.turn
    local workspace = assert(bounds.id(turn.workspace_id))
    local session = assert(bounds.id(turn.session_ref))
    local thread = assert(bounds.id(turn.thread_id))
    local reply: Object = {invocation_id = request.id}
    if not (security.can("bee.sessions.hook_boundary", session) or security.can("bee.threads.carrier", thread)) then
        reply.diagnostic = "hook supervision is not authorized"; return reply
    end
    local definition, definition_error = application.definition(request.application_ref)
    if not definition or definition.revision ~= request.application_revision then
        reply.diagnostic = definition_error or "application revision changed before invocation"; return reply
    end
    local actor = application.actor(workspace, "hook-" .. request.id, definition, 1)
    local scope, scope_error = application.scope(definition, workspace)
    if not actor or not scope then reply.diagnostic = scope_error or "application authority unavailable"; return reply end
    local _, admission, admission_error = application.admission(definition.process, workspace)
    local stable = app_identity.stable(workspace, definition.process, admission and admission.overlay_owner)
    if not stable or admission_error then reply.diagnostic = admission_error or "application membership identity is unavailable"; return reply end
    local alias: Object = {stable = stable.id, instance = actor:id(), workspace_id = workspace, definition_id = definition.process}
    local registered, registration_error = funcs.call("bee.threads.binding:register_app_alias", alias)
    local registration = bounds.object(registered)
    if registration_error or not registration or registration.ok ~= true then reply.diagnostic = "hook application membership is unavailable"; return reply end
    local executor = funcs.new():with_context({}):with_actor(actor):with_scope(scope):with_options({retry = {max_attempts = 1}})
    local budget = supervisor.budget(request.driver, request.point)
    reply.reply, reply.diagnostic = supervisor.run(executor, request.target, request.id, request.point, turn,
        math.min(budget.invocation_ms, budget.chain_ms, request.remaining_ms))
    local retired, retirement_error = funcs.call("bee.threads.binding:retire_app_alias", alias)
    local retirement = bounds.object(retired)
    if retirement_error or not retirement or retirement.ok ~= true then error("retire hook application membership") end
    return reply
end
return {handle = handle}
