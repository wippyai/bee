-- MIT. Pure decoder for host-owned capability vocabulary. Templates describe
-- possible grants; this module neither installs nor authorizes any of them.
local M = {}
type Object = {[string]: unknown}
type Template = {id: string, revision: integer, confirm: string, parameters: {[string]: string},
    text: string, policies: {Object}, resources: {Object}}
type Catalog = {revision: integer, never: {[string]: boolean}, capabilities: {[string]: Template}}

local function object(raw: unknown): Object?
    if type(raw) ~= "table" then return nil end
    for key in pairs(raw :: table) do if type(key) ~= "string" then return nil end end
    return raw :: Object
end
local function fields(value: Object, allowed: {[string]: boolean}): boolean
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end
local function list(raw: unknown, maximum: integer): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, "expected a list" end
    local count = 0
    for key in pairs(raw :: table) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "expected a dense list" end
        count = count + 1
    end
    if count > maximum then return nil, "list exceeds bound" end
    local capacity: integer = count > 0 and count or 1
    local result: {unknown} = table.create(capacity, 0)
    for index = 1, count do
        local value = (raw :: table)[index]
        if value == nil then return nil, "expected a dense list" end
        result[index] = value
    end
    return result, nil
end
local function word(raw: unknown, maximum: integer): string?
    if type(raw) ~= "string" or #raw == 0 or #raw > maximum or raw:find("%c") then return nil end
    return raw
end
local function identity(raw: unknown): string?
    local value = word(raw, 160)
    if not value or not value:match("^[a-z][a-z0-9_.-]*$") then return nil end
    return value
end
local KINDS: {[string]: boolean} = {relative_subpath = true, name = true, owned_scope = true,
    children_scope = true, definitions = true, methods = true, http_methods = true,
    https_origin = true, url_path_prefix = true, binding = true, contract = true}

local function template_value(raw: unknown, parameters: {[string]: string}): boolean
    if type(raw) == "string" then
        local parameter = raw:match("^%$([a-z_]+)$")
        return parameter == nil or parameters[parameter] ~= nil
    end
    local value = object(raw)
    if not value then return false end
    for _, child in pairs(value) do if not template_value(child, parameters) then return false end end
    return true
end

function M.decode(raw: unknown): (Catalog?, string?)
    local entry = object(raw)
    local meta = entry and object(entry.meta) or nil
    local data = entry and object(entry.data) or nil
    if not entry or entry.id ~= "bee:capability_catalog" or entry.kind ~= "registry.entry"
        or not meta or meta.type ~= "bee.capability_catalog" or not data
        or not fields(data, {revision = true, never = true, capabilities = true})
        or type(data.revision) ~= "number" or data.revision < 1 or data.revision ~= math.floor(data.revision) then
        return nil, "host capability catalog is malformed"
    end
    local body = data :: Object
    local never_rows = list(body.never, 64)
    local rows = list(body.capabilities, 32)
    if not never_rows or not rows or #rows == 0 then return nil, "host capability catalog lists are malformed" end
    local never: {[string]: boolean} = {}
    for _, raw_name in ipairs(never_rows) do
        local name = identity(raw_name)
        if not name or never[name] then return nil, "host never-list is malformed" end
        never[name] = true
    end
    local capabilities: {[string]: Template} = {}
    for _, raw_row in ipairs(rows) do
        local row = object(raw_row)
        local id = row and identity(row.id) or nil
        local params = row and object(row.parameters) or nil
        local policies = row and list(row.policies, 8) or nil
        local resources = row and list(row.resources, 8) or nil
        if not row or not id or never[id] or capabilities[id] or not params or not policies or #policies == 0
            or not resources or not fields(row, {id = true, revision = true, confirm = true,
                parameters = true, text = true, policies = true, resources = true})
            or type(row.revision) ~= "number" or row.revision < 1 or row.revision ~= math.floor(row.revision)
            or (row.confirm ~= "standard" and row.confirm ~= "explicit") or not word(row.text, 512) then
            return nil, "capability template is malformed"
        end
        local schema: {[string]: string} = {}
        local parameter_count = 0
        for key, kind in pairs(params) do
            if not identity(key) or type(kind) ~= "string" or not KINDS[kind] then
                return nil, "capability parameter schema is malformed"
            end
            schema[key] = kind
            parameter_count = parameter_count + 1
        end
        if parameter_count > 8 then return nil, "capability parameter schema exceeds bound" end
        for _, raw_operation in ipairs(policies) do
            local operation = object(raw_operation)
            if not operation or not fields(operation, {operation = true, resource = true, scope = true})
                or not identity(operation.operation) or not word(operation.resource, 160)
                or not object(operation.scope) or not template_value(operation.resource, schema)
                or not template_value(operation.scope, schema) then
                return nil, "capability operation template is malformed"
            end
        end
        for _, raw_resource in ipairs(resources) do
            local resource = object(raw_resource)
            if not resource or not fields(resource, {kind = true, mode = true, source = true})
                or not identity(resource.kind) or not word(resource.mode, 80)
                or (resource.source ~= nil and not word(resource.source, 160)) then
                return nil, "capability resource template is malformed"
            end
        end
        for placeholder in (row.text :: string):gmatch("{([a-z_]+)}") do
            if not schema[placeholder] then return nil, "capability text refers to an unknown parameter" end
        end
        capabilities[id] = {id = id, revision = row.revision :: integer,
            confirm = row.confirm :: string, parameters = schema, text = row.text :: string,
            policies = policies :: {Object}, resources = resources :: {Object}}
    end
    return {revision = body.revision :: integer, never = never, capabilities = capabilities}, nil
end

local function clean_path(raw: unknown, absolute: boolean): string?
    local value = word(raw, 160)
    if not value or value:find("\\", 1, true) or value:find("//", 1, true) then return nil end
    if not absolute and value == "." then return value end
    if absolute and value:sub(1, 1) ~= "/" then return nil end
    if not absolute and value:sub(1, 1) == "/" then return nil end
    if #value > 1 and value:sub(-1) == "/" then value = value:sub(1, -2) end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." or not segment:match("^[A-Za-z0-9_.-]+$") then return nil end
    end
    return value
end
local function set_values(raw: unknown, kind: string): {string}?
    local rows = list(raw, 16)
    if not rows or #rows == 0 then return nil end
    local seen: {[string]: boolean} = {}
    local result: {string} = {}
    for _, item in ipairs(rows) do
        local value = word(item, 160)
        if not value or seen[value] then return nil end
        if kind == "http_methods" then
            if not ({GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true})[value] then return nil end
        elseif kind == "definitions" or kind == "methods" then
            if kind == "definitions" and not value:match("^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$") then return nil end
            if kind == "methods" and not value:match("^[A-Za-z][A-Za-z0-9_]*$") then return nil end
        end
        seen[value] = true
        result[#result + 1] = value
    end
    table.sort(result)
    return result
end
local function parameter(raw: unknown, kind: string): unknown?
    if kind == "relative_subpath" then return clean_path(raw, false) end
    if kind == "url_path_prefix" then return clean_path(raw, true) end
    if kind == "owned_scope" then return raw == "owned" and "owned" or nil end
    if kind == "children_scope" then return raw == "children" and "children" or nil end
    if kind == "definitions" or kind == "methods" or kind == "http_methods" then return set_values(raw, kind) end
    local value = word(raw, 160)
    if not value then return nil end
    if kind == "https_origin" then
        local authority = value:match("^https://(.+)$")
        if not authority then return nil end
        local host, port = authority:match("^([A-Za-z0-9.-]+):([0-9]+)$")
        if not host then host = authority end
        if not host:match("^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$")
            or host:find("..", 1, true) or (port and (#port > 5 or tonumber(port) == 0
                or tonumber(port) > 65535)) then return nil end
        value = "https://" .. host:lower() .. (port and port ~= "443" and ":" .. tostring(tonumber(port)) or "")
    elseif kind == "name" then
        if not value:match("^[A-Za-z][A-Za-z0-9_]*$") then return nil end
    elseif kind == "binding" or kind == "contract" then
        if not value:match("^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$") then return nil end
    end
    return value
end

function M.normalize(catalog: Catalog, id_raw: unknown, raw: unknown): (Object?, string?)
    local id = identity(id_raw)
    local template = id and catalog.capabilities[id] or nil
    local input = object(raw)
    if not template or not input then return nil, "unknown capability or malformed parameters" end
    local result: Object = {}
    for key in pairs(input) do if not template.parameters[key] then return nil, "unknown capability parameter" end end
    for key, kind in pairs(template.parameters) do
        local value = parameter(input[key], kind)
        if value == nil then return nil, "invalid capability parameter " .. key end
        result[key] = value
    end
    return result, nil
end

local function expand(raw: unknown, parameters: Object): unknown
    if type(raw) == "string" then
        local key = raw:match("^%$([a-z_]+)$")
        return key and parameters[key] or raw
    end
    local source = raw :: Object
    local result: Object = {}
    for key, value in pairs(source) do result[key] = expand(value, parameters) end
    return result
end

function M.resolve(catalog: Catalog, id_raw: unknown, raw: unknown): ({Object}?, string?)
    local id = identity(id_raw)
    local template = id and catalog.capabilities[id] or nil
    local parameters, error_message = M.normalize(catalog, id_raw, raw)
    if not template or not parameters then return nil, error_message end
    local result: {Object} = {}
    for _, operation in ipairs(template.policies) do
        result[#result + 1] = {capability = id, template_revision = template.revision,
            operation = operation.operation, resource = expand(operation.resource, parameters),
            scope = expand(operation.scope, parameters), parameters = parameters}
    end
    return result, nil
end

local function printable(value: unknown): string
    if type(value) == "table" then return table.concat(value :: {string}, ", ") end
    return tostring(value)
end
local function equal(left: unknown, right: unknown, depth: integer): boolean
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    if depth > 8 then return false end
    for key, value in pairs(left :: table) do
        if not equal(value, (right :: table)[key], depth + 1) then return false end
    end
    for key in pairs(right :: table) do
        if (left :: table)[key] == nil then return false end
    end
    return true
end
function M.render(catalog: Catalog, grants_raw: unknown): ({string}?, string?)
    local grants = list(grants_raw, 128)
    if not grants then return nil, "capability grants are malformed" end
    local lines: {string} = {}
    local reads: {string} = {}
    local egress: {string} = {}
    for _, raw in ipairs(grants) do
        local grant = object(raw)
        local id = grant and identity(grant.capability) or nil
        local template = id and catalog.capabilities[id] or nil
        local params = grant and M.normalize(catalog, id, grant.parameters) or nil
        if not template or not params or grant.template_revision ~= template.revision then
            return nil, "capability grant meaning is unavailable"
        end
        local expected, resolve_error = M.resolve(catalog, id, params)
        if not expected then return nil, resolve_error end
        local found = false
        for _, operation in ipairs(expected) do
            if operation.operation == grant.operation and operation.resource == grant.resource
                and equal(operation.scope, grant.scope, 0) then found = true; break end
        end
        if not found then return nil, "capability grant differs from its host template" end
        local rendered = template.text:gsub("{([a-z_]+)}", function(key: string): string
            return printable(params[key])
        end)
        lines[#lines + 1] = rendered
        if id == "workspace.files.read" then reads[#reads + 1] = "Workspace files under " .. printable(params.subpath) end
        if id == "threads.read" then reads[#reads + 1] = "Owned thread content" end
        if id == "app.database" then reads[#reads + 1] = "Application database " .. printable(params.name) end
        if id == "http.api" then egress[#egress + 1] = printable(params.origin) end
        if id == "contract.call" then egress[#egress + 1] = "app binding " .. printable(params.binding) end
        if id == "hive.expose" then egress[#egress + 1] = "Hive contract " .. printable(params.contract) end
    end
    for _, source in ipairs(reads) do
        for _, destination in ipairs(egress) do
            lines[#lines + 1] = source .. " may be sent to " .. destination
        end
    end
    return lines, nil
end
return M
