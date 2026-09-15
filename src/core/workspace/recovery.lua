-- Durable values only: no PIDs, grants, handles, security policies or native resources.
local decode = require("decode")
local contract = require("contract")
local json = require("json")
local model = require("model")
local appearance = require("appearance")
type Record = {id: string, instance_id: string, definition_id: string, thread_id: string?, resume_schema: string,
    restart_policy: string, resume_state: string, window: model.Window?}
type Desktop = {scene: model.Scene, tabs: {string}, preferences: appearance.Preferences}
type Snapshot = {version: integer, desktop: Desktop, applications: {Record}}
local M = {}
function M.record(value: unknown): Record?
    if type(value) ~= "table" then return nil end
    local id, instance = contract.text(value.id, 80), contract.text(value.instance_id, 80)
    local definition, schema = contract.text(value.definition_id, 160), contract.text(value.resume_schema, 80)
    local thread_id = value.thread_id == nil and nil or contract.thread_id(value.thread_id)
    if not id or id == "" or not instance or instance == "" or not definition or definition == "" or not schema or schema == ""
        or (value.thread_id ~= nil and not thread_id) then return nil end
    if value.restart_policy ~= "automatic" and value.restart_policy ~= "manual" then return nil end
    if type(value.resume_state) ~= "string" or #value.resume_state > 65536 then return nil end
    if value.resume_state ~= "" then
        local _, err = json.decode(value.resume_state)
        if err then return nil end
    end
    local window: model.Window? = nil
    if value.window ~= nil then
        local scene = decode.scene({width = 80, height = 24, revision = 0, focus = "", windows = {value.window}})
        if not scene or scene.windows[1].id ~= id or scene.windows[1].instance_id ~= instance then return nil end
        window = scene.windows[1]
    end
    return {id = id, instance_id = instance, definition_id = definition, thread_id = thread_id, resume_schema = schema,
        restart_policy = value.restart_policy, resume_state = value.resume_state, window = window}
end
function M.decode(encoded: string): Snapshot?
    if #encoded > 2097152 then return nil end
    local value: unknown = json.decode(encoded)
    if type(value) ~= "table" or value.version ~= 1 or type(value.applications) ~= "table" then return nil end
    local desktop = decode.desktop(value.desktop)
    if not desktop then return nil end
    local count = 0
    for key in pairs(value.applications) do
        if type(key) ~= "number" or key < 1 or key > 16 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    local records: {Record} = {}
    local instances: {[string]: boolean} = {}
    local views: {[string]: boolean} = {}
    for index = 1, count do
        local item = M.record(value.applications[index])
        if not item or instances[item.instance_id] or views[item.id] then return nil end
        instances[item.instance_id] = true; views[item.id] = true
        records[#records + 1] = item
    end
    return {version = 1, desktop = {scene = desktop.scene, tabs = desktop.tabs, preferences = desktop.preferences}, applications = records}
end
return M
