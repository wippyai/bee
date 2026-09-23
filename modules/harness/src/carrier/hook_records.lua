-- MIT. Bounded shared hook record helper: decodes claimed hook items,
-- validates top-level boundaries, uniqueness, dense lists, and event keys,
-- producing extension observation records for thread commit.
local bounds = require("bounds")
local canonical = require("canonical")
local gateway_hooks = require("gateway_hooks")

local M = {}

M.MAX_CLAIMED_HOOKS = 16

type Object = {[string]: unknown}

type Batch = {
    records: {{[string]: unknown}},
    event_ids: {string},
    activity: string?,
}

-- Events whose activity describes a specific occurrence: without that
-- occurrence's identity the activity cannot be attributed and is uncertain.
local ATTRIBUTED: {[string]: boolean} = {
    UserPromptSubmit = true, PreToolUse = true, PostToolUse = true, PostToolUseFailure = true,
}
local ACTIVITY: {[string]: string} = {
    SessionStart = "Session started", UserPromptSubmit = "Working",
    PreToolUse = "Using tool", PostToolUse = "Working",
    PostToolUseFailure = "Tool failed", Stop = "Stopped",
    StopFailure = "Needs attention", SessionEnd = "Session ended",
}

-- Events that report the harness ended its turn, and the outcome the event
-- itself states. A stop names no outcome; a stop failure ended as failed.
local TURN_ENDED: {[string]: string} = {Stop = "", StopFailure = "failed"}

local ALLOWED_TOP_FIELDS: {string} = {
    "event_id",
    "event",
    "occurrence",
    "ambiguous",
    "provenance",
    "sequence",
    "fields",
    "digest",
    "created_at",
}

function M.batch(binding_id: string, turn_id: string?, items: unknown): (Batch?, string?)
    if type(binding_id) ~= "string" or not bounds.id(binding_id) then
        return nil, "invalid binding_id"
    end
    local valid_turn_id: string? = nil
    if turn_id ~= nil then
        valid_turn_id = bounds.id(turn_id)
        if not valid_turn_id then
            return nil, "invalid turn_id"
        end
    end
    if type(items) ~= "table" then
        return nil, "expected a list of hook records"
    end
    local count = 0
    for key in pairs(items :: Object) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, "list keys must be dense"
        end
        count = count + 1
    end
    if count ~= #(items :: {unknown}) then
        return nil, "list keys must be dense"
    end
    if count > M.MAX_CLAIMED_HOOKS then
        return nil, "hook claim exceeds limit of " .. tostring(M.MAX_CLAIMED_HOOKS)
    end
    if count == 0 then
        return {records = {}, event_ids = {}, activity = nil}, nil
    end

    local records: {{[string]: unknown}} = {}
    local event_ids: {string} = {}
    local activity: string? = nil
    local seen_event_ids: {[string]: boolean} = {}

    for index = 1, count do
        local raw_item = (items :: {unknown})[index]
        local item = bounds.object(raw_item)
        if not item then
            return nil, "hook record " .. tostring(index) .. " must be an object"
        end
        local unknown_field = bounds.fields(item, ALLOWED_TOP_FIELDS)
        if unknown_field then
            return nil, "hook record " .. tostring(index) .. ": " .. unknown_field
        end

        local event_id = bounds.id(item.event_id)
        if not event_id then
            return nil, "hook record " .. tostring(index) .. ": invalid event_id"
        end
        if seen_event_ids[event_id] then
            return nil, "hook record " .. tostring(index) .. ": duplicate event_id: " .. event_id
        end
        seen_event_ids[event_id] = true

        if type(item.event) ~= "string" or not gateway_hooks.known(item.event) then
            return nil, "hook record " .. tostring(index) .. ": unknown hook event: " .. tostring(item.event)
        end

        if type(item.occurrence) ~= "string" or #item.occurrence == 0 or #item.occurrence > 512 or item.occurrence:find("%c") then
            return nil, "hook record " .. tostring(index) .. ": invalid occurrence"
        end

        if type(item.ambiguous) ~= "boolean" then
            return nil, "hook record " .. tostring(index) .. ": ambiguous must be boolean"
        end

        local prov = bounds.id(item.provenance)
        if not prov then
            return nil, "hook record " .. tostring(index) .. ": invalid provenance"
        end

        local seq = bounds.count(item.sequence)
        if seq == nil then
            return nil, "hook record " .. tostring(index) .. ": invalid sequence"
        end

        if item.digest ~= nil then
            local dig = bounds.id(item.digest)
            if not dig then
                return nil, "hook record " .. tostring(index) .. ": invalid digest"
            end
        end

        if item.created_at ~= nil then
            if type(item.created_at) ~= "string" or #item.created_at == 0 or #item.created_at > 128 or item.created_at:find("%c") then
                return nil, "hook record " .. tostring(index) .. ": invalid created_at"
            end
        end

        local fields, fields_error = gateway_hooks.stored_fields(item.fields)
        if not fields then
            return nil, "hook record " .. tostring(index) .. ": " .. tostring(fields_error)
        end
        if fields.event ~= item.event then
            return nil, "hook record " .. tostring(index) .. ": event mismatch between record and fields"
        end

        local key = "hook:" .. event_id
        if item.ambiguous ~= true then
            key = "hook:" .. binding_id .. ":" .. tostring(item.event) .. ":" .. tostring(item.occurrence)
        end

        local payload_obj = {
            event_id = event_id,
            event = item.event,
            occurrence = item.occurrence,
            ambiguous = item.ambiguous == true,
            provenance = prov,
            sequence = seq,
            fields = fields,
            binding_id = binding_id,
        }
        local payload, encode_error = canonical.encode(payload_obj)
        if not payload then
            return nil, "hook record " .. tostring(index) .. ": canonical encode failed: " .. tostring(encode_error)
        end

        local record: {[string]: unknown} = {
            source = "bee",
            body = {
                type = "extension",
                event_key = key,
                data = {
                    type = "extension",
                    event_name = "bee.harness.hook",
                    event_revision = "1",
                    payload_json = payload,
                },
            },
        }
        if valid_turn_id ~= nil then
            record.turn_id = valid_turn_id
        end

        records[#records + 1] = record
        event_ids[index] = event_id
        -- A turn-ending hook is also a hook-sourced turn signal, keyed to the
        -- same occurrence, so thread readers see a window harness end its
        -- turn the way a stream harness reports it.
        local ended_outcome = TURN_ENDED[tostring(item.event)]
        if ended_outcome ~= nil then
            local signal: {[string]: unknown} = {type = "turn.signal", phase = "ended"}
            if ended_outcome ~= "" then signal.reported_outcome = ended_outcome end
            local turn_record: {[string]: unknown} = {source = "hook", body = {type = "turn.signal", event_key = key .. ":turn", data = signal}}
            if valid_turn_id ~= nil then turn_record.turn_id = valid_turn_id end
            records[#records + 1] = turn_record
        end
        local label = ACTIVITY[item.event]
        -- Ambiguity is about occurrence identity, not about what the event
        -- says happened. An ambiguous tool or prompt observation cannot be
        -- attributed to the action it reports, so that activity is
        -- uncertain. A stop carries no occurrence identity by design (a
        -- prompt may stop more than once), which is why it is always
        -- ambiguous; it reports only that activity ended, so it keeps its
        -- own label and a healthy attempt idle between turns is not
        -- reported uncertain.
        if item.ambiguous == true and ATTRIBUTED[item.event] == true then label = "Activity uncertain" end
        if label ~= nil then activity = label end
    end

    -- Only fixed labels leave the decoder; no prompt, tool input or arbitrary
    -- provider text becomes presentation. The window publishes after commit.
    return {records = records, event_ids = event_ids, activity = activity}, nil
end

return M
