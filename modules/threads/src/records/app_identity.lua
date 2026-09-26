-- MIT. The stable application identity behind thread membership.
--
-- An application's thread-facing membership belongs to the admitted app:
-- its definition id within its workspace, refined by the overlay owner for
-- governed workspace applications. It never names one execution instance,
-- so any current instance of the same admitted app is the same member and
-- a reopened app keeps the threads and runs it launched. A different app,
-- another workspace, or another overlay owner resolves to another member.
local hash = require("hash")
local bounds = require("bounds")
local M = {}
M.PREFIX = "bee.application:"
M.GOV_OWNER_PREFIX = "bee.gov.apps:"
M.APP_NAMESPACE = "app."
M.APP_ENTRY = "app"
M.MAX_DEFINITION_BYTES = 160
M.READABLE_BYTES = 48
M.DIGEST_BYTES = 24
type Stable = {id: string, workspace_id: string, definition_id: string, overlay_owner: string?}

local function workspace(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end

local function definition(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_DEFINITION_BYTES or value:find("%c") then return nil end
    return value
end

-- The overlay a workspace-application definition was delivered from,
-- mirroring the workspace-application naming rule: namespace app.<name>
-- carrying entry app. Any other definition has no overlay component.
local function overlay_owner(workspace_id: string, definition_id: string): string?
    local namespace = definition_id:match("^(.*):" .. M.APP_ENTRY .. "$")
    if not namespace or namespace:sub(1, #M.APP_NAMESPACE) ~= M.APP_NAMESPACE then return nil end
    local name = namespace:sub(#M.APP_NAMESPACE + 1)
    if #name == 0 or #name > 48 or not name:match("^[a-z][a-z0-9_]*$") then return nil end
    return M.GOV_OWNER_PREFIX .. workspace_id .. "." .. name
end

local function readable(definition_id: string): string
    local text = definition_id:gsub("[^A-Za-z0-9_.-]", "-"):sub(1, M.READABLE_BYTES)
    if text == "" then return "app" end
    return text
end

function M.stable(workspace_id: unknown, definition_id: unknown): Stable?
    local workspace = workspace(workspace_id)
    local definition = definition(definition_id)
    if not workspace or not definition then return nil end
    local owner = overlay_owner(workspace, definition)
    local digest, digest_error = hash.sha256(workspace .. "\0" .. definition .. "\0" .. (owner or ""))
    if not digest or digest_error then return nil end
    local id = M.PREFIX .. workspace .. ":" .. readable(definition) .. "-" .. digest:sub(1, M.DIGEST_BYTES)
    if not bounds.id(id) or #id > bounds.MAX_ID_BYTES then return nil end
    return {id = id, workspace_id = workspace, definition_id = definition, overlay_owner = owner}
end

return M
