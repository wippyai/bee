-- MIT. Configurable MCP descriptions. Host admission supplies authority;
-- neither a tool declaration nor trait activation grants permissions.
local bounds = require("bounds")
local json = require("json")
local M = {}
type Object = {[string]: unknown}
type Tool = {name: string, operation: string, description: string, policies: {string}, schema: Object, annotations: Object}
type Trait = {id: string, title: string, prompt: string, tools: {string}}
type Catalog = {tools: {Tool}, traits: {Trait}}
local function reference(value: unknown): string?
    local id = bounds.id(value)
    if not id or not id:match("^[%w_.%-]+:[%w_.%-]+$") then return nil end
    return id
end
-- The supported JSON Schema subset a configured tool may advertise: an object
-- schema with typed properties, required names, enums, string and integer
-- bounds and nested objects and arrays of the same subset. Anything else is
-- refused at admission so a malformed component tool cannot be advertised.
local SCHEMA_KEYS: {[string]: boolean} = {type = true, properties = true, required = true, items = true,
    enum = true, minimum = true, maximum = true, minLength = true, maxLength = true, maxItems = true,
    pattern = true, description = true, additionalProperties = true, examples = true}
local SCHEMA_TYPES: {[string]: boolean} = {object = true, array = true, string = true, integer = true,
    number = true, boolean = true}
local function valid_schema(value: unknown, depth: integer): boolean
    if depth > 4 then return false end
    local schema = bounds.object(value)
    if not schema then return false end
    for key in pairs(schema) do if type(key) ~= "string" or not SCHEMA_KEYS[key] then return false end end
    local kind = schema.type
    if kind ~= nil and (type(kind) ~= "string" or not SCHEMA_TYPES[kind]) then return false end
    if schema.properties ~= nil then
        local properties = bounds.object(schema.properties)
        if not properties then return false end
        for _, child in pairs(properties) do if not valid_schema(child, depth + 1) then return false end end
    end
    if schema.required ~= nil then
        local required, required_error = bounds.ids(schema.required, true)
        if not required or required_error then return false end
        local properties = schema.properties ~= nil and bounds.object(schema.properties) or nil
        for _, name in ipairs(required) do
            if properties and properties[name] == nil then return false end
        end
    end
    if schema.items ~= nil and not valid_schema(schema.items, depth + 1) then return false end
    if schema.enum ~= nil then
        if type(schema.enum) ~= "table" or #schema.enum == 0 then return false end
        local count = 0
        for key in pairs(schema.enum) do
            if type(key) ~= "number" then return false end
            count = count + 1
        end
        if count ~= #schema.enum then return false end
    end
    for _, key in ipairs({"minimum", "maximum", "minLength", "maxLength", "maxItems"}) do
        local bound = schema[key]
        if bound ~= nil and (type(bound) ~= "number" or bound ~= math.floor(bound)) then return false end
    end
    if schema.pattern ~= nil and type(schema.pattern) ~= "string" then return false end
    if schema.description ~= nil and type(schema.description) ~= "string" then return false end
    if schema.additionalProperties ~= nil and type(schema.additionalProperties) ~= "boolean" then return false end
    return true
end
-- MCP annotations are four booleans from a closed set. A configured tool
-- that misstates them is refused at admission.
local ANNOTATION_KEYS: {[string]: boolean} = {readOnlyHint = true, destructiveHint = true,
    idempotentHint = true, openWorldHint = true}
local function valid_annotations(value: unknown): boolean
    local annotations = bounds.object(value)
    if not annotations then return false end
    for key, item in pairs(annotations) do
        if type(key) ~= "string" or not ANNOTATION_KEYS[key] or type(item) ~= "boolean" then return false end
    end
    return true
end
local function list(value: unknown, limit: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, "expected list" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "invalid list key" end
        count = count + 1
    end
    if count > limit then return nil, "list exceeds bound" end
    local result: {unknown} = {}
    for index = 1, count do
        if value[index] == nil then return nil, "sparse list" end
        result[index] = value[index]
    end
    return result, nil
end
function M.decode(raw: unknown): (Catalog?, string?)
    local encoded, encode_error = json.encode(raw)
    if not encoded or encode_error or #encoded > 131072 then return nil, "catalog exceeds JSON bound" end
    local copied, copy_error = json.decode(encoded)
    if copy_error then return nil, "invalid catalog JSON" end
    local value = bounds.object(copied)
    if not value then return nil, "catalog must be an object" end
    local extra = bounds.fields(value, {"tools", "traits"})
    if extra then return nil, extra end
    local tools, tools_error = list(value.tools, 32)
    local traits, traits_error = list(value.traits, 16)
    if not tools then return nil, tools_error end
    if not traits then return nil, traits_error end
    local result: Catalog = {tools = {}, traits = {}}
    local names: {[string]: boolean} = {}
    for _, raw_tool in ipairs(tools) do
        local tool = bounds.object(raw_tool)
        if not tool then return nil, "tool must be an object" end
        local invalid = bounds.fields(tool, {"name", "operation", "description", "policies", "schema", "annotations"})
        if invalid then return nil, invalid end
        local name, operation = bounds.line(tool.name, 64), reference(tool.operation)
        local description = bounds.text(tool.description, 4096)
        local policies = bounds.ids(tool.policies, true)
        local schema, annotations = bounds.object(tool.schema), bounds.object(tool.annotations)
        if not name or name == "session" or name == "call_tool" or not name:match("^[%w_.%-]+$") or names[name] or not operation or not description
            or not policies or #policies == 0 or #policies > 8 or not schema or not annotations then
            return nil, "invalid or duplicate tool declaration"
        end
        for _, policy in ipairs(policies) do if not reference(policy) then return nil, "invalid policy reference" end end
        if schema.type ~= "object" or not valid_schema(schema, 0) then
            return nil, "tool schema must be an object schema in the supported subset"
        end
        if not valid_annotations(annotations) then
            return nil, "tool annotations must be booleans from the MCP annotation set"
        end
        names[name] = true
        result.tools[#result.tools + 1] = {name = name, operation = operation, description = description,
            policies = policies, schema = schema, annotations = annotations}
    end
    local ids: {[string]: boolean} = {}
    for _, raw_trait in ipairs(traits) do
        local trait = bounds.object(raw_trait)
        if not trait then return nil, "trait must be an object" end
        local invalid = bounds.fields(trait, {"id", "title", "prompt", "tools"})
        if invalid then return nil, invalid end
        local id, title, prompt = reference(trait.id), bounds.line(trait.title, 256), bounds.text(trait.prompt, 16384)
        local selected = bounds.ids(trait.tools, true)
        if not id or ids[id] or not title or not prompt or not selected or #selected > 32 then return nil, "invalid or duplicate trait" end
        for _, name in ipairs(selected) do if not names[name] then return nil, "trait references unknown tool" end end
        ids[id] = true
        result.traits[#result.traits + 1] = {id = id, title = title, prompt = prompt, tools = selected}
    end
    return result, nil
end
-- The base tool set and selectable traits are host-admitted. Activating a
-- trait can never widen the independent tool ceiling, even if its declaration
-- was changed after the host selected it.
function M.select(catalog: Catalog, ceiling: {string}, base: {string}, allowed_traits: {string}, active: {string}): ({Tool}?, string?)
    local permitted: {[string]: boolean} = {}
    local selected: {[string]: boolean} = {}
    local known: {[string]: Tool} = {}
    local traits: {[string]: Trait} = {}
    local selectable: {[string]: boolean} = {}
    for _, tool in ipairs(catalog.tools) do known[tool.name] = tool end
    for _, trait in ipairs(catalog.traits) do traits[trait.id] = trait end
    for _, name in ipairs(ceiling) do
        if not known[name] then return nil, "admitted tool is unavailable" end
        permitted[name] = true
    end
    for _, id in ipairs(allowed_traits) do selectable[id] = true end
    for _, name in ipairs(base) do
        if not permitted[name] then return nil, "base tool exceeds admission" end
        selected[name] = true
    end
    for _, id in ipairs(active) do
        local trait = traits[id]
        if not selectable[id] or not trait then return nil, "trait is not admitted or unavailable" end
        for _, name in ipairs(trait.tools) do
            if not permitted[name] then return nil, "trait tool exceeds admission" end
            selected[name] = true
        end
    end
    local tools: {Tool} = {}
    for _, tool in ipairs(catalog.tools) do if selected[tool.name] then tools[#tools + 1] = tool end end
    return tools, nil
end
return M
