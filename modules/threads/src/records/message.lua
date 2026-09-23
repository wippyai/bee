-- MIT. Message decoder: addressed content between participants.
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local M = {}
function M.decode(value: unknown): (types.Message?, string?)
    local object = bounds.object(value)
    if not object then return nil, "message must be an object" end
    local unknown_field = bounds.fields(object, {"message_id", "message_kind", "sender_id", "recipient_ids", "recipient_action_ids", "sender_action_id", "content", "in_reply_to", "outcome"})
    if unknown_field then return nil, unknown_field end
    local message_id, sender_id = bounds.id(object.message_id), bounds.id(object.sender_id)
    local kind = bounds.member(object.message_kind, {"request", "progress", "reply", "notification"})
    if not message_id then return nil, "message_id is not an identifier" end
    if not kind then return nil, "message_kind is not request, progress, reply or notification" end
    if not sender_id then return nil, "sender_id is not an identifier" end
    local recipients, recipients_error = bounds.ids(object.recipient_ids, true)
    if not recipients then return nil, "recipient_ids: " .. tostring(recipients_error) end
    local content, content_error = values.content(object.content)
    if not content then return nil, content_error end
    local message: types.Message = {message_id = message_id, message_kind = kind :: types.MessageKind,
        sender_id = sender_id, recipient_ids = recipients, content = content}
    if object.in_reply_to ~= nil then
        local ref, ref_error = values.ref(object.in_reply_to)
        if not ref then return nil, "in_reply_to: " .. tostring(ref_error) end
        message.in_reply_to = ref
    end
    -- Actions address sessions that share one member identity, such as
    -- agents started on one thread by the same subject; the authority checks
    -- each against the thread the message lands on and the sending action
    -- against the sender's own admitted work.
    if object.recipient_action_ids ~= nil then
        local actions, actions_error = bounds.ids(object.recipient_action_ids, true)
        if not actions then return nil, "recipient_action_ids: " .. tostring(actions_error) end
        if #actions == 0 then return nil, "recipient_action_ids names at least one action" end
        message.recipient_action_ids = actions
    end
    if object.sender_action_id ~= nil then
        local sender_action = bounds.id(object.sender_action_id)
        if not sender_action then return nil, "sender_action_id is not an identifier" end
        message.sender_action_id = sender_action
    end
    if object.outcome ~= nil then
        local outcome = values.outcome(object.outcome)
        if not outcome then return nil, "message outcome is not an outcome" end
        message.outcome = outcome
    end
    if kind == "reply" then
        if not message.in_reply_to then return nil, "reply needs in_reply_to" end
        if not message.outcome then return nil, "reply needs an outcome" end
    elseif kind ~= "notification" and message.outcome then
        return nil, kind .. " carries no outcome"
    end
    return message, nil
end
return M
