-- MIT. The ten default session MCP tools as projections of the bee.sessions
-- owner contracts. The gateway validates arguments against the published
-- closed schemas, refuses caller identity in the payload, and validates each
-- owner reply against the published output schema. It implements no session
-- logic: every tool is one owner contract method.
local json = require("json")
local bounds = require("bounds")
local json_schema = require("json_schema")
local bundle_source = require("session_bundle")
local M = {}
M.CONTRACT = "bee.threads.sessions:contract"
M.CATALOG_CONTRACT = "bee.threads.sessions:catalog"
type Object = {[string]: unknown}
type Tool = {name: string, description: string, operation: string, policies: {string}, schema: Object, annotations: Object}
type Target = {contract: string, method: string, mutation: boolean, read: boolean, destructive: boolean}

-- method: the owner contract method each tool projects.
local TARGETS: {[string]: Target} = {
    session_catalog = {contract = M.CATALOG_CONTRACT, method = "list", mutation = false, read = true, destructive = false},
    session_open = {contract = M.CONTRACT, method = "open", mutation = true, read = false, destructive = false},
    session_run = {contract = M.CONTRACT, method = "run", mutation = true, read = false, destructive = false},
    session_send = {contract = M.CONTRACT, method = "send", mutation = true, read = false, destructive = false},
    session_await = {contract = M.CONTRACT, method = "await", mutation = false, read = true, destructive = false},
    session_join = {contract = M.CONTRACT, method = "join", mutation = true, read = false, destructive = true},
    session_get = {contract = M.CONTRACT, method = "get", mutation = false, read = true, destructive = false},
    session_list = {contract = M.CONTRACT, method = "list", mutation = false, read = true, destructive = false},
    session_cancel = {contract = M.CONTRACT, method = "cancel", mutation = true, read = false, destructive = true},
    session_close = {contract = M.CONTRACT, method = "close", mutation = true, read = false, destructive = true},
}
M.NAMES = {"session_catalog", "session_open", "session_run", "session_send", "session_await", "session_join",
    "session_get", "session_list", "session_cancel", "session_close"}

local bundle = assert(bounds.object((json.decode(bundle_source))))
local defs = assert(bounds.object(bundle["$defs"]))
local declared = assert(bounds.dense_list(bundle.tools, 64, "session tools"))

local function copy(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local result: Object = table.create(0, 1)
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function reference_name(node: Object): string?
    local reference = node["$ref"]
    if type(reference) ~= "string" then return nil end
    return (reference):match("^#/%$defs/([%w_]+)$")
end

-- dereference: the schema with every local reference replaced by its
-- definition, so a tool schema stands alone.
local function dereference(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local node = value
    local name = reference_name(node)
    if name then return dereference(defs[name]) end
    local result: Object = table.create(0, 1)
    for key, child in pairs(node) do result[key] = dereference(child) end
    return result
end

function M.profile_schema(): Object
    return assert(bounds.object(dereference(defs.AgentProfile)))
end

-- closure: the definitions a schema reaches, transitively.
local function collect(value: unknown, into: Object)
    if type(value) ~= "table" then return end
    local node = value
    local name = reference_name(node)
    if name then
        if into[name] == nil then
            into[name] = defs[name]
            collect(defs[name], into)
        end
        return
    end
    for _, child in pairs(node) do collect(child, into) end
end

local function output_schema(tool: Object): Object
    local selected: Object = {}
    collect(tool.outputSchema, selected)
    local schema = assert(bounds.object(copy(tool.outputSchema)))
    schema.type = "object"
    schema["$schema"] = bundle["$schema"]
    schema["$defs"] = copy(selected)
    return schema
end

local INPUT: {[string]: Object} = {}
local OUTPUT: {[string]: Object} = {}
local DESCRIPTIONS: {[string]: string} = {}
for _, raw_tool in ipairs(declared) do
    local tool = assert(bounds.object(raw_tool))
    local name = assert(bounds.id(tool.name))
    local description = tool.description
    assert(type(description) == "string", "session tool description is not text")
    assert(TARGETS[name], "unexpected session tool " .. name)
    INPUT[name] = assert(bounds.object(dereference(tool.inputSchema)))
    OUTPUT[name] = output_schema(tool)
    DESCRIPTIONS[name] = description
end
for _, name in ipairs(M.NAMES) do assert(INPUT[name], "missing session tool " .. name) end
M.OUTPUT_SCHEMAS = OUTPUT

-- tools: the ten declarations. The host-linked policy reference names the
-- scope the projection runs under; it never widens the owner's own checks.
function M.tools(policy: string, read: Object, write: Object): {Tool}
    local destructive = assert(bounds.object(copy(write)))
    destructive.destructiveHint = true
    local result: {Tool} = {}
    for _, name in ipairs(M.NAMES) do
        local target = TARGETS[name]
        local annotations = write
        if target.read then annotations = read elseif target.destructive then annotations = destructive end
        result[#result + 1] = {name = name, description = DESCRIPTIONS[name],
            operation = target.contract .. "." .. target.method, policies = {policy},
            schema = INPUT[name], annotations = annotations}
    end
    return result
end

function M.is_session_tool(name: string): boolean return TARGETS[name] ~= nil end

-- target: the owner contract and method a tool projects.
function M.target(name: string): (string?, string?)
    local target = TARGETS[name]
    if not target then return nil, nil end
    return target.contract, target.method
end

-- decode: the owner request for one tool call. Arguments are exactly the
-- published schema; caller identity is never a field and reaches the owner
-- only through the authenticated call context.
function M.decode(name: string, params: Object): (Object?, string?)
    local schema = INPUT[name]
    if not schema then return nil, "not a session tool" end
    local arguments = params.arguments
    if type(arguments) ~= "table" then return nil, "tool arguments must be an object" end
    local failure = json_schema.validate(schema, arguments)
    if failure then return nil, failure end
    local request = arguments
    if name == "session_join" and request.quorum ~= nil and (request.quorum) > #(request.works) then
        return nil, "quorum exceeds the number of works"
    end
    return request, nil
end

-- call: one owner method on an opened contract instance.
function M.call(instance: Object, name: string, request: Object): (unknown, unknown)
    local _, method = M.target(name)
    if not method then return nil, "not a session tool" end
    local invoke = instance[method]
    if type(invoke) ~= "function" then return nil, "owner binding has no method " .. method end
    return (invoke)(instance, request)
end

local resolved: {[string]: Object} = {}

-- result: the owner reply when it satisfies the published output schema and,
-- for a mutation, echoes the operation key on failure.
function M.result(name: string, reply: unknown): (Object?, string?)
    local declaration = OUTPUT[name]
    if not declaration then return nil, "not a session tool" end
    local schema = resolved[name]
    if not schema then
        local body = assert(bounds.object(copy(declaration)))
        body["$defs"] = nil
        schema = assert(bounds.object(dereference(body)))
        resolved[name] = schema
    end
    if type(reply) ~= "table" then return nil, "owner reply must be an object" end
    local failure = json_schema.validate(schema, reply)
    if failure then return nil, "owner reply violates the published schema: " .. failure end
    return reply, nil
end

return M
