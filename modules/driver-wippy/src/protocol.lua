-- MIT. Native Wippy driver protocol revision native-1: the in-process runner
-- commits observations and the terminal report to the carrier itself, so
-- normalize re-validates one committed envelope instead of parsing process
-- output. Envelopes carry observations verbatim; only their shape is
-- checked, never their content.
local bounds = require("bounds")

local M = {}
M.PROTOCOL_REVISION = "native-1"
M.MAX_OBSERVATIONS = 64

type State = {
    resumed: boolean,
    terminal: {[string]: unknown}?,
}

type Step = {
    observations: {{[string]: unknown}},
    terminal: {[string]: unknown}?,
}

function M.new(resumed: boolean): State
    return {resumed = resumed, terminal = nil}
end

local function observation(value: unknown, index: integer): ({[string]: unknown}?, string?)
    local label = "observations[" .. tostring(index) .. "]"
    local object = bounds.object(value)
    if not object then return nil, label .. " must be an object" end
    if bounds.fields(object, {"source", "body", "turn_id"}) then return nil, label .. " carries an unknown field" end
    if object.source ~= "bee" then return nil, label .. ".source must be bee" end
    if not bounds.object(object.body) then return nil, label .. ".body must be an object" end
    if object.turn_id ~= nil and not bounds.id(object.turn_id) then return nil, label .. ".turn_id is not an identifier" end
    return object, nil
end

local function terminal(value: unknown): ({[string]: unknown}?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, "terminal must be an object" end
    if bounds.fields(object, {"outcome", "answer"}) then return nil, "terminal carries an unknown field" end
    if not bounds.member(object.outcome, {"succeeded", "failed", "cancelled", "uncertain"}) then
        return nil, "terminal.outcome is not a carrier outcome"
    end
    if object.answer ~= nil and not bounds.text(object.answer, 32768) then
        return nil, "terminal.answer must be bounded text"
    end
    return object, nil
end

function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): (Step?, string?)
    if index < 0 then return nil, "index must be a nonnegative integer" end
    if state.terminal then return nil, "envelope arrived after the turn ended" end
    if bounds.fields(envelope, {"observations", "terminal"}) then return nil, "envelope carries an unknown field" end
    local raw = envelope.observations == nil and {} or envelope.observations
    if type(raw) ~= "table" then return nil, "observations must be a list" end
    local list = raw :: {unknown}
    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, "observations must be a list" end
        count = count + 1
    end
    if count > M.MAX_OBSERVATIONS then return nil, "observations exceeds " .. tostring(M.MAX_OBSERVATIONS) .. " items" end
    local out: {{[string]: unknown}} = {}
    for position = 1, count do
        local item, item_error = observation(list[position], position)
        if not item then return nil, item_error end
        out[#out + 1] = item
    end
    local term, term_error = terminal(envelope.terminal)
    if term_error then return nil, term_error end
    if term then state.terminal = term end
    return {observations = out, terminal = term}, nil
end

function M.finish(state: State, index: integer): (Step?, string?)
    if index < 0 then return nil, "index must be a nonnegative integer" end
    return {observations = {}, terminal = state.terminal}, nil
end

return M
