-- MIT. Decoders for the delivery families the authority commits: a mark for
-- every claim transition and the answered record a correlated reply settles.
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local M = {}
function M.mark(value: unknown): (types.DeliveryMark?, string?)
    local object = bounds.object(value)
    if not object then return nil, "delivery mark must be an object" end
    local unknown_field = bounds.fields(object, {"delivery_id", "message_id", "recipient_id", "state", "owner_epoch", "channel", "evidence_ref"})
    if unknown_field then return nil, unknown_field end
    local delivery_id, message_id, recipient_id = bounds.id(object.delivery_id), bounds.id(object.message_id), bounds.id(object.recipient_id)
    local state = bounds.member(object.state, {"claimed", "delivered", "released", "uncertain"})
    local epoch = bounds.integer(object.owner_epoch)
    local channel = bounds.id(object.channel)
    if not delivery_id then return nil, "delivery_id is not an identifier" end
    if not message_id then return nil, "message_id is not an identifier" end
    if not recipient_id then return nil, "recipient_id is not an identifier" end
    if not state then return nil, "delivery state is not claimed, delivered, released or uncertain" end
    if not epoch or epoch < 1 then return nil, "owner_epoch must be a positive integer" end
    if not channel then return nil, "channel is not an identifier" end
    local mark: types.DeliveryMark = {delivery_id = delivery_id, message_id = message_id, recipient_id = recipient_id,
        state = state :: types.DeliveryState, owner_epoch = epoch, channel = channel}
    local evidence, valid = values.optional_id(object, "evidence_ref")
    if not valid then return nil, "evidence_ref is not an identifier" end
    mark.evidence_ref = evidence
    return mark, nil
end
function M.answered(value: unknown): (types.Answered?, string?)
    local object = bounds.object(value)
    if not object then return nil, "answered record must be an object" end
    local unknown_field = bounds.fields(object, {"request_message_id", "recipient_id", "reply_message_id", "outcome"})
    if unknown_field then return nil, unknown_field end
    local request_id, recipient_id, reply_id = bounds.id(object.request_message_id), bounds.id(object.recipient_id), bounds.id(object.reply_message_id)
    local outcome = values.outcome(object.outcome)
    if not request_id then return nil, "request_message_id is not an identifier" end
    if not recipient_id then return nil, "recipient_id is not an identifier" end
    if not reply_id then return nil, "reply_message_id is not an identifier" end
    if not outcome then return nil, "answered outcome is not an outcome" end
    return {request_message_id = request_id, recipient_id = recipient_id, reply_message_id = reply_id, outcome = outcome}, nil
end
return M
