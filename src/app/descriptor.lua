-- MIT. An app's declaration: the meta.application record on a process.lua
-- entry of meta.type bee.application. It names the app's title, icon, group and role,
-- whether one instance or many run, how a kept instance comes back, the menus
-- it is placed in, and whether it runs a terminal page.
local M = {}

M.TYPE = "bee.application"

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

-- problem names the first field of meta.application that keeps value from
-- declaring an app, with the value it expects; nil when value declares one.
function M.problem(value: unknown): string?
    if type(value) ~= "table" then return "meta.application must be an object" end
    if value.api_version ~= 1 then return "meta.application.api_version must be 1" end
    if value.lifetime ~= "view" then return "meta.application.lifetime must be view" end
    local title = text(value.title, 80)
    if not title or title == "" then return "meta.application.title must be one line of 1 to 80 characters" end
    if not text(value.icon or "", 8) then return "meta.application.icon must be at most 8 characters" end
    local revision = text(value.revision, 80)
    if not revision or revision == "" then return "meta.application.revision must be a string of 1 to 80 characters, such as '1'" end
    if not text(value.group or "", 160) then return "meta.application.group must be at most 160 characters" end
    if not text(value.role or "", 32) then return "meta.application.role must be at most 32 characters" end
    if value.instance_policy ~= "singleton" and value.instance_policy ~= "multiple" then
        return "meta.application.instance_policy must be singleton or multiple"
    end
    local schema = text(value.resume_schema or "", 80)
    if not schema then return "meta.application.resume_schema must be at most 80 characters without control characters" end
    local restart = value.restart_policy or "never"
    if restart ~= "never" and restart ~= "automatic" and restart ~= "manual" then
        return "meta.application.restart_policy must be never, automatic or manual"
    end
    if restart ~= "never" and schema == "" then
        return "meta.application.restart_policy " .. tostring(restart) .. " needs a nonempty meta.application.resume_schema; use never for an app without checkpoints"
    end
    if not menus(value.menus) then return "meta.application.menus must be a list of at most 16 bee.menu entry ids" end
    if value.terminal ~= nil and type(value.terminal) ~= "boolean" then return "meta.application.terminal must be true or false" end
    return nil
end

-- decode returns the descriptor process entry id declares in value, its
-- meta.application, or nil when the record is not a valid declaration.
function M.decode(id: string, value: unknown): Descriptor?
    if M.problem(value) then return nil end
    local declared = value :: {[string]: unknown}
    local placed = menus(declared.menus) :: {string}
    local restart = declared.restart_policy or "never"
    return {definition_id = id, definition_revision = declared.revision :: string, title = declared.title :: string,
        icon = (declared.icon or "") :: string, group = (declared.group or "") :: string,
        role = (declared.role or "") :: string, singleton = declared.instance_policy == "singleton",
        resume_schema = (declared.resume_schema or "") :: string, restart_policy = restart :: string,
        menus = placed, terminal = declared.terminal == true}
end

return M
