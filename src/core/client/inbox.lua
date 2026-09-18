-- MIT. Client-owned question projection survives replacement of its presenter.
local layout = require("layout")
local questions = require("questions")
local interaction = require("interaction")
type Pending = {tab_id: string, id: string, instance_id: string}
type State = {workspace_id: string, connection_id: string, selection_revision: integer,
    question_revision: integer, signature: string?, targets: {layout.Target},
    items: {interaction.Wire}, pending: {[string]: Pending}}
local M = {}
function M.new(workspace_id: string, connection_id: string): State
    return {workspace_id = workspace_id, connection_id = connection_id, selection_revision = 0,
        question_revision = -1, signature = nil, targets = {}, items = {}, pending = {}}
end
function M.select(state: State, targets: {layout.Target}): boolean
    if #targets > 16 then error("Client selection capacity exceeded") end
    local keys: {string} = {}
    local copied: {layout.Target} = {}
    for _, target in ipairs(targets) do
        if target.workspace_id ~= state.workspace_id then error("Foreign inbox target") end
        keys[#keys + 1] = target.tab_id .. "\0" .. target.instance_id .. "\0" .. target.view_id
        copied[#copied + 1] = {tab_id = target.tab_id, workspace_id = target.workspace_id,
            instance_id = target.instance_id, view_id = target.view_id}
    end
    table.sort(keys)
    local signature = table.concat(keys, "\n")
    if signature == state.signature then return false end
    if state.selection_revision >= 9007199254740990 then error("Client selection revision exhausted") end
    state.signature, state.targets = signature, copied
    state.selection_revision, state.question_revision = state.selection_revision + 1, -1
    state.items, state.pending = {}, {}
    return true
end
function M.selection(state: State)
    local targets: {questions.Target} = {}
    for _, target in ipairs(state.targets) do targets[#targets + 1] = {id = target.view_id, instance_id = target.instance_id} end
    return {version = 1, workspace_id = state.workspace_id, connection_id = state.connection_id,
        revision = state.selection_revision, targets = targets}
end
function M.observe(state: State, data: unknown): boolean
    local snapshot = questions.snapshot(data)
    if not snapshot or snapshot.workspace_id ~= state.workspace_id or snapshot.connection_id ~= state.connection_id
        or snapshot.selection_revision ~= state.selection_revision or snapshot.revision <= state.question_revision then return false end
    local items: {interaction.Wire} = {}
    local retained: {[string]: Pending} = {}
    for _, spec in ipairs(snapshot.items) do
        local selected: layout.Target? = nil
        for _, target in ipairs(state.targets) do
            if target.view_id == spec.id and target.instance_id == spec.instance_id then selected = target end
        end
        if not selected then return false end
        spec.id = selected.tab_id
        items[#items + 1] = spec
        local pending = state.pending[spec.request_id]
        if pending then retained[spec.request_id] = pending end
    end
    state.question_revision, state.items, state.pending = snapshot.revision, items, retained
    return true
end
function M.answer(state: State, data: unknown)
    local response = interaction.response(data)
    if not response or state.pending[response.request_id] then return nil end
    local found = false
    for _, item in ipairs(state.items) do
        if item.id == response.id and item.instance_id == response.instance_id and item.request_id == response.request_id then
            if item.kind == "confirm" and response.value ~= "" then return nil end
            found = true
        end
    end
    if not found then return nil end
    for _, target in ipairs(state.targets) do
        if target.tab_id == response.id and target.instance_id == response.instance_id then
            state.pending[response.request_id] = {tab_id = target.tab_id, id = target.view_id, instance_id = target.instance_id}
            return {version = 1, workspace_id = state.workspace_id, connection_id = state.connection_id,
                selection_revision = state.selection_revision, request_id = response.request_id,
                id = target.view_id, instance_id = target.instance_id, action = response.action, value = response.value}
        end
    end
    return nil
end
function M.result(state: State, data: unknown): interaction.Result?
    if type(data) ~= "table" or data.workspace_id ~= state.workspace_id or data.connection_id ~= state.connection_id then return nil end
    local result = interaction.result(data)
    if not result then return nil end
    local pending = state.pending[result.request_id]
    if not pending or pending.id ~= result.id or pending.instance_id ~= result.instance_id then return nil end
    state.pending[result.request_id] = nil
    return {version = 1, request_id = result.request_id, id = pending.tab_id, instance_id = result.instance_id,
        error_code = result.error_code, error = result.error}
end
return M
