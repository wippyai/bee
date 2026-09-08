-- MIT. Public workspace descriptions contain no execution or mount authority.
local contract = require("contract")
local decode = require("decode")
type View = {workspace_id: string, view_id: string, instance_id: string, definition_id: string, title: string, icon: string?}
type State = {workspace_id: string, catalog_revision: integer, views_revision: integer, catalog: {contract.Descriptor}, views: {View}}
type Catalog = {version: integer, workspace_id: string, connection_id: string, revision: integer, items: {contract.Descriptor}}
type Views = {version: integer, workspace_id: string, connection_id: string, revision: integer, items: {View}}
local M = {}
local function revision(value: unknown): integer?
    if type(value) ~= "number" or value < 0 or value > 9007199254740990 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function next_revision(value: integer): integer
    if value >= 9007199254740990 then error("Workspace inventory revision exhausted") end
    return value + 1
end
function M.view(value: unknown): View?
    if type(value) ~= "table" then return nil end
    local workspace_id = contract.workspace_id(value.workspace_id)
    local view_id, instance_id = contract.text(value.view_id, 80), contract.text(value.instance_id, 80)
    local definition_id, title = contract.text(value.definition_id, 160), contract.text(value.title, 80)
    local icon = contract.text(value.icon, 8)
    if not workspace_id or not view_id or view_id == "" or not instance_id or instance_id == ""
        or not definition_id or definition_id == "" or not title or (value.icon ~= nil and not icon) then return nil end
    return {workspace_id = workspace_id, view_id = view_id, instance_id = instance_id, definition_id = definition_id, title = title, icon = icon}
end
function M.new(workspace_id: string): State
    if not contract.workspace_id(workspace_id) then error("Invalid inventory workspace") end
    return {workspace_id = workspace_id, catalog_revision = 0, views_revision = 0, catalog = {}, views = {}}
end
function M.set_catalog(state: State, value: unknown): State?
    local items = decode.catalog(value)
    if not items then return nil end
    return {workspace_id = state.workspace_id, catalog_revision = next_revision(state.catalog_revision),
        views_revision = state.views_revision, catalog = items, views = state.views}
end
function M.observe(state: State, reply: contract.Reply): State?
    if reply.workspace_id ~= state.workspace_id then return nil end
    local remove = reply.op == "closed" or (reply.op == "close" and reply.error_code == "")
    local opened = reply.op == "open" and reply.error_code == ""
    local titled = reply.op == "title" and reply.error_code == ""
    if not remove and not opened and not titled then return nil end
    local incoming: View? = nil
    if opened then
        incoming = M.view({workspace_id = state.workspace_id, view_id = reply.id, instance_id = reply.instance_id,
            definition_id = reply.definition_id, title = reply.title, icon = reply.icon})
        if not incoming then return nil end
    end
    local views: {View} = {}
    local changed, found = false, false
    for _, previous in ipairs(state.views) do
        local current = previous
        if previous.view_id == reply.id and previous.instance_id == reply.instance_id then
            found = true
            if remove then changed = true
            else
                if titled and previous.title ~= reply.title then
                    current = {workspace_id = previous.workspace_id, view_id = previous.view_id, instance_id = previous.instance_id,
                        definition_id = previous.definition_id, title = reply.title, icon = previous.icon}
                    changed = true
                end
                views[#views + 1] = current
            end
        else
            -- An old incarnation must not replace or remove the current target.
            if previous.view_id == reply.id then return nil end
            views[#views + 1] = current
        end
    end
    if opened and not found and incoming then
        if #views >= 16 then error("Workspace live inventory capacity exceeded") end
        views[#views + 1] = incoming
        changed = true
    end
    if not changed then return nil end
    return {workspace_id = state.workspace_id, catalog_revision = state.catalog_revision,
        views_revision = next_revision(state.views_revision), catalog = state.catalog, views = views}
end
function M.catalog_message(state: State, connection_id: string): Catalog
    return {version = 1, workspace_id = state.workspace_id, connection_id = connection_id, revision = state.catalog_revision, items = state.catalog}
end
function M.views_message(state: State, connection_id: string): Views
    return {version = 1, workspace_id = state.workspace_id, connection_id = connection_id, revision = state.views_revision, items = state.views}
end
function M.catalog(value: unknown): Catalog?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local workspace_id, connection_id = contract.workspace_id(value.workspace_id), contract.text(value.connection_id, 80)
    local sequence, items = revision(value.revision), decode.catalog(value.items)
    if not workspace_id or not connection_id or connection_id == "" or not sequence or not items then return nil end
    return {version = 1, workspace_id = workspace_id, connection_id = connection_id, revision = sequence, items = items}
end
function M.views(value: unknown): Views?
    if type(value) ~= "table" or value.version ~= 1 or type(value.items) ~= "table" then return nil end
    local workspace_id, connection_id = contract.workspace_id(value.workspace_id), contract.text(value.connection_id, 80)
    local sequence = revision(value.revision)
    if not workspace_id or not connection_id or connection_id == "" or not sequence then return nil end
    local count = 0
    for key in pairs(value.items) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local items: {View} = {}
    local known: {[string]: boolean} = {}
    for index = 1, count do
        local item = M.view(value.items[index])
        if not item or item.workspace_id ~= workspace_id or known[item.view_id] then return nil end
        known[item.view_id] = true
        items[#items + 1] = item
    end
    return {version = 1, workspace_id = workspace_id, connection_id = connection_id, revision = sequence, items = items}
end
return M
