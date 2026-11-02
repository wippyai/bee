-- MIT. A driver's hook semantics come from its bee.driver_hooks declaration,
-- found by meta.driver_id. A driver without one answers no hook point.
local registry = require("registry")
local bounds = require("bounds")
local hook_limits = require("hook_limits")
local M = {}
M.TYPE = "bee.driver_hooks"
M.POINTS = {"session.start", "prompt.submit", "tool.before", "tool.after"}
M.EVENTS = {SessionStart = "session.start", UserPromptSubmit = "prompt.submit", PreToolUse = "tool.before", PostToolUse = "tool.after"}
M.RESULTS = {"pass", "add_context", "change", "deny"}
M.RESPONSES = {"hook_specific_output", "agy", "host"}
M.TRANSPORTS = {command = hook_limits.COMMAND_SECONDS, http = hook_limits.HTTP_SECONDS, mcp = hook_limits.MCP_SECONDS}
M.UNDECLARED = "The driver declares no synchronous hook response."
type Capability = {point: string, supported: boolean, allowed_results: {string}, reason: string}
type Point = {results: {string}, reason: string, transport: string?}
type McpMeta = {hook: {string}, model: {string}}
type Declaration = {
    response: string?,
    unsupported: string,
    points: {[string]: Point},
    allow_on_change: boolean,
    input: string?,
    input_bytes: integer?,
    output_bytes: integer?,
    mcp_meta: McpMeta?,
}

local function names(raw: unknown, label: string): ({string}?, string?)
    local list = bounds.ids(raw, true)
    if not list or #list == 0 or #list > 8 then return nil, label .. " must name one to eight fields" end
    return list, nil
end

local function transport(raw: unknown, label: string): (string?, string?)
    if raw == nil then return nil, nil end
    if type(raw) ~= "string" or M.TRANSPORTS[raw] == nil then return nil, label .. " must be command, http or mcp" end
    return raw, nil
end

-- decode reads one declaration's data strictly; a field it does not know is
-- refused rather than ignored.
function M.decode(raw: unknown): (Declaration?, string?)
    local data = bounds.object(raw)
    if not data then return nil, "hook declaration data must be an object" end
    local extra = bounds.fields(data, {"response", "transport", "unsupported", "points", "allow_on_change", "input",
        "input_bytes", "output_bytes", "mcp_meta"})
    if extra then return nil, "hook declaration: " .. extra end
    local response: string? = nil
    if data.response ~= nil then
        response = bounds.member(data.response, M.RESPONSES)
        if not response then return nil, "hook declaration response must be hook_specific_output, agy or host" end
    end
    local default_transport, transport_error = transport(data.transport, "hook declaration transport")
    if transport_error then return nil, transport_error end
    local unsupported = M.UNDECLARED
    if data.unsupported ~= nil then
        local text = bounds.line(data.unsupported, 512)
        if not text or text == "" then return nil, "hook declaration unsupported must be one line" end
        unsupported = text
    end
    local points: {[string]: Point} = {}
    local declared = bounds.object(data.points == nil and {} or data.points)
    if not declared then return nil, "hook declaration points must be an object" end
    for name, raw_point in pairs(declared) do
        if not bounds.member(name, M.POINTS) then return nil, "hook declaration names unknown point " .. tostring(name) end
        local point = bounds.object(raw_point)
        if not point or bounds.fields(point, {"results", "reason", "transport"}) then return nil, "hook point " .. name .. " is malformed" end
        local results = bounds.ids(point.results, true)
        if not results or #results == 0 then return nil, "hook point " .. name .. " names no results" end
        for _, result in ipairs(results) do
            if not bounds.member(result, M.RESULTS) then return nil, "hook point " .. name .. " names unknown result " .. result end
        end
        local reason = bounds.line(point.reason, 512)
        if not reason or reason == "" then return nil, "hook point " .. name .. " needs a one-line reason" end
        local selected, selected_error = transport(point.transport, "hook point " .. name .. " transport")
        if selected_error then return nil, selected_error end
        selected = selected or default_transport
        if response ~= "host" and not selected then return nil, "hook point " .. name .. " names no transport" end
        points[name] = {results = results, reason = reason, transport = selected}
    end
    if next(points) ~= nil and not response then return nil, "a hook declaration with points names its response" end
    if data.allow_on_change ~= nil and type(data.allow_on_change) ~= "boolean" then return nil, "allow_on_change must be a boolean" end
    local input: string? = nil
    if data.input ~= nil then
        input = bounds.member(data.input, {"command", "additive"})
        if not input then return nil, "hook declaration input must be command or additive" end
    end
    local input_bytes = data.input_bytes ~= nil and bounds.count(data.input_bytes) or nil
    if data.input_bytes ~= nil and (not input_bytes or input_bytes < 1) then return nil, "input_bytes must be a positive integer" end
    local output_bytes = data.output_bytes ~= nil and bounds.count(data.output_bytes) or nil
    if data.output_bytes ~= nil and (not output_bytes or output_bytes < 1) then return nil, "output_bytes must be a positive integer" end
    local mcp_meta: McpMeta? = nil
    if data.mcp_meta ~= nil then
        local meta = bounds.object(data.mcp_meta)
        if not meta or bounds.fields(meta, {"hook", "model"}) then return nil, "mcp_meta names hook and model fields" end
        local hook, hook_error = names(meta.hook, "mcp_meta.hook")
        if not hook then return nil, hook_error end
        local model, model_error = names(meta.model, "mcp_meta.model")
        if not model then return nil, model_error end
        mcp_meta = {hook = hook, model = model}
    end
    return {response = response, unsupported = unsupported, points = points, allow_on_change = data.allow_on_change == true,
        input = input, input_bytes = input_bytes, output_bytes = output_bytes, mcp_meta = mcp_meta}, nil
end

local function declarations(query: {[string]: unknown}): ({unknown}?, string?)
    local pinned, pin_error = registry.snapshot()
    if not pinned then return nil, "hook declarations are unreadable: " .. tostring(pin_error) end
    query[".kind"], query["meta.type"] = "registry.entry", M.TYPE
    local found, find_error = pinned:find(query)
    if find_error or not found then return nil, "hook declarations are unreadable: " .. tostring(find_error) end
    return found, nil
end

-- declaration returns the driver's hook declaration; a driver that declares
-- none has no hook points.
function M.declaration(driver: string): (Declaration, string?)
    local none: Declaration = {unsupported = M.UNDECLARED, points = {}, allow_on_change = false}
    local found, find_error = declarations({["meta.driver_id"] = driver})
    if not found then return none, find_error end
    if #found == 0 then return none, nil end
    if #found > 1 then return none, "driver " .. driver .. " declares hooks more than once" end
    local entry = bounds.object(found[1])
    local decoded, decode_error = M.decode(entry and entry.data)
    if not decoded then return none, tostring(entry and bounds.id(entry.id) or driver) .. ": " .. tostring(decode_error) end
    return decoded, nil
end

function M.for_driver(driver: string): {Capability}
    local declared, problem = M.declaration(driver)
    local result: {Capability} = {}
    for _, point in ipairs(M.POINTS) do
        local selected = declared.points[point]
        if selected then
            result[#result + 1] = {point = point, supported = true, allowed_results = selected.results, reason = selected.reason}
        else
            result[#result + 1] = {point = point, supported = false, allowed_results = {}, reason = problem or declared.unsupported}
        end
    end
    return result
end
function M.at(driver: string, point: string): Capability?
    for _, capability in ipairs(M.for_driver(driver)) do
        if capability.point == point then return capability end
    end
    return nil
end
function M.allows(capability: Capability, result: string): boolean
    for _, allowed in ipairs(capability.allowed_results) do if allowed == result then return true end end
    return false
end
-- seconds bounds a hook chain by the transport the driver answers the point on.
function M.seconds(driver: string, point: string): integer?
    local declared = M.declaration(driver)
    local selected = declared.points[point]
    local name = selected and selected.transport
    if not name then return nil end
    return M.TRANSPORTS[name]
end
-- mcp_meta lists the request metadata fields each driver answering over the
-- MCP hook transport sets on its hook-engine and model calls.
function M.mcp_meta(): ({McpMeta}?, string?)
    local found, find_error = declarations({})
    if not found then return nil, find_error end
    local rules: {McpMeta} = {}
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local decoded = entry and M.decode(entry.data) or nil
        if decoded and decoded.mcp_meta then rules[#rules + 1] = decoded.mcp_meta end
    end
    return rules, nil
end
return M
