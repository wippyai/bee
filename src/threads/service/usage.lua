local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local record = require("record")
local record_types = require("record_types")
local journal = require("journal")
local access = require("access")
local M = {}
type Usage = {input_tokens: integer?, output_tokens: integer?, cached_tokens: integer?, tool_calls: integer?, coverage: string}
local function merge(target: Usage, raw: unknown): string?
    if raw == nil then return nil end
    local source = bounds.object(raw)
    if not source then return "reported usage must be an object" end
    for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
        if source[name] ~= nil then
            local count = bounds.count(source[name])
            if count == nil then return "invalid usage counter: " .. name end
            if name == "input_tokens" then target.input_tokens = math.max(target.input_tokens or 0, count)
            elseif name == "output_tokens" then target.output_tokens = math.max(target.output_tokens or 0, count)
            else target.cached_tokens = math.max(target.cached_tokens or 0, count) end
        end
    end
    return nil
end
local function data(record: record_types.Record, session: string, turn: string): {[string]: unknown}?
    if record.kind ~= "observation" or access.forwarded(record.producer_id) then return nil end
    local observed = record.body.data
    if observed.type == "extension" and observed.event_name == "bee.sessions.event" then
        if record.source ~= "bee" then return nil end
        local event = bounds.object(json.decode(observed.payload_json))
        local detail = event and bounds.object(event.data)
        local observation = detail and bounds.object(detail.observation)
        if not event or event.session_ref ~= session or event.kind ~= "turn.observation" or not detail or detail.turn ~= turn or not observation then return nil end
        return bounds.object(observation.data)
    end
    if record.action_id == session then return bounds.object(observed) end
    return nil
end
function M.turn(tx: sql.Transaction, thread: string, turn: journal.Turn, reported: unknown): (Usage?, string?)
    local rows, err = tx:query("SELECT record_json FROM bee_thread_records WHERE thread_id=? AND kind='observation' AND sequence>(SELECT sequence FROM bee_thread_records WHERE record_id=?) ORDER BY sequence", {thread, turn.reserve_record_id})
    if not rows or err then return nil, "read committed turn usage" end
    local usage: Usage = {coverage = "unknown"}
    local calls: {[string]: boolean} = {}
    local tool_calls = 0
    for _, row in ipairs(rows) do
        local decoded, invalid = record.decode_json(row.record_json)
        if not decoded then return nil, invalid end
        local observation = data(decoded, turn.session_ref, turn.turn_ref)
        if observation then
            if observation.type == "turn.signal" and observation.phase == "ended" then
                local invalid = merge(usage, observation.usage)
                if invalid then return nil, invalid end
            elseif observation.type == "tool.call" then
                local id = bounds.id(observation.call_id)
                if id and not calls[id] then calls[id] = true; tool_calls = tool_calls + 1 end
            end
        end
    end
    if tool_calls > 0 then usage.tool_calls = tool_calls end
    local invalid = merge(usage, reported)
    if invalid then return nil, invalid end
    if usage.input_tokens ~= nil or usage.output_tokens ~= nil or usage.cached_tokens ~= nil or usage.tool_calls ~= nil then usage.coverage = "partial" end
    return usage, nil
end
return M
