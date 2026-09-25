-- MIT. Host-owned question delivery; selection describes interest, never authority.
local contract = require("contract")
local interaction = require("interaction")
local protocol = require("protocol")
type Selection = protocol.Selection
type Snapshot = protocol.Snapshot
type State = {workspace_id: string, revision: integer, items: {interaction.Spec},
    selections: {[string]: Selection}, dispatched: {[string]: boolean}}
local M = {}
local function contains(selection: Selection, id: string, instance_id: string): boolean
    for _, target in ipairs(selection.targets) do
        if target.id == id and target.instance_id == instance_id then return true end
    end
    return false
end
function M.new(workspace_id: string): State
    if not contract.workspace_id(workspace_id) then error("Invalid question workspace") end
    return {workspace_id = workspace_id, revision = 0, items = {}, selections = {}, dispatched = {}}
end
function M.restore(value: unknown, workspace_id: string): State?
    if type(value) ~= "table" or value.workspace_id ~= workspace_id or type(value.revision) ~= "number"
        or value.revision < 0 or value.revision > 9007199254740990
        or value.revision ~= math.floor(value.revision) or type(value.selections) ~= "table"
        or type(value.dispatched) ~= "table" then return nil end
    local items = interaction.snapshot({version = 1, items = value.items})
    if not items then return nil end
    local selections: {[string]: Selection} = {}
    local count = 0
    for connection_id, selection in pairs(value.selections) do
        if type(connection_id) ~= "string" or type(selection) ~= "table" then return nil end
        local decoded = protocol.selection({version = 1, workspace_id = selection.workspace_id,
            connection_id = selection.connection_id, revision = selection.revision, targets = selection.targets})
        if not decoded or decoded.workspace_id ~= workspace_id or decoded.connection_id ~= connection_id then return nil end
        count = count + 1
        if count > 8 then return nil end
        selections[connection_id] = decoded
    end
    local dispatched: {[string]: boolean} = {}
    for request_id, sent in pairs(value.dispatched) do
        if type(request_id) ~= "string" or sent ~= true then return nil end
        dispatched[request_id] = true
    end
    return {workspace_id = workspace_id, revision = math.floor(value.revision), items = items,
        selections = selections, dispatched = dispatched}
end
-- Caller authentication and the admitted client's control permission are checked
-- by bee.host:clients before this owner-local model is entered.
function M.select(state: State, connection_id: string, data: unknown): boolean
    local selection = protocol.selection(data)
    if not selection or selection.workspace_id ~= state.workspace_id or selection.connection_id ~= connection_id then return false end
    local previous = state.selections[connection_id]
    if previous and selection.revision <= previous.revision then return false end
    if not previous then
        local count = 0
        for _ in pairs(state.selections) do count = count + 1 end
        if count >= 8 then return false end
    end
    state.selections[connection_id] = selection
    return true
end
function M.forget(state: State, connection_id: string)
    state.selections[connection_id] = nil
end
function M.update(state: State, data: unknown): boolean
    local items = interaction.snapshot(data)
    if not items then return false end
    local known: {[string]: boolean} = {}
    local dispatched: {[string]: boolean} = {}
    for _, item in ipairs(items) do
        if known[item.request_id] then return false end
        known[item.request_id] = true
        if state.dispatched[item.request_id] then dispatched[item.request_id] = true end
    end
    if state.revision >= 9007199254740990 then error("Question revision exhausted") end
    state.revision, state.items, state.dispatched = state.revision + 1, items, dispatched
    return true
end
function M.snapshot(state: State, connection_id: string): Snapshot?
    local selection = state.selections[connection_id]
    if not selection then return nil end
    local items: {interaction.Wire} = {}
    for _, item in ipairs(state.items) do
        if contains(selection, item.id, item.instance_id) then items[#items + 1] = interaction.wire(item) end
    end
    return {version = 1, workspace_id = state.workspace_id, connection_id = connection_id,
        selection_revision = selection.revision, revision = state.revision, items = items}
end
function M.answer(state: State, connection_id: string, data: unknown): (interaction.Response?, string?)
    local selection = state.selections[connection_id]
    if not selection or type(data) ~= "table" or data.workspace_id ~= state.workspace_id
        or data.connection_id ~= connection_id or data.selection_revision ~= selection.revision then return nil, "stale_selection" end
    local response = interaction.response(data)
    if not response or not contains(selection, response.id, response.instance_id) then return nil, "invalid_response" end
    for _, item in ipairs(state.items) do
        if item.request_id == response.request_id and item.id == response.id and item.instance_id == response.instance_id then
            if item.kind == "confirm" and response.value ~= "" then return nil, "invalid_response" end
            if state.dispatched[item.request_id] then return nil, "already_dispatched" end
            return response, nil
        end
    end
    return nil, "question_retired"
end
-- A successful send only dispatches an answer. Broker publication establishes
-- retirement; disconnecting or replacing a renderer cannot answer a question.
function M.dispatched(state: State, response: interaction.Response)
    state.dispatched[response.request_id] = true
end
return M
