-- MIT. A function tool an agent may call: a function.lua entry whose meta
-- declares type tool, an llm_alias, an llm_description, a JSON input schema,
-- an optional output schema and MCP annotations. Framework agents and
-- workspace applications declare tools in this one shape; this module is the
-- single decoder for it and for the JSON Schema subset Bee advertises.
local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.TYPE = "tool"
-- A tool without owner-declared annotations is presented as side-effecting,
-- non-idempotent and open-world: the conservative reading until its owner
-- says otherwise.
M.DEFAULT_ANNOTATIONS = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = true}
type Object = {[string]: unknown}
type Tool = {ref: string, digest: string, alias: string, description: string, input_schema: Object,
    output_schema: Object?, scopes: {string}, annotations: {[string]: boolean}}

-- The supported JSON Schema subset an advertised tool may use: object
-- schemas with typed properties, required names, enums and constants, string,
-- integer and array bounds, formats, nested objects and arrays, and the
-- oneOf/allOf/if/then/else/not applicators over the same subset.
local SCHEMA_KEYS: {[string]: boolean} = {type = true, properties = true, required = true, items = true,
    enum = true, const = true, default = true, format = true, minimum = true, maximum = true, exclusiveMinimum = true, exclusiveMaximum = true, minProperties = true, maxProperties = true, minLength = true,
    maxLength = true, minItems = true, maxItems = true, uniqueItems = true, pattern = true, description = true,
    additionalProperties = true, examples = true, oneOf = true, allOf = true, ["if"] = true, ["then"] = true,
    ["else"] = true, ["not"] = true}
local SCHEMA_TYPES: {[string]: boolean} = {object = true, array = true, string = true, integer = true,
    number = true, boolean = true}
local SCHEMA_SCHEMAS = {"if", "then", "else", "not"}
local SCHEMA_LISTS = {"oneOf", "allOf"}
local SCHEMA_DEPTH = 8
local function valid_schema(value: unknown, depth: integer, applicator: boolean): boolean
    if depth > SCHEMA_DEPTH then return false end
    local schema = bounds.object(value)
    if not schema then return false end
    for key in pairs(schema) do if type(key) ~= "string" or not SCHEMA_KEYS[key] then return false end end
    local kind = schema.type
    if kind ~= nil and (type(kind) ~= "string" or not SCHEMA_TYPES[kind]) then return false end
    if schema.properties ~= nil then
        local properties = bounds.object(schema.properties)
        if not properties then return false end
        for _, child in pairs(properties) do if not valid_schema(child, depth + 1, false) then return false end end
    end
    if schema.required ~= nil then
        local required, required_error = bounds.ids(schema.required, true)
        if not required or required_error then return false end
        -- An applicator branch may require names its parent declares.
        if not applicator then
            local properties = schema.properties ~= nil and bounds.object(schema.properties) or nil
            for _, name in ipairs(required) do
                if not properties or properties[name] == nil then return false end
            end
        end
    end
    if schema.items ~= nil and not valid_schema(schema.items, depth + 1, false) then return false end
    for _, key in ipairs(SCHEMA_SCHEMAS) do
        if schema[key] ~= nil and not valid_schema(schema[key], depth + 1, true) then return false end
    end
    for _, key in ipairs(SCHEMA_LISTS) do
        if schema[key] ~= nil then
            local branches = schema[key]
            if type(branches) ~= "table" or #(branches) == 0 then return false end
            local count = 0
            for _ in pairs(branches) do count = count + 1 end
            if count ~= #(branches) then return false end
            for _, branch in ipairs(branches) do
                if not valid_schema(branch, depth + 1, true) then return false end
            end
        end
    end
    if schema.enum ~= nil then
        if type(schema.enum) ~= "table" or #schema.enum == 0 then return false end
        local count = 0
        for key in pairs(schema.enum) do
            if type(key) ~= "number" then return false end
            count = count + 1
        end
        if count ~= #schema.enum then return false end
    end
    for _, key in ipairs({"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}) do
        local bound = schema[key]
        if bound ~= nil and (type(bound) ~= "number" or bound ~= bound or bound == math.huge or bound == -math.huge) then return false end
    end
    for _, key in ipairs({"minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"}) do
        local bound = schema[key]
        if bound ~= nil and (type(bound) ~= "number" or bound ~= math.floor(bound) or bound < 0 or bound == math.huge) then return false end
    end
    if schema.pattern ~= nil and type(schema.pattern) ~= "string" then return false end
    if schema.format ~= nil and type(schema.format) ~= "string" then return false end
    if schema.uniqueItems ~= nil and type(schema.uniqueItems) ~= "boolean" then return false end
    if schema.description ~= nil and type(schema.description) ~= "string" then return false end
    if schema.additionalProperties ~= nil and type(schema.additionalProperties) ~= "boolean"
        and not valid_schema(schema.additionalProperties, depth + 1, false) then return false end
    return true
end
-- Whether value is an object schema in the advertised subset.
function M.valid_schema(value: unknown): boolean
    local schema = bounds.object(value)
    return schema ~= nil and schema.type == "object" and valid_schema(schema, 0, false)
end

-- MCP annotations are four booleans from a closed set.
function M.valid_annotations(value: unknown): boolean
    local annotations = bounds.object(value)
    if not annotations then return false end
    for key, item in pairs(annotations) do
        if type(key) ~= "string" or M.DEFAULT_ANNOTATIONS[key] == nil or type(item) ~= "boolean" then return false end
    end
    return true
end

-- Whether a name may be an MCP tool name Bee admits; session and call_tool
-- belong to the gateway.
function M.name(raw: unknown): string?
    local name = bounds.line(raw, 64)
    if not name or name == "" or not name:match("^[%w_.%-]+$") or name == "session" or name == "call_tool" then return nil end
    return name
end

local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end

-- decode reads the tool entry ref names.
function M.decode(ref: string, entry: Object): (Tool?, string?)
    if entry.kind ~= "function.lua" then return nil, ref .. " is not a function tool" end
    local meta = bounds.object(entry.meta)
    if not meta or meta.type ~= M.TYPE then return nil, ref .. " is not a function tool" end
    local alias = M.name(meta.llm_alias)
    if not alias then return nil, ref .. ": llm_alias is not an MCP name Bee admits" end
    local description = bounds.text(meta.llm_description, 4096)
    if not description then return nil, ref .. ": llm_description must be bounded text" end
    if type(meta.input_schema) ~= "string" then return nil, ref .. ": input_schema must be a JSON object" end
    local input_schema, schema_error = json.decode(meta.input_schema)
    if schema_error or type(input_schema) ~= "table" then return nil, ref .. ": input_schema must be a JSON object" end
    local output_schema: Object? = nil
    if meta.output_schema ~= nil then
        if type(meta.output_schema) ~= "string" then return nil, ref .. ": output_schema must be a JSON object" end
        local decoded, output_error = json.decode(meta.output_schema)
        if output_error or type(decoded) ~= "table" then return nil, ref .. ": output_schema must be a JSON object" end
        output_schema = decoded
    end
    local mcp = bounds.object(meta.mcp == nil and {} or meta.mcp)
    if not mcp then return nil, ref .. ": mcp must be an object" end
    local mcp_field = bounds.fields(mcp, {"required_scopes", "annotations"})
    if mcp_field then return nil, ref .. ": mcp: " .. mcp_field end
    local scopes, scopes_error = bounds.ids(mcp.required_scopes == nil and {} or mcp.required_scopes, true)
    if not scopes then return nil, ref .. ": mcp.required_scopes: " .. tostring(scopes_error) end
    local annotations: {[string]: boolean} = {}
    if mcp.annotations ~= nil then
        local declared = bounds.object(mcp.annotations)
        if not declared then return nil, ref .. ": mcp.annotations must be an object" end
        if not M.valid_annotations(declared) then
            return nil, ref .. ": mcp.annotations must be booleans from the MCP annotation set"
        end
        for key, item in pairs(declared) do annotations[key] = item == true end
    else
        for key, item in pairs(M.DEFAULT_ANNOTATIONS) do annotations[key] = item end
    end
    local digest, digest_error = digest_of({id = ref, kind = entry.kind, meta = entry.meta, data = entry.data})
    if not digest then return nil, ref .. ": " .. tostring(digest_error) end
    return {ref = ref, digest = digest, alias = alias, description = description, input_schema = input_schema,
        output_schema = output_schema, scopes = scopes, annotations = annotations}, nil
end

-- application reads a tool an application offers agents: a tool whose
-- schemas Bee advertises and that declares no security of its own, so it
-- runs only with the application's scope.
function M.application(ref: string, entry: Object): (Tool?, string?)
    local tool, tool_error = M.decode(ref, entry)
    if not tool then return nil, tool_error end
    if not M.valid_schema(tool.input_schema)
        or (tool.output_schema ~= nil and not M.valid_schema(tool.output_schema)) then
        return nil, "agent tool " .. ref .. " uses a schema Bee does not advertise"
    end
    local data = bounds.object(entry.data)
    if data and data.security ~= nil then
        return nil, "agent tool " .. ref .. " declares its own security; it runs only with the application's grants"
    end
    return tool, nil
end

return M
