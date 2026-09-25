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

-- This is deliberately derived only from broker-owned launch values. The
-- execution generation changes when the producer is replaced; the logical
-- actor ID remains stable for the workspace and application instance.
function M.value(workspace_id: unknown, instance_id: unknown, definition_id: unknown,
    definition_revision: unknown, execution_generation: unknown): Value?
    local workspace = text(workspace_id, 32)
    if not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then return nil end
    local instance = text(instance_id, 80)
    local definition = text(definition_id, 160)
    local revision = text(definition_revision, 80)
    local generation = positive_generation(execution_generation)
    if not instance or not definition or not revision or not generation then return nil end
    return {id = "bee.application:" .. workspace .. ":" .. instance,
        metadata = {workspace_id = workspace, definition_id = definition,
            definition_revision = revision, execution_generation = generation}}
end

return M
