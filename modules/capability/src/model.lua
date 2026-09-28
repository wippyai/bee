-- MIT. Shared capability interpretation for registry, resource and MCP
-- grants. The model compares authority; each owner keeps its own storage.
local M = {}
M.REVISION = "bee.capability-model@1"
local bounds = require("bounds")
type Value = {[string]: unknown}
type Parameter = string | {string}
type Parameters = {[string]: Parameter}
type Template = {id: string, revision: integer, confirm: string, parameters: {[string]: string},
    text: string, policies: {Value}, resources: {Value}}
type Vocabulary = {revision: integer, never: {[string]: boolean}, capabilities: {[string]: Template}}
type Grant = {capability: string, template_revision: integer, operation: string,
    resource: string, scope: Value, parameters: Value?}
type Revocation = {grants: {Grant}, fenced_attempts: {string}}

local function object(raw: unknown): Value?
    return bounds.object(raw)
end
local function fields(value: Value, allowed: {[string]: boolean}): boolean
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end
local function list(raw: unknown, maximum: integer): ({unknown}?, string?)
    return bounds.dense_list(raw, maximum, "capability values")
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
M.identity = identity
local KINDS: {[string]: boolean} = {relative_subpath = true, name = true, owned_scope = true,
    children_scope = true, definitions = true, methods = true, http_methods = true,
    https_origin = true, url_path_prefix = true, binding = true, contract = true,
    hive_operations = true, hive_mode = true, hive_audiences = true}
local HIVE_MODES: {[string]: boolean} = {open = true, policy = true}
local function collection_kind(kind: string): boolean
    return kind == "definitions" or kind == "methods" or kind == "http_methods"
        or kind == "hive_operations" or kind == "hive_audiences"
end

M.collection_kind = collection_kind

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
local function resource_template(raw: unknown, parameters: {[string]: string}): boolean
    if not word(raw, 160) then return false end
    local parameter = (raw :: string):match("^%$([a-z_]+)$")
    local kind = parameter and parameters[parameter] or nil
    return parameter == nil or (type(kind) == "string" and not collection_kind(kind))
end

local function decode_entry(raw: unknown): (Vocabulary?, string?)
    local entry = object(raw)
    local meta = entry and object(entry.meta) or nil
    local data = entry and object(entry.data) or nil
    if not entry then return nil, "host capability catalog is malformed: entry is not an object" end
    if entry.id ~= "bee:capability_catalog" then return nil, "host capability catalog is malformed: unexpected id " .. tostring(entry.id) end
    if entry.kind ~= "registry.entry" then return nil, "host capability catalog is malformed: unexpected kind " .. tostring(entry.kind) end
    if not meta or meta.type ~= "bee.capability_catalog" then return nil, "host capability catalog is malformed: unexpected metadata " .. tostring(meta and meta.type) end
    if not data then return nil, "host capability catalog is malformed: data is absent" end
    if not fields(data, {revision = true, never = true, capabilities = true}) then return nil, "host capability catalog is malformed: data has unknown fields" end
    if type(data.revision) ~= "number" or data.revision < 1 or data.revision ~= math.floor(data.revision) then
        return nil, "host capability catalog is malformed: invalid revision"
    end
    local body = data :: Value
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
                or not object(operation.scope) or not resource_template(operation.resource, schema)
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
            policies = policies :: {Value}, resources = resources :: {Value}}
    end
    return {revision = body.revision :: integer, never = never, capabilities = capabilities}, nil
end

function M.decode(raw: unknown): (Vocabulary?, string?)
    return decode_entry(raw)
end

function M.revisions(catalog: Vocabulary, id_raw: string): (integer?, integer?)
    local id = identity(id_raw)
    if not id then return nil, nil end
    local template = catalog.capabilities[id]
    if not template then return nil, nil end
    return catalog.revision, template.revision
end

function M.template(catalog: Vocabulary, id_raw: string): (Template?, string?)
    local id = identity(id_raw)
    if not id then return nil, "unknown capability or malformed parameters" end
    local template = catalog.capabilities[id]
    if not template then return nil, "unknown capability or malformed parameters" end
    return template, nil
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
local function string_set(raw: unknown): {string}?
    local rows = list(raw, 16)
    if not rows or #rows == 0 then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(rows) do
        local value = word(item, 160)
        if not value or seen[value] then return nil end
        result[#result + 1], seen[value] = value, true
    end
    table.sort(result)
    return result
end
local function set_values(raw: unknown, kind: string): {string}?
    local result = string_set(raw)
    if not result then return nil end
    for _, value in ipairs(result) do
        if kind == "http_methods" then
            if not ({GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true})[value] then return nil end
        elseif kind == "definitions" or kind == "methods" or kind == "hive_operations" then
            if kind == "methods" and not value:match("^[A-Za-z][A-Za-z0-9_]*$") then return nil end
            if kind ~= "methods" and not value:match("^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$") then return nil end
        end
    end
    return result
end
local function audience_list(raw: unknown): {string}?
    local result = string_set(raw)
    if not result then return nil end
    for _, value in ipairs(result) do
        if value ~= "*" and not value:match("^[a-z][a-z0-9_.-]*$") then return nil end
    end
    return result
end
local function parameter(raw: unknown, kind: string): Parameter?
    if kind == "relative_subpath" then return clean_path(raw, false) end
    if kind == "url_path_prefix" then return clean_path(raw, true) end
    if kind == "owned_scope" then return raw == "owned" and "owned" or nil end
    if kind == "children_scope" then return raw == "children" and "children" or nil end
    if kind == "hive_mode" then
        if type(raw) ~= "string" or not HIVE_MODES[raw] then return nil end
        return raw
    end
    if kind == "hive_audiences" then return audience_list(raw) end
    if kind == "definitions" or kind == "methods" or kind == "http_methods"
        or kind == "hive_operations" then return set_values(raw, kind) end
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

local function normalize_decoded(catalog: Vocabulary, id_raw: unknown, raw: unknown): (Parameters?, string?)
    local id = identity(id_raw)
    local template = id and catalog.capabilities[id] or nil
    local input = object(raw)
    if not template or not input then return nil, "unknown capability or malformed parameters" end
    local result: Parameters = {}
    for key in pairs(input) do if not template.parameters[key] then return nil, "unknown capability parameter" end end
    for key, kind in pairs(template.parameters) do
        local value = parameter(input[key], kind)
        if value == nil then return nil, "invalid capability parameter " .. key end
        result[key] = value
    end
    return result, nil
end

function M.normalize(catalog: Vocabulary, id_raw: string, raw: unknown): (Parameters?, string?)
    return normalize_decoded(catalog, id_raw, raw)
end

local function expand(raw: unknown, parameters: Parameters): unknown
    if type(raw) == "string" then
        local key = raw:match("^%$([a-z_]+)$")
        return key and parameters[key] or raw
    end
    local source = raw :: Value
    local result: Value = {}
    for key, value in pairs(source) do result[key] = expand(value, parameters) end
    return result
end

local function resolve_parameters(catalog: Vocabulary, id: string, parameters: Parameters): ({Grant}?, string?)
    local template = catalog.capabilities[id]
    if not template then return nil, "unknown capability or malformed parameters" end
    local result: {Grant} = {}
    for _, operation in ipairs(template.policies) do
        local resource = expand(operation.resource, parameters)
        local scope = expand(operation.scope, parameters)
        if type(resource) ~= "string" or type(scope) ~= "table" then
            return nil, "capability operation did not resolve to a grant"
        end
        result[#result + 1] = {capability = id, template_revision = template.revision,
            operation = operation.operation :: string, resource = resource,
            scope = scope :: Value, parameters = parameters}
    end
    return result, nil
end

function M.resolve_normalized(catalog: Vocabulary, id_raw: string, parameters: Parameters): ({Grant}?, string?)
    local id = identity(id_raw)
    if not id then return nil, "unknown capability or malformed parameters" end
    return resolve_parameters(catalog, id, parameters)
end

function M.resolve(catalog: Vocabulary, id_raw: string, raw: unknown): ({Grant}?, string?)
    local id = identity(id_raw)
    local parameters, normalize_error = normalize_decoded(catalog, id_raw, raw)
    if not id or not parameters then return nil, normalize_error end
    return resolve_parameters(catalog, id, parameters)
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
function M.render(catalog: Vocabulary, grants_raw: unknown): ({string}?, string?)
    local grants = list(grants_raw, 128)
    if not grants then return nil, "capability grants are malformed" end
    local lines: {string} = {}
    local reads: {string} = {}
    local egress: {string} = {}
    for _, raw in ipairs(grants) do
        local grant = object(raw)
        local id = grant and identity(grant.capability) or nil
        if not grant or not id then return nil, "capability grant meaning is unavailable" end
        local template = catalog.capabilities[id]
        if not template then return nil, "capability grant meaning is unavailable" end
        local params = normalize_decoded(catalog, id, grant.parameters)
        if not params or grant.template_revision ~= template.revision then
            return nil, "capability grant meaning is unavailable"
        end
        local expected, resolve_error = resolve_parameters(catalog, id, params)
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
        if id == "hive.expose" then egress[#egress + 1] = "Hive operations " .. printable(params.operations) .. " in " .. printable(params.mode) .. " mode" end
    end
    for _, source in ipairs(reads) do
        for _, destination in ipairs(egress) do
            lines[#lines + 1] = source .. " may be sent to " .. destination
        end
    end
    return lines, nil
end

type Change = {before: Grant?, after: Grant?}
type Diff = {added: {Change}, widened: {Change}, narrowed: {Change},
    removed: {Change}, changed: {Change}, requires_approval: boolean, revocation: Revocation}

local SCOPE_FIELDS: {[string]: boolean} = {subpath = true, path_prefix = true, methods = true,
    definitions = true, operations = true, traits = true, audiences = true, scope = true,
    name = true, access = true, workspace_id = true}
local SET_FIELDS: {[string]: boolean} = {methods = true, definitions = true, operations = true,
    traits = true, audiences = true}
local function valid_path(value: string, absolute: boolean): boolean
    return (value == "" and not absolute) or clean_path(value, absolute) == value
end
local function normalize_scope(raw: unknown): (Value?, string?)
    local scope = object(raw)
    if not scope then return nil, "resolved grant scope is malformed" end
    local copy: Value = {}
    for key, value in pairs(scope) do
        if not SCOPE_FIELDS[key] then return nil, "resolved grant scope is unknown" end
        if SET_FIELDS[key] then
            local values = string_set(value)
            if not values then return nil, "resolved grant set scope is malformed" end
            copy[key] = values
        elseif key == "access" then
            if value ~= "read" and value ~= "write" then return nil, "resolved grant access is malformed" end
            copy[key] = value
        else
            local text = key == "subpath" and type(value) == "string" and #value <= 160
                and not value:find("%c") and value or word(value, 160)
            if not text then return nil, "resolved grant scalar scope is malformed" end
            if key == "subpath" and not valid_path(text, false) then return nil, "resolved grant subpath is malformed" end
            if key == "path_prefix" and not valid_path(text, true) then return nil, "resolved grant path prefix is malformed" end
            copy[key] = text
        end
    end
    return copy, nil
end
local function normalize_grant(raw: unknown): (Grant?, string?)
    local item = object(raw)
    local scope = item and normalize_scope(item.scope) or nil
    if not item or not scope or not word(item.capability, 160) or not word(item.operation, 160)
        or not word(item.resource, 160) or type(item.template_revision) ~= "number"
        or item.template_revision < 1 or item.template_revision ~= math.floor(item.template_revision) then
        return nil, "resolved grant is malformed"
    end
    for key in pairs(item) do
        if key ~= "capability" and key ~= "template_revision" and key ~= "operation"
            and key ~= "resource" and key ~= "scope" and key ~= "parameters" then
            return nil, "resolved grant has an unknown field"
        end
    end
    local params = item.parameters == nil and nil or object(item.parameters)
    if item.parameters ~= nil and not params then return nil, "resolved grant parameters are malformed" end
    return {capability = item.capability :: string, template_revision = item.template_revision :: integer,
        operation = item.operation :: string, resource = item.resource :: string,
        scope = scope :: Value, parameters = params}, nil
end
local function path_contains(parent: string, child: string): boolean
    if parent == child or parent == "/" or parent == "." then return true end
    return child:sub(1, #parent + 1) == parent .. "/"
end
local function set_contains(parent: {string}, child: {string}): boolean
    local members: {[string]: boolean} = {}
    for _, value in ipairs(parent) do members[value] = true end
    for _, value in ipairs(child) do if not members[value] then return false end end
    return true
end
local function scope_contains(parent: Value, child: Value): boolean
    for key, value in pairs(parent) do
        local next_value = child[key]
        if next_value == nil then return false end
        if key == "subpath" or key == "path_prefix" then
            if not path_contains(value :: string, next_value :: string) then return false end
        elseif SET_FIELDS[key] then
            if not set_contains(value :: {string}, next_value :: {string}) then return false end
        elseif key == "access" then
            if value == "read" and next_value == "write" then return false end
        elseif value ~= next_value then return false end
    end
    for key in pairs(child) do if parent[key] == nil then return false end end
    return true
end
local function same_operation(left: Grant, right: Grant): boolean
    return left.operation == right.operation and left.resource == right.resource
end
local function same_meaning(left: Grant, right: Grant): boolean
    return same_operation(left, right) and left.capability == right.capability
        and left.template_revision == right.template_revision
end
local function covered(target: Grant, others: {Grant}): boolean
    for _, other in ipairs(others) do
        if same_meaning(target, other) and scope_contains(other.scope, target.scope) then return true end
    end
    local set_key: string? = nil
    for key in pairs(SET_FIELDS) do if target.scope[key] ~= nil then set_key = key; break end end
    if not set_key then return false end
    local members: {[string]: boolean} = {}
    for _, other in ipairs(others) do
        if same_meaning(target, other) and type(other.scope[set_key]) == "table" then
            local compatible = true
            for key, value in pairs(other.scope) do
                if key ~= set_key then
                    local target_value = target.scope[key]
                    if target_value == nil then compatible = false
                    elseif key == "subpath" or key == "path_prefix" then
                        if not path_contains(value :: string, target_value :: string) then compatible = false end
                    elseif key == "access" then
                        if value == "read" and target_value == "write" then compatible = false end
                    elseif value ~= target_value then compatible = false end
                end
            end
            for key in pairs(target.scope) do if key ~= set_key and other.scope[key] == nil then compatible = false end end
            if compatible then for _, value in ipairs(other.scope[set_key] :: {string}) do members[value] = true end end
        end
    end
    for _, value in ipairs(target.scope[set_key] :: {string}) do if not members[value] then return false end end
    return true
end
local function decode_grants(raw: unknown): ({Grant}?, string?)
    local rows, rows_error = list(raw, 128)
    if not rows then return nil, rows_error end
    local result: {Grant} = {}
    for _, value in ipairs(rows) do
        local grant, grant_error = normalize_grant(value)
        if not grant then return nil, grant_error end
        result[#result + 1] = grant
    end
    return result, nil
end

function M.scope_contains(parent_raw: unknown, child_raw: unknown): boolean
    local parent, parent_error = normalize_scope(parent_raw)
    local child, child_error = normalize_scope(child_raw)
    return parent_error == nil and child_error == nil and scope_contains(parent :: Value, child :: Value)
end
function M.contains(parent_raw: unknown, child_raw: unknown): boolean
    local parent = normalize_grant(parent_raw)
    local child = normalize_grant(child_raw)
    return parent ~= nil and child ~= nil and same_meaning(parent :: Grant, child :: Grant)
        and scope_contains((parent :: Grant).scope, (child :: Grant).scope)
end
function M.traits(resource_raw: unknown, traits_raw: unknown): (Value?, string?)
    local resource = word(resource_raw, 160)
    local traits = string_set(traits_raw)
    if not resource or not traits then return nil, "MCP capability scope is malformed" end
    return {capability = "mcp.access", template_revision = 1, operation = "mcp.traits",
        resource = resource, scope = {traits = traits}}, nil
end
function M.resource(workspace_raw: unknown, name_raw: unknown, subpath_raw: unknown, access_raw: unknown): (Value?, string?)
    local workspace, name = word(workspace_raw, 160), word(name_raw, 160)
    local subpath, access = subpath_raw, access_raw
    if not workspace or not name or type(subpath) ~= "string" or #subpath > 160 or subpath:find("%c")
        or (access ~= "read" and access ~= "write") then
        return nil, "resource capability scope is malformed"
    end
    local scope, scope_error = normalize_scope({workspace_id = workspace, name = name, subpath = subpath, access = access})
    if not scope then return nil, scope_error end
    return {capability = "workspace.resource", template_revision = 1, operation = "resource.access",
        resource = workspace, scope = scope}, nil
end
-- Revocation reports carry the removed capability meanings and unique live
-- attempt IDs. Each owner can report effects without sharing its ledger.
function M.revocation_report(grants_raw: unknown, attempts_raw: unknown): (Revocation?, string?)
    local grants, grant_error = decode_grants(grants_raw)
    local attempts, attempt_error = list(attempts_raw, 128)
    if not grants or not attempts then return nil, grant_error or attempt_error end
    local fenced: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(attempts) do
        local attempt = word(raw, 160)
        if not attempt then return nil, "revocation attempt is malformed" end
        if not seen[attempt] then seen[attempt] = true; fenced[#fenced + 1] = attempt end
    end
    table.sort(fenced)
    return {grants = grants, fenced_attempts = fenced}, nil
end
function M.compare(installed_raw: unknown, proposed_raw: unknown): (Diff?, string?)
    local installed, old_error = decode_grants(installed_raw)
    local proposed, new_error = decode_grants(proposed_raw)
    if not installed or not proposed then return nil, old_error or new_error end
    local diff: Diff = {added = {}, widened = {}, narrowed = {}, removed = {}, changed = {},
        requires_approval = false, revocation = {grants = {}, fenced_attempts = {}}}
    local changed_pairs: {[integer]: boolean} = {}
    for _, next_grant in ipairs(proposed) do
        if not covered(next_grant, installed) then
            local changed_index: integer? = nil
            local widened_index: integer? = nil
            for old_index, old_grant in ipairs(installed) do
                if same_operation(old_grant, next_grant) then
                    if not same_meaning(old_grant, next_grant) and not changed_pairs[old_index] then
                        changed_index = old_index; break
                    elseif same_meaning(old_grant, next_grant) and scope_contains(next_grant.scope, old_grant.scope) then
                        widened_index = old_index
                    end
                end
            end
            if changed_index then
                changed_pairs[changed_index] = true
                diff.changed[#diff.changed + 1] = {before = installed[changed_index], after = next_grant}
            elseif widened_index then
                diff.widened[#diff.widened + 1] = {before = installed[widened_index], after = next_grant}
            else
                diff.added[#diff.added + 1] = {after = next_grant}
            end
        end
    end
    local revoked: {Grant} = {}
    for index, old_grant in ipairs(installed) do
        if not covered(old_grant, proposed) then
            local narrower: Grant? = nil
            for _, next_grant in ipairs(proposed) do
                if same_meaning(old_grant, next_grant) and scope_contains(old_grant.scope, next_grant.scope) then
                    narrower = next_grant; break
                end
            end
            if narrower then diff.narrowed[#diff.narrowed + 1] = {before = old_grant, after = narrower}
            else diff.removed[#diff.removed + 1] = {before = old_grant} end
            revoked[#revoked + 1] = old_grant
        end
    end
    diff.requires_approval = #diff.added > 0 or #diff.widened > 0 or #diff.changed > 0
    local report, report_error = M.revocation_report(revoked, {})
    if not report then return nil, report_error end
    diff.revocation = report
    return diff, nil
end
M.strings = string_set
return M
