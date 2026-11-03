-- MIT. A driver's synchronous hook answer is shaped by the response entry its
-- bee.driver_hooks declaration names (meta type bee.driver_hook_response).
-- Each part renders a JSON template when its fact holds for the event; the
-- rendered parts merge into one answer. A template string that is exactly
-- one placeholder takes that value, and a key whose value is absent is left
-- out. permission shapes a PermissionRequest decision the same way.
local registry = require("registry")
local bounds = require("bounds")
local capabilities = require("capabilities")
local M = {}
type Object = {[string]: unknown}
M.TYPE = "bee.driver_hook_response"
M.FACTS = {"context", "denied", "changed", "output"}
M.PART_VALUES = {"event", "reason", "context", "input", "output"}
M.PERMISSION_VALUES = {"behavior", "message"}
M.MAX_PARTS = 16
M.MAX_DEPTH = 8
type Part = {fact: string, events: {string}?, except_events: {string}?, unless: {string}, value: unknown}
type Shape = {parts: {Part}, permission: unknown?}

local function check_template(value: unknown, allowed: {string}, label: string, depth: integer): string?
    if depth > M.MAX_DEPTH then return label .. " nests too deep" end
    if type(value) == "string" then
        local name = value:match("^{([%w_]+)}$")
        if name and not bounds.member(name, allowed) then return label .. " names unknown value {" .. name .. "}" end
        return nil
    end
    if type(value) ~= "table" then return nil end
    for key, item in pairs(value) do
        local item_error = check_template(item, allowed, label .. "." .. tostring(key), depth + 1)
        if item_error then return item_error end
    end
    return nil
end

local function events(raw: unknown, label: string): ({string}?, string?)
    if raw == nil then return nil, nil end
    local list = bounds.ids(raw, true)
    if not list or #list == 0 then return nil, label .. " must name hook events" end
    return list, nil
end

-- decode reads one response entry's data strictly.
function M.decode(raw: unknown): (Shape?, string?)
    local data = bounds.object(raw)
    if not data then return nil, "hook response data must be an object" end
    local extra = bounds.fields(data, {"parts", "permission"})
    if extra then return nil, "hook response: " .. extra end
    local rows = bounds.array(data.parts == nil and {} or data.parts, M.MAX_PARTS)
    if not rows then return nil, "hook response parts must list at most " .. tostring(M.MAX_PARTS) .. " parts" end
    local parts: {Part} = {}
    for index, raw_part in ipairs(rows) do
        local label = "hook response part " .. tostring(index)
        local part = bounds.object(raw_part)
        if not part or bounds.fields(part, {"fact", "events", "except_events", "unless", "value"}) then return nil, label .. " is malformed" end
        local fact = bounds.member(part.fact, M.FACTS)
        if not fact then return nil, label .. " names no known fact" end
        local only, only_error = events(part.events, label .. " events")
        if only_error then return nil, only_error end
        local except, except_error = events(part.except_events, label .. " except_events")
        if except_error then return nil, except_error end
        local unless = bounds.ids(part.unless == nil and {} or part.unless, true)
        if not unless then return nil, label .. " unless must name facts" end
        for _, name in ipairs(unless) do
            if not bounds.member(name, M.FACTS) then return nil, label .. " unless names unknown fact " .. name end
        end
        if not bounds.object(part.value) then return nil, label .. " value must be an object" end
        local template_error = check_template(part.value, M.PART_VALUES, label .. " value", 0)
        if template_error then return nil, template_error end
        parts[index] = {fact = fact, events = only, except_events = except, unless = unless, value = part.value}
    end
    if data.permission ~= nil then
        if not bounds.object(data.permission) then return nil, "hook response permission must be an object" end
        local template_error = check_template(data.permission, M.PERMISSION_VALUES, "hook response permission", 0)
        if template_error then return nil, template_error end
    end
    return {parts = parts, permission = data.permission}, nil
end

-- shape returns the response entry a driver's hook declaration names.
function M.shape(driver: string): (Shape?, string?)
    local declared, problem = capabilities.declaration(driver)
    if problem then return nil, problem end
    local ref = declared.response
    if not ref then return nil, "driver " .. driver .. " names no hook response" end
    local entry, get_error = registry.get(ref)
    local item = bounds.object(entry)
    local meta = item and bounds.object(item.meta)
    if get_error or not item or not meta or meta.type ~= M.TYPE then return nil, "hook response " .. ref .. " is unavailable" end
    local decoded, decode_error = M.decode(item.data)
    if not decoded then return nil, ref .. ": " .. tostring(decode_error) end
    return decoded, nil
end

local function fill(template: unknown, values: Object): unknown
    if type(template) == "string" then
        local name = template:match("^{([%w_]+)}$")
        if not name then return template end
        local value = values[name]
        if value == "" then return nil end
        return value
    end
    if type(template) ~= "table" then return template end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(template) do result[key] = fill(item, values) end
    return result
end

local function merge(target: Object, source: Object)
    for key, value in pairs(source) do
        local into, from = bounds.object(target[key]), bounds.object(value)
        if into and from then merge(into, from) else target[key] = value end
    end
end

local function facts(event: string, result: Object): ({[string]: boolean}, Object)
    local context = bounds.text(result.additional_context, 24576)
    if context == "" then context = nil end
    local held: {[string]: boolean} = {
        context = context ~= nil,
        denied = result.denied == true,
        changed = result.changed == true and result.input ~= nil,
        output = #(bounds.array(result.original_refs, 16) or {}) > 0,
    }
    return held, {event = event, reason = result.reason, context = context, input = result.input, output = result.output}
end

local function applies(part: Part, event: string, held: {[string]: boolean}): boolean
    if not held[part.fact] then return false end
    if part.events and not bounds.member(event, part.events) then return false end
    if part.except_events and bounds.member(event, part.except_events) then return false end
    for _, name in ipairs(part.unless) do if held[name] then return false end end
    return true
end

-- render shapes the host's hook result for event as the driver's answer.
function M.render(event: string, raw: unknown, driver: string): (Object?, string?)
    local result = bounds.object(raw)
    if not result then return nil, "hook result must be an object" end
    local selected, shape_error = M.shape(driver)
    if not selected then return nil, shape_error end
    local held, values = facts(event, result)
    local answer: Object = {}
    for _, part in ipairs(selected.parts) do
        if applies(part, event, held) then merge(answer, assert(bounds.object(fill(part.value, values)))) end
    end
    return answer, nil
end

-- permission shapes a PermissionRequest decision for the driver; a driver
-- whose response declares no permission shape takes the decision as Bee
-- writes it.
function M.permission(decision: Object, driver: string): (Object?, string?)
    local selected, shape_error = M.shape(driver)
    if not selected then return nil, shape_error end
    if selected.permission == nil then return decision, nil end
    local output = bounds.object(decision.hookSpecificOutput)
    local verdict = output and bounds.object(output.decision)
    if not verdict then return nil, "permission decision is malformed" end
    return bounds.object(fill(selected.permission, {behavior = verdict.behavior, message = verdict.message})), nil
end

return M
