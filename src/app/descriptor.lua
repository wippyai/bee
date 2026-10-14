-- MIT. An app's declaration: the meta.application record on a process.lua
-- entry of meta.type bee.app. It names the app's title, icon, group and role,
-- whether one instance or many run, how a kept instance comes back, the menus
-- it is placed in, and whether it runs a terminal page.
local M = {}

M.TYPE = "bee.app"

type Descriptor = {definition_id: string, definition_revision: string, title: string, icon: string,
    group: string, role: string, singleton: boolean, resume_schema: string, restart_policy: string,
    menus: {string}, terminal: boolean}

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") then return nil end
    return value
end

local function menus(value: unknown): {string}?
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local found: {string} = {}
    for index = 1, count do
        local id = text(value[index], 160)
        if not id or id == "" then return nil end
        found[index] = id
    end
    return found
end

-- decode returns the descriptor process entry id declares in value, its
-- meta.application, or nil when the record is not a valid declaration.
function M.decode(id: string, value: unknown): Descriptor?
    if type(value) ~= "table" or value.api_version ~= 1 or value.lifetime ~= "view" then return nil end
    local title, icon = text(value.title, 80), text(value.icon or "", 8)
    local revision, group, role = text(value.revision, 80), text(value.group or "", 160), text(value.role or "", 32)
    if not title or title == "" or not icon or not revision or revision == "" or not group or not role then return nil end
    if value.instance_policy ~= "singleton" and value.instance_policy ~= "multiple" then return nil end
    local schema = text(value.resume_schema or "", 80)
    local restart = value.restart_policy or "never"
    if not schema or (restart ~= "never" and restart ~= "automatic" and restart ~= "manual") then return nil end
    if restart ~= "never" and schema == "" then return nil end
    local placed = menus(value.menus)
    if not placed then return nil end
    if value.terminal ~= nil and type(value.terminal) ~= "boolean" then return nil end
    return {definition_id = id, definition_revision = revision, title = title, icon = icon, group = group,
        role = role, singleton = value.instance_policy == "singleton", resume_schema = schema, restart_policy = restart,
        menus = placed, terminal = value.terminal == true}
end

return M
