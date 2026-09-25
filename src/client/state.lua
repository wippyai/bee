-- MIT. Client layout contains durable targets, never execution credentials.
local decode = require("decode")
local contract = require("contract")
local model = require("model")
local appearance = require("appearance")
local hash = require("hash")
type Target = {tab_id: string, workspace_id: string, instance_id: string, view_id: string}
type AppearanceMode = "inherit" | "custom"
type State = {version: integer, appearance_mode: AppearanceMode, scene: model.Scene, tabs: {string}, preferences: appearance.Preferences, targets: {Target}}
local M = {}
function M.decode(value: unknown): State?
    if type(value) ~= "table" or (value.version ~= 1 and value.version ~= 2) or type(value.targets) ~= "table" then return nil end
    local mode: AppearanceMode = "custom"
    if value.version == 2 then
        if value.appearance_mode == "inherit" then mode = "inherit"
        elseif value.appearance_mode == "custom" then mode = "custom"
        else return nil end
    end
    local desktop = decode.desktop(value)
    if not desktop then return nil end
    local count = 0
    for key in pairs(value.targets) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    if count ~= #desktop.tabs then return nil end
    local windows: {[string]: model.Window} = {}
    for _, window in ipairs(desktop.scene.windows) do
        if not contract.text(window.id, 80) or not contract.text(window.title, 80) then return nil end
        windows[window.id] = window
    end
    local targets: {Target} = {}
    local identities: {[string]: boolean} = {}
    for index = 1, count do
        local item: unknown = value.targets[index]
        if type(item) ~= "table" then return nil end
        local tab_id, instance_id = contract.text(item.tab_id, 80), contract.text(item.instance_id, 80)
        local workspace_id, view_id = contract.workspace_id(item.workspace_id), contract.text(item.view_id, 80)
        if not tab_id or tab_id == "" or not instance_id or instance_id == "" or not workspace_id or not view_id or view_id == "" then return nil end
        local identity = workspace_id .. "\0" .. instance_id .. "\0" .. view_id
        if identities[identity] then return nil end
        identities[identity] = true
        local window = windows[tab_id]
        if not window or window.workspace_id ~= workspace_id or window.instance_id ~= instance_id then return nil end
        windows[tab_id] = nil
        targets[#targets + 1] = {tab_id = tab_id, workspace_id = workspace_id, instance_id = instance_id, view_id = view_id}
    end
    return {version = 2, appearance_mode = mode, scene = desktop.scene, tabs = desktop.tabs, preferences = desktop.preferences, targets = targets}
end
-- A projection can precede queued add/remove commands. Build its durable target
-- list without pruning the owner's pending target records.
function M.project(current: State, value: unknown, targets: {[string]: Target}): (State?, string?)
    local desktop = decode.desktop(value)
    if not desktop then return nil, "Invalid session projection" end
    if desktop.scene.revision < current.scene.revision then return nil, nil end
    local selected: {Target} = {}
    for _, window in ipairs(desktop.scene.windows) do
        local target = targets[window.id]
        if not target then return nil, "Session produced an unknown tab" end
        selected[#selected + 1] = target
    end
    local result = M.decode({version = 2, appearance_mode = current.appearance_mode, scene = desktop.scene, tabs = desktop.tabs,
        preferences = desktop.preferences, targets = selected})
    if not result then return nil, "Session target identity mismatch" end
    return result, nil
end
function M.empty(width: integer, height: integer): State
    local tabs: {string} = {}
    local targets: {Target} = {}
    return {version = 2, appearance_mode = "inherit", scene = model.new(width, height), tabs = tabs, targets = targets, preferences = appearance.defaults()}
end
-- Stable import keys are client layout keys, not remote view IDs. Qualifying the
-- input before hashing lets different workspaces retain identical native IDs.
function M.import_desktop(workspace_id: string, value: unknown): (State?, string?)
    if not contract.workspace_id(workspace_id) then return nil, "Invalid workspace identity" end
    local desktop = decode.desktop(value)
    if not desktop then return nil, "Invalid legacy desktop" end
    local targets: {Target} = {}
    local keys: {[string]: string} = {}
    local scene = desktop.scene
    for _, window in ipairs(scene.windows) do
        if window.workspace_id ~= nil and window.workspace_id ~= workspace_id then return nil, "Foreign legacy window" end
        local view_id = contract.text(window.id, 80)
        local instance_id = contract.text(window.instance_id, 80)
        if not view_id or view_id == "" or not instance_id or instance_id == "" then return nil, "Invalid legacy target" end
        local tab_id, err = hash.sha256(workspace_id .. "\0" .. instance_id .. "\0" .. view_id)
        if not tab_id then return nil, tostring(err) end
        keys[view_id] = tab_id
        targets[#targets + 1] = {tab_id = tab_id, workspace_id = workspace_id, instance_id = instance_id, view_id = view_id}
        window.id, window.workspace_id = tab_id, workspace_id
    end
    scene.focus = keys[scene.focus] or ""
    local tabs: {string} = {}
    for _, id in ipairs(desktop.tabs) do tabs[#tabs + 1] = keys[id] end
    local result = M.decode({version = 1, scene = scene, tabs = tabs, preferences = desktop.preferences, targets = targets})
    if not result then return nil, "Invalid imported client layout" end
    return result, nil
end
function M.target(state: State, tab_id: string): Target?
    for _, target in ipairs(state.targets) do
        if target.tab_id == tab_id then
            return {tab_id = target.tab_id, workspace_id = target.workspace_id, instance_id = target.instance_id, view_id = target.view_id}
        end
    end
    return nil
end
return M
