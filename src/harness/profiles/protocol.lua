local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local access = require("access")
local M = {}
M.SCHEMA = "bee.agent-profile@3"
M.PRIOR = "bee.agent-profile@2"
M.RETIRED = {"presentation", "budgets", "supervision"}
M.MAX_OPTIONS = 64
type Context = {[string]: string | number | boolean}
type Object = {[string]: unknown}
type Workdir = {root_ref: string, path: string}
type Thread = {thread_id: string}
type EnvValue = {kind: "literal", value: string} | {kind: "credential", credential_ref: string}
type Provider = {model: string?, effort: string?, permission_mode: string?, tool_allow: {string}?, tool_deny: {string}?,
    system_prompt_append: string?, env: {[string]: EnvValue}?, options: Object?}
type Scope = access.Scope
type Mcp = access.Mcp
type File = access.File
type Workspace = access.Workspace
type Bee = access.Bee
type Placement = {kind: "native", home: "private" | "machine"} | {kind: "docker", profile_ref: string, overrides: Object?}
type Profile = {schema_revision: string, definition_ref: string, driver_binding_ref: string, name: string,
    provider: Provider, bee: Bee, placement: Placement?, active_traits: {string}?, requestable: {string}?, role: string?, context: Context?,
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
function M.context(value: unknown): (Context?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "context must be a scalar map" end
    local result: Context = {}
    local count = 0
    for key, item in pairs(raw) do
        count = count + 1
        if count > 24 then return nil, "context exceeds 24 keys" end
        if not bounds.line(key, 128) or key == "" then return nil, "context key must contain 1 to 128 printable bytes" end
        if key:sub(1, 4) == "bee." then return nil, "reserved context key " .. key end
        if type(item) == "string" or type(item) == "boolean" then result[key] = item
        elseif type(item) == "number" and item == item and item ~= math.huge and item ~= -math.huge then result[key] = item
        else return nil, "context." .. key .. " must be a finite scalar" end
    end
    if not canonical.encode(result, 8192, 2) then return nil, "context exceeds 8192 encoded bytes" end
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
M.bee = access.decode
-- A folder under an admitted node root: the root's ref and a relative path
-- that stays inside it.
function M.workdir(value: unknown): Workdir?
    local item = bounds.object(value)
    local root = item and bounds.id(item.root_ref)
    local path = item and bounds.subpath(item.path)
    if not item or not root or not path or bounds.fields(item, {"root_ref", "path"}) then return nil end
    return {root_ref = root, path = path}
end
type Overrides = {name: string?, role: string?, traits: {string}?, context: Context?, workdir: Workdir?, workspace: string?, input: unknown}
function M.overrides(value: unknown): (Overrides?, string?)
    if value == nil then return {}, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"name", "role", "traits", "context", "workdir", "workspace", "input"}) then return nil, "invalid spawn overrides" end
    local result: Overrides = {}
    if raw.name ~= nil then
        local name = bounds.line(raw.name, 80)
        if not name or name:match("^%s*$") then return nil, "name must contain 1 to 80 printable bytes" end
        result.name = name
    end
    if raw.role ~= nil then
        local role = bounds.text(raw.role, 256)
        if not role or role:find("%c") then return nil, "role must contain at most 256 printable bytes" end
        result.role = role
    end
    if raw.traits ~= nil then
        local traits, err = bounds.ids(raw.traits, true)
        if not traits or #traits > 16 then return nil, err or "traits exceeds 16 traits" end
        result.traits = traits
    end
    if raw.context ~= nil then
        local context, err = M.context(raw.context)
        if not context then return nil, err end
        result.context = context
    end
    if raw.workdir ~= nil then
        result.workdir = M.workdir(raw.workdir)
        if not result.workdir then return nil, "invalid overrides.workdir" end
    end
    if raw.workspace ~= nil then
        local workspace = bounds.text(raw.workspace, 32)
        if not workspace or #workspace ~= 32 or workspace:find("[^0-9a-f]") then return nil, "workspace must be a canonical workspace ID" end
        result.workspace = workspace
    end
    if raw.input ~= nil then
        if type(raw.input) == "string" and #raw.input <= 16384 then result.input = raw.input
        else
            local input = bounds.object(raw.input)
            if not input or bounds.fields(input, {"schema", "value"}) or not bounds.id(input.schema) or not canonical.encode(input.value, 65536, 16) then return nil, "input must be bounded text or {schema, value}" end
            result.input = input
        end
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
-- A recorded v2 profile in the current schema: the same fields without the
-- retired presentation, budgets and supervision. Other values pass unchanged.
function M.upgrade(value: unknown): unknown
    local raw = bounds.object(value)
    if not raw or raw.schema_revision ~= M.PRIOR then return value end
    local result: Object = {}
    for key, item in pairs(raw) do
        if not bounds.member(key, M.RETIRED) then result[key] = item end
    end
    result.schema_revision = M.SCHEMA
    return result
end
function M.profile(value: unknown): (Profile?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "profile must be an object" end
    local extra = bounds.fields(raw, {"schema_revision", "definition_ref", "driver_binding_ref", "name", "provider", "bee", "placement", "workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest", "active_traits", "requestable", "role", "context"})
    if extra then return nil, extra end
    if raw.schema_revision ~= M.SCHEMA then return nil, "profile.schema_revision must be " .. M.SCHEMA end
    local definition, driver, name = bounds.id(raw.definition_ref), bounds.id(raw.driver_binding_ref), bounds.line(raw.name, 80)
    if not definition or not driver or not name or name:match("^%s*$") then return nil, "profile requires definition_ref, driver_binding_ref and name" end
    local provider, provider_error = M.provider(raw.provider)
    if not provider then return nil, provider_error end
    local bee, bee_error = M.bee(raw.bee)
    if not bee then return nil, bee_error end
    local result: Profile = {schema_revision = M.SCHEMA, definition_ref = definition, driver_binding_ref = driver, name = name, provider = provider, bee = bee}
    if raw.role ~= nil then
        local role = bounds.text(raw.role, 256)
        if not role or role:find("%c") then return nil, "role must contain at most 256 printable bytes" end
        result.role = role
    end
    if raw.context ~= nil then
        local context, err = M.context(raw.context)
        if not context then return nil, err end
        result.context = context
    end
    for _, field in ipairs({"active_traits", "requestable"}) do
        if raw[field] ~= nil then
            local selected, err = bounds.ids(raw[field], true)
            if not selected or #selected > 16 then return nil, err or field .. " exceeds 16 traits" end
            if field == "active_traits" then result.active_traits = selected else result.requestable = selected end
        end
    end
    local placement, placement_error = M.placement(raw.placement)
    if placement_error then return nil, placement_error end
    result.placement = placement
    if raw.workdir ~= nil then
        local workdir = M.workdir(raw.workdir)
        if not workdir then return nil, "invalid profile.workdir" end
        result.workdir = workdir
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

type LaunchPreferences = {context: Context?, requestable: {string}?, active_traits: {string}?, authority_grant_id: string?, docker_overrides: Object?, home: "private" | "machine"?, bee: Bee?, options: Object, mcp_tools: {string}, instructions: string}
function M.preferences(profile: Profile): (LaunchPreferences?, string?)
    local provider = profile.provider
    local options: Object = {}
    for name, value in pairs(provider.options or {}) do
        options[name] = value
    end
    if provider.model then options.model = provider.model end
    if provider.effort then options.effort = provider.effort end
    if provider.permission_mode then options.permission_mode = provider.permission_mode end
    if provider.tool_allow then options.tool_allow = provider.tool_allow end
    if provider.tool_deny then options.tool_deny = provider.tool_deny end
    if provider.env then options.env = provider.env end
    local bee = profile.bee
    local tools: {string} = {}
    for _, item in ipairs(bee.mcp or {}) do
        tools[#tools + 1] = item.tool
    end
    local home: "private" | "machine"? = nil
    if profile.placement and profile.placement.kind == "native" then home = profile.placement.home end
    local overrides = profile.placement and profile.placement.kind == "docker" and profile.placement.overrides or nil
    return {context = profile.context, requestable = profile.requestable, active_traits = profile.active_traits, docker_overrides = overrides, home = home, bee = bee, options = options, mcp_tools = tools,
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
