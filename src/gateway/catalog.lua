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
