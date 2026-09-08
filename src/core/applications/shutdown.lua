-- MIT. Pure shutdown negotiation state; process ownership stays with the broker.
type Decision = {id: string, title: string, message: string, force: boolean}
type State = {request_id: string, pending: {[string]: boolean}, decisions: {[string]: Decision}}

local M = {}
local MAX_ITEMS = 16
local MAX_ID_BYTES = 80

local function valid_text(value: unknown, required: boolean): string?
    if type(value) ~= "string" or #value > MAX_ID_BYTES or value:find("%c") then return nil end
    if required and value == "" then return nil end
    return value
end

local function copy_decision(value: Decision): Decision
    return {id = value.id, title = value.title, message = value.message, force = value.force}
end

function M.start(request_id: string, ids: {string}): State?
    local request = valid_text(request_id, true)
    if not request or type(ids) ~= "table" then return nil end

    local count = 0
    for key in pairs(ids) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > MAX_ITEMS then return nil end
        count = count + 1
    end
    if count > MAX_ITEMS then return nil end

    local pending: {[string]: boolean} = {}
    for index = 1, count do
        local id = valid_text(ids[index], true)
        if not id or pending[id] then return nil end
        pending[id] = true
    end
    return {request_id = request, pending = pending, decisions = {}}
end

function M.record(state: State, id: string, title: string, message: string, force: boolean): boolean
    if type(id) ~= "string" or type(title) ~= "string" or type(message) ~= "string" or type(force) ~= "boolean"
        or not state.pending[id] then return false end
    state.pending[id] = nil
    state.decisions[id] = {id = id, title = title, message = message, force = force}
    return true
end

function M.remove(state: State, id: string)
    state.pending[id] = nil
    state.decisions[id] = nil
end

function M.ready(state: State): boolean
    return next(state.pending) == nil
end

function M.decisions(state: State): {Decision}
    local result: {Decision} = {}
    for _, decision in pairs(state.decisions) do result[#result + 1] = copy_decision(decision) end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function M.empty(state: State): boolean
    return next(state.pending) == nil and next(state.decisions) == nil
end

function M.needs_confirmation(state: State): boolean
    for _, decision in pairs(state.decisions) do
        if decision.force or decision.message ~= "" then return true end
    end
    return false
end

return M
