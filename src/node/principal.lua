-- MIT. The identity an app instance runs as: one application principal per
-- workspace and instance, derived only from the node owner's launch values.
-- The execution generation changes when the producer is replaced; the
-- logical actor ID stays stable for the workspace and app instance.
local bounds = require("bounds")
local M = {}

type Value = {id: string, metadata: {[string]: string | integer}}

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
    return value
end

local function positive_generation(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > 2147483647 then return nil end
    return math.floor(value)
end

function M.actor_id(workspace_id: unknown, instance_id: unknown): string?
    local workspace = bounds.id(workspace_id)
    if not workspace then return nil end
    local instance = text(instance_id, 160)
    if not instance then return nil end
    return "bee.application:" .. workspace .. ":" .. instance
end

function M.value(workspace_id: unknown, instance_id: unknown, definition_id: unknown,
    definition_revision: unknown, execution_generation: unknown): Value?
    local workspace = bounds.id(workspace_id)
    local instance = text(instance_id, 80)
    local definition = text(definition_id, 160)
    local revision = text(definition_revision, 80)
    local generation = positive_generation(execution_generation)
    local actor_id = M.actor_id(workspace, instance)
    if not workspace or not instance or not definition or not revision or not generation or not actor_id then return nil end
    return {id = actor_id,
        metadata = {workspace_id = workspace, definition_id = definition,
            definition_revision = revision, execution_generation = generation}}
end

return M
