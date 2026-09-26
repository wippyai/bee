-- MIT. Pure checks for the host gateway through which applications make the
-- contract calls and HTTP requests their installed grants allow. The runtime
-- authorizes contract.call on the bare method name and http_client.request on
-- the URL alone, so an application never holds those actions; it calls the
-- gateway, which authenticates the broker-created principal, reads that
-- application's own live grant record and admits only the exact binding and
-- method, or the approved origin, method and path prefix. A callee receives
-- the original application actor, so its owner checks see the real caller.
local bounds = require("bounds")

local M = {}
M.CONTRACT_CALL = "bee.gov.binding:contract_call"
M.HTTP_REQUEST = "bee.gov.binding:http_request"
M.GRANTED_RESOURCES = "bee.gov.binding:granted_resources"
type Object = {[string]: unknown}
type Caller = {actor_id: string, workspace_id: string, definition_id: string}

-- The application behind an actor. The broker derives the principal ID and
-- metadata from its own launch values and applications cannot create actors,
-- so the workspace and definition here are authenticated.
function M.caller(actor_raw: unknown, meta_raw: unknown): (Caller?, string?)
    local meta = bounds.object(meta_raw)
    if type(actor_raw) ~= "string" or not meta then return nil, "caller is not an application" end
    local matched = (actor_raw :: string):match("^bee%.application:([0-9a-f]+):[^:]+$")
    local definition = bounds.id(meta.definition_id)
    if not matched or not definition then return nil, "caller is not an application" end
    local workspace: string = matched
    if #workspace ~= 32 or meta.workspace_id ~= workspace then return nil, "caller is not an application" end
    return {actor_id = actor_raw :: string, workspace_id = workspace, definition_id = definition}, nil
end

local function own(record_raw: unknown, caller_raw: unknown, live: unknown): ({unknown}?, string?)
    local record, caller = bounds.object(record_raw), bounds.object(caller_raw)
    if not record or not caller or live ~= true then return nil, "no live grant authorizes this caller" end
    if record.workspace_id ~= caller.workspace_id or record.application ~= caller.definition_id then
        return nil, "the grant belongs to another application or workspace"
    end
    local capabilities = record.capabilities
    if type(capabilities) ~= "table" then return nil, "the grant set is malformed" end
    return capabilities :: {unknown}, nil
end

local function contains(raw: unknown, value: string): boolean
    if type(raw) ~= "table" then return false end
    for _, item in ipairs(raw :: {unknown}) do if item == value then return true end end
    return false
end

-- Only the caller's own live grant for this exact binding and method passes.
function M.contract(record_raw: unknown, caller_raw: unknown, binding_raw: unknown, method_raw: unknown,
    live: unknown): (boolean?, string?)
    local capabilities, refusal = own(record_raw, caller_raw, live)
    if not capabilities then return nil, refusal end
    local binding = bounds.id(binding_raw)
    local method = type(method_raw) == "string" and (method_raw :: string):match("^[A-Za-z][A-Za-z0-9_]*$") or nil
    if not binding or not method then return nil, "contract call is malformed" end
    for _, raw_grant in ipairs(capabilities) do
        local grant = bounds.object(raw_grant)
        local scope = grant and bounds.object(grant.scope) or nil
        if grant and scope and grant.capability == "contract.call" and grant.operation == "contract.call"
            and grant.resource == binding and contains(scope.methods, method) then
            return true, nil
        end
    end
    return nil, "no grant covers binding " .. binding .. " method " .. method
end

-- The origin and path of an absolute HTTPS URL, refusing credentials,
-- traversal segments and encoded separators a server could reinterpret.
local function target(url_raw: unknown): (string?, string?)
    if type(url_raw) ~= "string" or #(url_raw :: string) > 2048 or (url_raw :: string):find("[%c%s\\]") then
        return nil, nil
    end
    local url = url_raw :: string
    local authority, rest = url:match("^https://([^/?#]+)(.*)$")
    if not authority or authority:find("@", 1, true) then return nil, nil end
    local named, port = authority:match("^([A-Za-z0-9.-]+):([0-9]+)$")
    if not named then named = authority:match("^[A-Za-z0-9.-]+$") end
    if not named then return nil, nil end
    local host: string = named
    local origin = "https://" .. host:lower() .. (port and port ~= "443" and ":" .. tostring(tonumber(port)) or "")
    local path: string = rest:match("^([^?#]*)") or ""
    if path == "" then path = "/" end
    local lowered = path:lower()
    if path:sub(1, 1) ~= "/" or path:find("//", 1, true) or lowered:find("%2e", 1, true)
        or lowered:find("%2f", 1, true) or lowered:find("%5c", 1, true) then
        return nil, nil
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil, nil end
    end
    return origin, path
end

local function under(path: string, prefix: string): boolean
    if prefix == "/" then return true end
    return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

local function http_grants(capabilities: {unknown}, origin: string, path: string): {Object}
    local matched: {Object} = {}
    for _, raw_grant in ipairs(capabilities) do
        local grant = bounds.object(raw_grant)
        local scope = grant and bounds.object(grant.scope) or nil
        local prefix = scope and scope.path_prefix or nil
        if grant and scope and grant.capability == "http.api" and grant.operation == "http.request"
            and grant.resource == origin and type(prefix) == "string" and under(path, prefix) then
            matched[#matched + 1] = scope
        end
    end
    return matched
end

-- Only the caller's own live grant for this origin, method and path prefix
-- passes.
function M.http(record_raw: unknown, caller_raw: unknown, method_raw: unknown, url_raw: unknown,
    live: unknown): (boolean?, string?)
    local capabilities, refusal = own(record_raw, caller_raw, live)
    if not capabilities then return nil, refusal end
    local method = type(method_raw) == "string" and (method_raw :: string):upper() or nil
    local origin, path = target(url_raw)
    if not method or not origin or not path then return nil, "HTTP request target is malformed" end
    for _, scope in ipairs(http_grants(capabilities, origin, path)) do
        if contains(scope.methods, method) then return true, nil end
    end
    return nil, "no grant covers " .. method .. " " .. origin .. path
end

-- Whether the URL a response arrived from stays under an approved origin and
-- path prefix of the record, whatever method a redirect used.
function M.located(record_raw: unknown, url_raw: unknown): (boolean?, string?)
    local record = bounds.object(record_raw)
    local capabilities = record and record.capabilities or nil
    local origin, path = target(url_raw)
    if type(capabilities) ~= "table" or not origin or not path then return nil, "response location is malformed" end
    if #http_grants(capabilities :: {unknown}, origin, path) > 0 then return true, nil end
    return nil, "response arrived from outside the approved origin and path"
end

return M
