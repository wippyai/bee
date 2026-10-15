-- MIT. Directory for the gateway authority.
local security = require("security")
local contract = require("contract")
local bounds = require("bounds")
local sessions = require("sessions")
local part_model = require("part_model")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Object = part_model.Object
local fail = part_values.fail
local succeed = part_values.succeed
local function directory(value: unknown, fields: {string}): ({Object}?, Object?, Reply?)
    local request = bounds.object(value)
    if not request or bounds.fields(request, fields) then return nil, nil, fail("INVALID", "invalid workspace directory request") end
    local workspace = bounds.id(request.workspace_id)
    if not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then return nil, nil, fail("INVALID", "canonical workspace_id required") end
    local caller = security.actor()
    if not caller or not security.can(part_model.READ_WORKSPACE, workspace) then return nil, nil, fail("DENIED", "caller may not read this workspace") end
    local attributed, actor_error = security.new_actor(caller:id(), {workspace_id = workspace})
    if not attributed then return nil, nil, fail("DENIED", tostring(actor_error)) end
    local definition, contract_error = contract.get("bee.threads.sessions:contract")
    if not definition then return nil, nil, fail("UNAVAILABLE", tostring(contract_error)) end
    local acted, acting_error = definition:with_actor(attributed)
    if not acted then return nil, nil, fail("DENIED", tostring(acting_error)) end
    local owner, open_error = acted:open()
    if not owner then return nil, nil, fail("UNAVAILABLE", tostring(open_error)) end
    local rows: {Object} = {}
    local cursor: string? = nil
    local seen: {[string]: boolean} = {}
    for _ = 1, 64 do
        local reply_raw, call_error = owner:list({filter = {workspace = workspace}, cursor = cursor})
        local reply = bounds.object(reply_raw)
        if call_error or not reply or reply.ok ~= true then return nil, nil, fail("UNAVAILABLE", tostring(call_error or "Sessions directory unavailable")) end
        local items, decode_error = sessions.project(reply.value, workspace)
        if not items then return nil, nil, fail("UNAVAILABLE", decode_error or "invalid Sessions directory") end
        for _, item in ipairs(items) do rows[#rows + 1] = item end
        local page = bounds.object(reply.value)
        cursor = page and bounds.id(page.next)
        if not cursor then return rows, request, nil end
        if seen[cursor] then return nil, nil, fail("UNAVAILABLE", "Sessions directory repeated its cursor") end
        seen[cursor] = true
    end
    return nil, nil, fail("UNAVAILABLE", "Sessions directory exceeds the workspace projection bound")
end
function M.describe(value: unknown): Reply
    local listed, _, refused = directory(value, {"workspace_id"})
    if not listed then return assert(refused) end
    local items: {Object} = {}
    for index = 1, math.min(#listed, part_model.MAX_DESCRIBED) do items[index] = listed[index] end
    return succeed({title = "Agent sessions", items = items, total = #listed})
end
function M.search(value: unknown): Reply
    local listed, request, refused = directory(value, {"workspace_id", "text", "limit"})
    if not listed or not request then return assert(refused) end
    local wanted = bounds.line(request.text, 240)
    if not wanted then return fail("INVALID", "text must be one nonempty line") end
    local limit = request.limit == nil and part_model.MAX_DESCRIBED or bounds.integer(request.limit)
    if not limit or limit < 1 or limit > part_model.MAX_DESCRIBED then return fail("INVALID", "limit must be between 1 and 50") end
    local hits: {Object} = {}
    for _, item in ipairs(listed) do
        if #hits >= limit then break end
        if tostring(item.label):lower():find(wanted:lower(), 1, true) or tostring(item.session):sub(1, #wanted) == wanted then hits[#hits + 1] = item end
    end
    return succeed({title = "Agent sessions", hits = hits})
end
return M
