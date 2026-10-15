local process = require("process")
local security = require("security")
local application = require("application")
local principal = require("principal")
local bounds = require("bounds")
local function handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    local options = request and bounds.object(request.options)
    local workspace = options and bounds.id(options.workspace_id)
    local definition_id = options and bounds.id(options.definition_id)
    local actor = security.actor()
    local metadata = actor and bounds.object(actor:meta())
    if not request or not options or not workspace or not definition_id or not metadata
        or metadata.workspace_id ~= workspace or metadata.definition_id ~= definition_id then
        return {error = "application launch identity does not match its workspace and definition"}
    end
    if not actor or actor:id() ~= principal.actor_id(workspace, options.instance_id)
        or metadata.execution_generation ~= options.execution_generation then
        return {error = "application launch instance does not match its caller"}
    end
    local definition, err = application.definition(definition_id)
    if not definition then return {error = err} end
    if metadata.definition_revision ~= definition.revision or options.definition_revision ~= definition.revision then
        return {error = "application changed before launch"}
    end
    local scope, scope_error = application.scope(definition, workspace)
    if not scope then return {error = scope_error} end
    local pid, spawn_error = process.with_options({terminal = request.terminal})
        :with_context({["bee.workspace_id"] = workspace}):with_scope(scope)
        :spawn(definition.process, "bee:workers", options)
    return {pid = pid and tostring(pid), error = spawn_error and tostring(spawn_error)}
end
return {handle = handle}
