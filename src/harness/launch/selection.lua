-- MIT. Window-profile discovery from one immutable registry snapshot.
-- Choices contain presentation and measured identities only. Discovery never
-- creates work or grants launch authority; admission checks the chosen plan.
local catalog = require("catalog")
local definitions = require("definitions")
local admission = require("admission")
local bounds = require("bounds")
local M = {}
M.MAX_DEFINITIONS = 64
type Choice = {definition_ref: string, title: string, launch_id: string, plan_digest: string, unavailable: string?}
type Choices = {items: {Choice}, unavailable: integer}
function M.read(pinned: catalog.Pinned): (Choices?, string?)
    local found, find_error = pinned:find({["meta.type"] = definitions.TYPE})
    if find_error or not found then return nil, "Agent profiles could not be read" end
    if #found > M.MAX_DEFINITIONS then return nil, "Too many agent profiles to list" end
    local result: Choices = {items = {}, unavailable = 0}
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local ref = entry and bounds.id(entry.id) or nil
        if entry and ref then
            local definition = definitions.decode(ref, entry)
            if not definition then
                result.unavailable = result.unavailable + 1
            elseif definition.presentation.start_menu and definition.default_mode == "window" then
                local plan, refused = admission.read(pinned, ref, "window")
                if plan then
                    result.items[#result.items + 1] = {definition_ref = ref, title = definition.title,
                        launch_id = definition.launch_id, plan_digest = plan.plan_digest}
                else
                    result.unavailable = result.unavailable + 1
                    local fault = refused and refused.error
                    result.items[#result.items + 1] = {definition_ref = ref, title = definition.title,
                        launch_id = definition.launch_id, plan_digest = "",
                        unavailable = fault and fault.message or "Profile is unavailable on this node"}
                end
            end
        else
            result.unavailable = result.unavailable + 1
        end
    end
    table.sort(result.items, function(left: Choice, right: Choice): boolean
        if left.title ~= right.title then return left.title < right.title end
        return left.definition_ref < right.definition_ref
    end)
    return result, nil
end
function M.snapshot(): (Choices?, string?)
    local pinned = catalog.pin()
    if not pinned then return nil, "Agent profiles could not be read" end
    return M.read(pinned)
end
return M
