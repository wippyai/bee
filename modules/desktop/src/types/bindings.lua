-- MIT. Owner-supplied status associations, separate from desktop layout.
-- The session authenticates the sender before calling decode. These values
-- name threads; they never establish membership or carry an execution scope.
local contract = require("contract")
local model = require("model")
local M = {}
type Binding = {tab_id: string, instance_id: string, thread_id: string?}
type Snapshot = {version: integer, workspace_id: string, revision: integer, items: {Binding}}
type State = {revision: integer, items: {Binding}}
local function fields(value: {[unknown]: unknown}, allowed: {[string]: boolean}): boolean
    for key in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then return false end
    end
    return true
end
function M.decode(value: unknown): Snapshot?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    if not fields(value, {version = true, workspace_id = true, revision = true, items = true}) then return nil end
    local workspace = contract.workspace_id(value.workspace_id)
    if not workspace then return nil end
    local revision = value.revision
    if type(revision) ~= "number" or revision < 1 or revision > 9007199254740990
        or revision ~= math.floor(revision) or type(value.items) ~= "table" then return nil end
    local count = 0
    for key in pairs(value.items) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local items: {Binding} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item = value.items[index]
        if type(item) ~= "table" or not fields(item, {tab_id = true, instance_id = true, thread_id = true}) then return nil end
        local tab, instance = contract.text(item.tab_id, 80), contract.text(item.instance_id, 80)
        local thread = contract.text(item.thread_id, 160)
        if not tab or tab == "" or not instance or instance == "" or seen[tab]
            or (item.thread_id ~= nil and (not thread or thread == "")) then return nil end
        seen[tab] = true
        items[#items + 1] = {tab_id = tab, instance_id = instance, thread_id = thread}
    end
    return {version = 1, workspace_id = workspace, revision = math.floor(revision), items = items}
end
function M.new(): State
    return {revision = 0, items = {}}
end
-- A complete newer snapshot replaces the old associations. Mismatches are
-- omitted, never retained for later: a delayed layout add cannot revive them.
function M.prune(items: {Binding}, scene: model.Scene, workspace: string): {Binding}
    local result: {Binding} = {}
    for _, item in ipairs(items) do
        for _, window in ipairs(scene.windows) do
            if window.workspace_id == workspace and window.id == item.tab_id and window.instance_id == item.instance_id then
                result[#result + 1] = {tab_id = item.tab_id, instance_id = item.instance_id, thread_id = item.thread_id}
                break
            end
        end
    end
    return result
end
function M.apply(state: State, snapshot: Snapshot, scene: model.Scene, workspace: string): State?
    if snapshot.workspace_id ~= workspace or snapshot.revision <= state.revision then return nil end
    return {revision = snapshot.revision, items = M.prune(snapshot.items, scene, workspace)}
end
return M
