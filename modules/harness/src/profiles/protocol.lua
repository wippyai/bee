local bounds = require("bounds")
local budgets = require("budgets")
local canonical = require("canonical")
local json = require("json")
local M = {}
M.SCHEMA = "bee.agent-profile@2"
M.MAX_OPTIONS = 64
type Object = {[string]: unknown}
type Workdir = {root_ref: string, path: string}
type Thread = {thread_id: string}
type EnvValue = {kind: "literal", value: string} | {kind: "credential", credential_ref: string}
type Provider = {model: string?, effort: string?, permission_mode: string?, tool_allow: {string}?, tool_deny: {string}?,
    system_prompt_append: string?, env: {[string]: EnvValue}?, options: Object?}
type Scope = {workspace_id: string?, name: string?, access: "read" | "write"?, subpath: string?, path_prefix: string?, scope: string?,
    methods: {string}?, definitions: {string}?, operations: {string}?, traits: {string}?, audiences: {string}?}
type Mcp = {tool: string, scope: Scope}
type File = {workspace_id: string, resource: string, subpath: string, access: "read" | "write"}
type Workspace = {workspace_id: string, operations: {string}}
type Bee = {mcp: {Mcp}?, files: {File}?, workspaces: {Workspace}?, credential_refs: {string}?, approval_leases: {string}?, permission_answers: "provider" | "ask" | "deny"?}
type Placement = {kind: "native", home: "private" | "machine"} | {kind: "docker", profile_ref: string, overrides: Object?}
type Profile = {schema_revision: string, definition_ref: string, driver_binding_ref: string, name: string,
    provider: Provider, bee: Bee, placement: Placement?, presentation: "headless" | "window"?, budgets: budgets.Budgets?, supervision: budgets.Supervision?,
    workdir: Workdir?, thread: Thread?, agent_ref: string?, owner_component_revision: integer?, spec_digest: string?}
type Request = {operation: string, workspace_id: string, profile_id: string, profile: Profile?, expected_revision: integer,
    idempotency_key: string, after_key: string, expected_cursor: integer?, limit: integer, definition_ref: string?, query: string?, sort: string?}
local function strings(value: unknown, label: string): ({string}?, string?)
    local rows, err = bounds.array(value, 64)
    if not rows then return nil, err end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local text = bounds.line(raw, 512)
        if not text or text == "" or seen[text] then return nil, label .. " must contain unique bounded strings" end
        seen[text] = true; result[#result + 1] = text
    end
    return result, nil
end
local function scope(value: unknown): (Scope?, string?)
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"workspace_id", "name", "access", "subpath", "path_prefix", "scope", "methods", "definitions", "operations", "traits", "audiences"}) then return nil, "invalid MCP scope" end
    local result: Scope = {}
    for _, field in ipairs({"workspace_id", "name", "scope", "path_prefix"}) do
        if raw[field] ~= nil then
            local text = bounds.line(raw[field], 512)
            if not text or text == "" then return nil, "scope." .. field .. " must be bounded text" end
            if field == "workspace_id" then result.workspace_id = text
            elseif field == "name" then result.name = text
            elseif field == "scope" then result.scope = text else result.path_prefix = text end
        end
    end
    if raw.subpath ~= nil then
        local path, err = bounds.subpath(raw.subpath)
        if not path then return nil, err end
        result.subpath = path
    end
    if raw.access == "read" then result.access = "read"
    elseif raw.access == "write" then result.access = "write"
    elseif raw.access ~= nil then return nil, "scope.access must be read or write" end
    for _, field in ipairs({"methods", "definitions", "operations", "traits", "audiences"}) do
        if raw[field] ~= nil then
            local list, err = strings(raw[field], "scope." .. field)
            if not list then return nil, err end
            if field == "methods" then result.methods = list
            elseif field == "definitions" then result.definitions = list
            elseif field == "operations" then result.operations = list
            elseif field == "traits" then result.traits = list else result.audiences = list end
        end
    end
    return result, nil
end
function M.provider(value: unknown): (Provider?, string?)
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"model", "effort", "permission_mode", "tool_allow", "tool_deny", "system_prompt_append", "env", "options"}) then return nil, "provider has undeclared named fields" end
    local result: Provider = {}
    for _, field in ipairs({"model", "effort", "permission_mode"}) do
        if raw[field] ~= nil then
            local text = bounds.line(raw[field], 512)
            if not text or text == "" then return nil, "provider." .. field .. " must be bounded text" end
            if field == "model" then result.model = text elseif field == "effort" then result.effort = text else result.permission_mode = text end
        end
    end
    for _, field in ipairs({"tool_allow", "tool_deny"}) do
        if raw[field] ~= nil then
            local list, err = strings(raw[field], "provider." .. field)
            if not list then return nil, err end
            if field == "tool_allow" then result.tool_allow = list else result.tool_deny = list end
        end
    end
    if raw.system_prompt_append ~= nil then
        local text = bounds.text(raw.system_prompt_append, 4096)
        if not text or text:find("[%z\1-\8\11\12\14-\31\127]") then return nil, "provider.system_prompt_append must be bounded prompt text" end
        result.system_prompt_append = text
    end
    if raw.env ~= nil then
        local env = bounds.object(raw.env)
        if not env then return nil, "provider.env must be an object" end
        local values: {[string]: EnvValue} = {}
        local count = 0
        for name, value in pairs(env) do
            count = count + 1
            if count > 64 or not name:match("^[A-Z][A-Z0-9_]*$") or name:match("^BEE_") or name == "HOME" or name == "PATH" or name:match("_HOME$") then return nil, "provider.env has a reserved or invalid name" end
            local item = bounds.object(value)
            if not item then return nil, "provider.env." .. name .. " must be a typed value" end
            if item.kind == "literal" and not bounds.fields(item, {"kind", "value"}) then
                local text = bounds.text(item.value, 4096)
                if not text or text:find("%z") then return nil, "invalid environment literal" end
                values[name] = {kind = "literal", value = text}
            elseif item.kind == "credential" and not bounds.fields(item, {"kind", "credential_ref"}) then
                local ref = bounds.id(item.credential_ref)
                if not ref then return nil, "invalid environment credential reference" end
                values[name] = {kind = "credential", credential_ref = ref}
            else return nil, "environment values must be literal or credential" end
        end
        result.env = values
    end
    if raw.options ~= nil then
        local options = bounds.object(raw.options)
        local encoded = options and canonical.encode(options)
        if not options or not encoded or #encoded > 8192 then return nil, "provider.options must be bounded JSON" end
        local count = 0
        for name in pairs(options) do
            count = count + 1
            if count > M.MAX_OPTIONS or not name:match("^[a-z][a-z0-9_]*$") or bounds.member(name, {"model", "effort", "permission_mode", "tool_allow", "tool_deny", "system_prompt_append", "env"}) then return nil, "provider.options repeats or invalidates a named field" end
        end
        local decoded, decode_error = json.decode(encoded)
        local copied = bounds.object(decoded)
        if decode_error or not copied then return nil, "provider.options must be JSON" end
        result.options = copied
    end
    return result, nil
end
function M.bee(value: unknown): (Bee?, string?)
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"mcp", "files", "workspaces", "credential_refs", "approval_leases", "permission_answers"}) then return nil, "bee has unknown fields" end
    local result: Bee = {}
    if raw.permission_answers == "provider" then result.permission_answers = "provider"
    elseif raw.permission_answers == "ask" then result.permission_answers = "ask"
    elseif raw.permission_answers == "deny" then result.permission_answers = "deny"
    elseif raw.permission_answers ~= nil then return nil, "bee.permission_answers must be provider, ask or deny" end
    for _, field in ipairs({"credential_refs", "approval_leases"}) do
        if raw[field] ~= nil then
            local list, err = bounds.ids(raw[field], true)
            if not list then return nil, err end
            if field == "credential_refs" then result.credential_refs = list else result.approval_leases = list end
        end
    end
    if raw.mcp ~= nil then
        local list, err = bounds.array(raw.mcp, 64)
        if not list then return nil, err end
        local items: {Mcp} = {}
        local seen: {[string]: boolean} = {}
        for _, value in ipairs(list) do
            local item = bounds.object(value)
            local tool = item and bounds.id(item.tool)
            if not item or not tool or bounds.fields(item, {"tool", "scope"}) then return nil, "bee.mcp must name tool and scope" end
            if seen[tool] then return nil, "Duplicate MCP tool " .. tool end
            seen[tool] = true
            local selected, scope_error = scope(item.scope)
            if not selected then return nil, scope_error end
            items[#items + 1] = {tool = tool, scope = selected}
        end
        result.mcp = items
    end
    if raw.files ~= nil then
        local list, err = bounds.array(raw.files, 64)
        if not list then return nil, err end
        local items: {File} = {}
        for _, value in ipairs(list) do
            local item = bounds.object(value)
            local workspace = item and bounds.id(item.workspace_id)
            local resource = item and bounds.id(item.resource)
            local path = item and bounds.subpath(item.subpath)
            if not item or not workspace or not resource or not path or bounds.fields(item, {"workspace_id", "resource", "subpath", "access"}) then return nil, "invalid bee.files grant" end
            local access: "read" | "write"
            if item.access == "read" then access = "read" elseif item.access == "write" then access = "write" else return nil, "file access must be read or write" end
            items[#items + 1] = {workspace_id = workspace, resource = resource, subpath = path, access = access}
        end
        result.files = items
    end
    if raw.workspaces ~= nil then
        local list, err = bounds.array(raw.workspaces, 64)
        if not list then return nil, err end
        local items: {Workspace} = {}
        for _, value in ipairs(list) do
            local item = bounds.object(value)
            local workspace = item and bounds.id(item.workspace_id)
            local operations = item and strings(item.operations, "workspace.operations")
            if not item or not workspace or not operations or bounds.fields(item, {"workspace_id", "operations"}) then return nil, "invalid bee.workspaces grant" end
            items[#items + 1] = {workspace_id = workspace, operations = operations}
        end
        result.workspaces = items
    end
    return result, nil
end
function M.placement(value: unknown): (Placement?, string?)
    if value == nil then return nil, nil end
    local placement = bounds.object(value)
    if not placement then return nil, "placement must be native or docker" end
    if placement.kind == "native" and not bounds.fields(placement, {"kind", "home"}) then
        if placement.home == "private" then return {kind = "native", home = "private"}
        elseif placement.home == "machine" then return {kind = "native", home = "machine"}
        else return nil, "placement.home must be private or machine" end
    elseif placement.kind == "docker" and not bounds.fields(placement, {"kind", "profile_ref", "overrides"}) then
        local ref = bounds.id(placement.profile_ref)
        if not ref then return nil, "Docker placement requires profile_ref" end
        local overrides = placement.overrides ~= nil and bounds.object(placement.overrides) or nil
        if placement.overrides ~= nil and not overrides then return nil, "Docker overrides must be an object" end
        if overrides and bounds.fields(overrides, {"image", "user", "network_policy_ref", "limits", "mounts", "tmpfs", "working_directory", "environment_policy_ref"}) then return nil, "Docker overrides has unknown fields" end
        if overrides then
            local encoded = canonical.encode(overrides, 8192, 8)
            if not encoded then return nil, "Docker overrides exceed the JSON bound" end
            local decoded, decode_error = json.decode(encoded)
            overrides = bounds.object(decoded)
            if decode_error or not overrides then return nil, "Docker overrides must be JSON" end
        end
        return {kind = "docker", profile_ref = ref, overrides = overrides}
    else return nil, "placement must be native or docker" end

end
function M.profile(value: unknown): (Profile?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "profile must be an object" end
    local extra = bounds.fields(raw, {"schema_revision", "definition_ref", "driver_binding_ref", "name", "provider", "bee", "placement", "presentation", "budgets", "supervision", "workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest"})
    if extra then return nil, extra end
    if raw.schema_revision ~= M.SCHEMA then return nil, "profile.schema_revision must be " .. M.SCHEMA end
    local definition, driver, name = bounds.id(raw.definition_ref), bounds.id(raw.driver_binding_ref), bounds.line(raw.name, 80)
    if not definition or not driver or not name or name:match("^%s*$") then return nil, "profile requires definition_ref, driver_binding_ref and name" end
    local provider, provider_error = M.provider(raw.provider)
    if not provider then return nil, provider_error end
    local bee, bee_error = M.bee(raw.bee)
    if not bee then return nil, bee_error end
    local limits, limit_error = budgets.budgets(raw.budgets)
    if limit_error then return nil, limit_error end
    local supervision, supervision_error = budgets.supervision(raw.supervision)
    if supervision_error then return nil, supervision_error end
    local result: Profile = {schema_revision = M.SCHEMA, definition_ref = definition, driver_binding_ref = driver, name = name, provider = provider, bee = bee, budgets = limits, supervision = supervision}
    if raw.presentation == "headless" then result.presentation = "headless"
    elseif raw.presentation == "window" then result.presentation = "window"
    elseif raw.presentation ~= nil then return nil, "presentation must be headless or window" end
    local placement, placement_error = M.placement(raw.placement)
    if placement_error then return nil, placement_error end
    result.placement = placement
    if raw.workdir ~= nil then
        local item = bounds.object(raw.workdir)
        local root = item and bounds.id(item.root_ref)
        local path = item and bounds.subpath(item.path)
        if not item or not root or not path or bounds.fields(item, {"root_ref", "path"}) then return nil, "invalid profile.workdir" end
        result.workdir = {root_ref = root, path = path}
    end
    if raw.thread ~= nil then
        local item = bounds.object(raw.thread)
        local id = item and bounds.id(item.thread_id)
        if not item or not id or bounds.fields(item, {"thread_id"}) then return nil, "invalid profile.thread" end
        result.thread = {thread_id = id}
    end
    if raw.agent_ref ~= nil then
        local ref = bounds.id(raw.agent_ref)
        if not ref then return nil, "agent_ref must be an identifier" end
        result.agent_ref = ref
    end
    if raw.owner_component_revision ~= nil then
        local revision = bounds.count(raw.owner_component_revision)
        if not revision or revision < 1 then return nil, "owner_component_revision must be a positive integer" end
        result.owner_component_revision = revision
    end
    if raw.spec_digest ~= nil then
        local digest = bounds.line(raw.spec_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "spec_digest must be a lowercase SHA-256 hex digest" end
        result.spec_digest = digest
    end
    return result, nil
end

type LaunchPreferences = {docker_overrides: Object?, home: "private" | "machine"?, bee: {permission_answers: string?}?, options: {[string]: string | number | boolean}, mcp_tools: {string}, instructions: string}
function M.preferences(profile: Profile): (LaunchPreferences?, string?)
    local provider = profile.provider
    local options: {[string]: string | number | boolean} = {}
    for name, value in pairs(provider.options or {}) do
        if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then return nil, "provider.options." .. name .. " requires a descriptor render for structured values" end
        options[name] = value
    end
    if provider.model then options.model = provider.model end
    if provider.effort then options.effort = provider.effort end
    if provider.permission_mode then options.permission_mode = provider.permission_mode end
    if provider.tool_allow or provider.tool_deny or provider.env then return nil, "Provider tool rules and environment require an admitted descriptor render" end
    local bee = profile.bee
    for _, field in ipairs({"files", "workspaces", "credential_refs", "approval_leases"}) do
        local values = bee[field]
        if values and #values > 0 then return nil, "bee." .. field .. " requires an exact host grant" end
    end
    local tools: {string} = {}
    for _, item in ipairs(bee.mcp or {}) do
        if next(item.scope) then return nil, "bee.mcp." .. item.tool .. " requests an unsupported scope" end
        tools[#tools + 1] = item.tool
    end
    local home: "private" | "machine"? = nil
    if profile.placement and profile.placement.kind == "native" then home = profile.placement.home end
    local overrides = profile.placement and profile.placement.kind == "docker" and profile.placement.overrides or nil
    return {docker_overrides = overrides, home = home, bee = {permission_answers = bee.permission_answers}, options = options, mcp_tools = tools,
        instructions = provider.system_prompt_append or ""}, nil
end
function M.agent_preferences(profile: Profile, tool_names: {string}): (LaunchPreferences?, string?)
    if profile.provider.model then return nil, "option model is owned by the host agent model mapping" end
    local selected, err = M.preferences(profile)
    if not selected then return nil, err end
    local admitted: {[string]: boolean} = {}
    for _, name in ipairs(tool_names) do admitted[name] = true end
    for _, name in ipairs(selected.mcp_tools) do
        if not admitted[name] then return nil, "MCP tool " .. name .. " is outside the admitted agent" end
    end
    return selected, nil
end

function M.decode(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local operation = bounds.member(object.operation, {"get", "list", "put", "remove"})
    if not operation then return nil, "unknown profile operation" end
    local fields: {string}
    if operation == "get" then fields = {"operation", "workspace_id", "profile_id"}
    elseif operation == "list" then fields = {"operation", "workspace_id", "after_key", "expected_cursor", "limit", "definition_ref", "query", "sort"}
    elseif operation == "put" then fields = {"operation", "workspace_id", "profile_id", "expected_revision", "idempotency_key", "profile"}
    elseif operation == "remove" then fields = {"operation", "workspace_id", "profile_id", "expected_revision", "idempotency_key"}
    else return nil, "unknown profile operation" end
    local extra = bounds.fields(object, fields)
    if extra then return nil, extra end
    local workspace = bounds.id(object.workspace_id)
    if not workspace then return nil, "workspace_id must be an identifier" end
    local request: Request = {operation = operation, workspace_id = workspace, profile_id = "", expected_revision = 0, idempotency_key = "", after_key = "", limit = 32}
    if operation == "list" then
        request.definition_ref = bounds.id(object.definition_ref)
        if object.definition_ref ~= nil and not request.definition_ref then return nil, "definition_ref must be an identifier" end
        request.query = bounds.line(object.query, 80)
        if object.query ~= nil and not request.query then return nil, "query must be bounded text" end
        request.sort = object.sort == nil and "name" or bounds.member(object.sort, {"name", "driver"})
        if not request.sort then return nil, "sort must be name or driver" end
        local after_key = object.after_key == nil and "" or object.after_key
        if after_key ~= "" and not bounds.id(after_key) then return nil, "after_key must be an identifier" end
        local cursor = bounds.count(object.expected_cursor)
        local limit = bounds.count(object.limit == nil and 32 or object.limit)
        if object.expected_cursor ~= nil and not cursor then return nil, "expected_cursor must be a nonnegative safe integer" end
        if after_key ~= "" and not cursor then return nil, "continuation requires expected_cursor" end
        if not limit or limit < 1 or limit > 64 then return nil, "limit must be between 1 and 64" end
        request.after_key = after_key
        request.expected_cursor = cursor
        request.limit = limit
        return request, nil
    end
    local id = bounds.id(object.profile_id)
    if not id then return nil, "profile_id must be an identifier" end
    request.profile_id = id
    if operation == "get" then return request, nil end
    local revision = bounds.count(object.expected_revision)
    local key = bounds.id(object.idempotency_key)
    if not revision then return nil, "expected_revision must be a nonnegative safe integer" end
    if not key then return nil, "idempotency_key must be an identifier" end
    request.expected_revision = revision
    request.idempotency_key = key
    if operation == "put" then
        local profile, profile_error = M.profile(object.profile)
        if not profile then return nil, profile_error end
        request.profile = profile
    end
    return request, nil
end
return M
