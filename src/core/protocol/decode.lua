local model = require("model")
local appearance = require("appearance")
local contract = require("contract")
local M = {}
type Reply = contract.Reply
local function reply_op(value: unknown): contract.ReplyOp?
    if value == "open" then return "open" end
    if value == "close" then return "close" end
    if value == "closed" then return "closed" end
    if value == "focus" then return "focus" end
    if value == "attached" then return "attached" end
    if value == "bind" then return "bind" end
    if value == "unbind" then return "unbind" end
    if value == "page" then return "page" end
    if value == "title" then return "title" end
    if value == "closing" then return "closing" end
    if value == "quit" then return "quit" end
    if value == "shutdown" then return "shutdown" end
    return nil
end
function M.reply(value: unknown): Reply?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local workspace_id = contract.workspace_id(value.workspace_id)
    if value.workspace_id ~= nil and not workspace_id then return nil end
    local op = reply_op(value.op)
    if not op then return nil end
    local request_id, id = contract.text(value.request_id, 80), contract.text(value.id, 80)
    local instance, title = contract.text(value.instance_id, 80), contract.text(value.title, 80)
    local mount, code = contract.text(value.mount, 1024), contract.text(value.error_code, 80)
    if not request_id or not id or not instance or not title or not mount or not code
        or type(value.error) ~= "string" or #value.error > 4096 then return nil end
    local icon = contract.text(value.icon, 8)
    if value.icon ~= nil and not icon then return nil end
    return {version = 1, request_id = request_id, op = op, id = id, instance_id = instance, workspace_id = workspace_id, icon = icon,
        title = title, mount = mount, error_code = code, error = value.error,
        definition_id = contract.text(value.definition_id, 160) or "", resume_schema = contract.text(value.resume_schema, 80) or "",
        restart_policy = contract.text(value.restart_policy, 16) or "never",
        resume_state = type(value.resume_state) == "string" and #value.resume_state <= 65536 and value.resume_state or ""}
end
function M.belongs(reply: Reply, workspace_id: string): boolean
    return reply.workspace_id == workspace_id and contract.workspace_id(workspace_id) ~= nil
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value < -2147483647 or value > 2147483647 then return nil end
    if value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function rect(value: unknown): model.Rect?
    if type(value) ~= "table" then return nil end
    local x, y, width, height = integer(value.x), integer(value.y), integer(value.width), integer(value.height)
    if not x or not y or not width or not height or width < 1 or height < 1 then return nil end
    return {x = x, y = y, width = width, height = height}
end
local function accent(value: unknown): string?
    if value == "" or value == "amber" or value == "cyan" or value == "green"
        or value == "rose" or value == "violet" then
        return value
    end
    return nil
end
local function window_mode(value: unknown): model.Mode?
    if value == "floating" then return "floating" end
    if value == "fullscreen" then return "fullscreen" end
    if value == "minimized" then return "minimized" end
    if value == "collapsed" then return "collapsed" end
    return nil
end
local function restore_mode(value: unknown): model.RestoreMode?
    if value == "floating" then return "floating" end
    if value == "fullscreen" then return "fullscreen" end
    if value == "collapsed" then return "collapsed" end
    return nil
end
local function window(value: unknown): model.Window?
    if type(value) ~= "table" then return nil end
    if type(value.id) ~= "string" or type(value.instance_id) ~= "string" or type(value.title) ~= "string" then return nil end
    local bounds, normal = rect(value.bounds), rect(value.normal_bounds)
    if not bounds or not normal then return nil end
    local mode = window_mode(value.mode)
    local restore = restore_mode(value.restore_mode)
    if not mode or not restore then return nil end
    local icon = contract.text(value.icon, 8)
    if value.icon ~= nil and not icon then return nil end
    local user_title = contract.text(value.user_title, 80)
    if value.user_title ~= nil and not user_title then return nil end
    local selected_accent = accent(value.accent)
    if value.accent ~= nil and selected_accent == nil then return nil end
    local workspace_id = contract.workspace_id(value.workspace_id)
    if value.workspace_id ~= nil and not workspace_id then return nil end
    return {id = value.id, instance_id = value.instance_id, workspace_id = workspace_id, title = value.title,
        user_title = user_title, accent = selected_accent, icon = icon,
        bounds = bounds, normal_bounds = normal, mode = mode, restore_mode = restore}
end
function M.scene(value: unknown): model.Scene?
    if type(value) ~= "table" or type(value.windows) ~= "table" or type(value.focus) ~= "string" then return nil end
    local width, height, revision = integer(value.width), integer(value.height), integer(value.revision)
    if not width or not height or not revision or width < 1 or height < 1 or revision < 0 then return nil end
    local count = 0
    for key in pairs(value.windows) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local windows: {model.Window} = {}
    local ids: {[string]: boolean} = {}
    for index = 1, count do
        local item = window(value.windows[index])
        if not item or item.id == "" or ids[item.id] then return nil end
        if item.id == value.focus and item.mode == "minimized" then return nil end
        ids[item.id] = true
        windows[#windows + 1] = item
    end
    if value.focus ~= "" and not ids[value.focus] then return nil end
    return {width = width, height = height, revision = revision, focus = value.focus, windows = windows}
end
type Acknowledgement = {version: integer, request_id: string, scene: model.Scene, tabs: {string}?, preferences: appearance.Preferences?, error_code: string, error: string}
type CatalogItem = contract.Descriptor
type Desktop = {scene: model.Scene, tabs: {string}, preferences: appearance.Preferences, catalog: {CatalogItem}}
function M.catalog(value: unknown): {CatalogItem}?
    if type(value) ~= "table" then return nil end
    local result: {CatalogItem} = {}
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 64 then return nil end
        count = count + 1
    end
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item: unknown = value[index]
        if type(item) ~= "table" or type(item.singleton) ~= "boolean" then return nil end
        local id, revision = contract.text(item.definition_id, 160), contract.text(item.definition_revision, 80)
        local title, icon = contract.text(item.title, 80), contract.text(item.icon, 8)
        local group, role = contract.text(item.group, 160), contract.text(item.role, 32)
        if not id or id == "" or seen[id] or not revision or not title or not icon or not group or not role then return nil end
        seen[id] = true
        result[#result + 1] = {definition_id = id, definition_revision = revision, title = title, icon = icon, group = group, role = role, singleton = item.singleton, resume_schema = contract.text(item.resume_schema, 80) or "", restart_policy = contract.text(item.restart_policy, 16) or "never"}
    end
    return result
end
function M.desktop(value: unknown): Desktop?
    if type(value) ~= "table" or type(value.tabs) ~= "table" then return nil end
    local scene = M.scene(value.scene)
    if not scene then return nil end
    local count = 0
    for key in pairs(value.tabs) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    if count ~= #scene.windows then return nil end
    local known: {[string]: boolean} = {}
    for _, win in ipairs(scene.windows) do known[win.id] = true end
    local tabs: {string} = {}
    for index = 1, count do
        local id = value.tabs[index]
        if type(id) ~= "string" or not known[id] then return nil end
        known[id] = nil
        tabs[#tabs + 1] = id
    end
    local preferences = value.preferences == nil and appearance.defaults() or appearance.decode(value.preferences)
    if not preferences then return nil end
    local catalog = value.catalog ~= nil and M.catalog(value.catalog) or {}
    if not catalog then return nil end
    return {scene = scene, tabs = tabs, preferences = preferences, catalog = catalog}
end
function M.ack(value: unknown): Acknowledgement?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id = contract.text(value.request_id, 80)
    local code = contract.text(value.error_code, 80)
    if not request_id or not code or type(value.error) ~= "string" or #value.error > 4096 then return nil end
    local desktop = M.desktop(value)
    if not desktop then return nil end
    return {version = 1, request_id = request_id, scene = desktop.scene, tabs = desktop.tabs, preferences = desktop.preferences,
        error_code = code, error = value.error}
end
return M
