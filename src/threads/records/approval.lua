-- MIT. Decoders for approval projection records: a request as the owner
-- store recorded it, and a transition with the revision it expected.
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local canonical = require("canonical")
local M = {}
M.REQUEST_KINDS = {"permission", "question"}
M.STATES = {"approved", "denied", "expired", "cancelled"}
M.MAX_SCHEMA_BYTES = 4096
M.MAX_REASON_BYTES = 512
function M.request(value: unknown): (types.ApprovalRequest?, string?)
    local object = bounds.object(value)
    if not object then return nil, "approval request must be an object" end
    local unknown_field = bounds.fields(object, {"approval_id", "request_kind", "requester_id", "operation_ref", "prompt", "response_schema", "expires_at", "state"})
    if unknown_field then return nil, unknown_field end
    local approval_id, requester_id = bounds.id(object.approval_id), bounds.id(object.requester_id)
    if not approval_id then return nil, "approval_id is not an identifier" end
    if not requester_id then return nil, "requester_id is not an identifier" end
    local kind = bounds.member(object.request_kind, M.REQUEST_KINDS)
    if not kind then return nil, "request_kind must be permission or question" end
    local operation_ref, valid = values.optional_id(object, "operation_ref")
    if not valid then return nil, "operation_ref is not an identifier" end
    local prompt, prompt_error = values.content(object.prompt)
    if not prompt then return nil, "prompt: " .. tostring(prompt_error) end
    local schema = bounds.object(object.response_schema == nil and {} or object.response_schema)
    if not schema then return nil, "response_schema must be an object" end
    local encoded_schema, schema_error = canonical.encode(schema)
    if not encoded_schema then return nil, "response_schema: " .. tostring(schema_error) end
    if #encoded_schema > M.MAX_SCHEMA_BYTES then return nil, "response_schema exceeds " .. tostring(M.MAX_SCHEMA_BYTES) .. " bytes" end
    local expires_at = bounds.timestamp(object.expires_at)
    if not expires_at then return nil, "expires_at is not a canonical UTC timestamp" end
    if object.state ~= "pending" then return nil, "a request is recorded pending" end
    local request_kind = kind :: types.ApprovalKind
    return {approval_id = approval_id, request_kind = request_kind, requester_id = requester_id, operation_ref = operation_ref, prompt = prompt,
        response_schema = schema, expires_at = expires_at, state = "pending"}, nil
end
function M.transition(value: unknown): (types.ApprovalTransition?, string?)
    local object = bounds.object(value)
    if not object then return nil, "approval transition must be an object" end
    local unknown_field = bounds.fields(object, {"approval_id", "expected_revision", "state", "decider_id", "response", "reason"})
    if unknown_field then return nil, unknown_field end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return nil, "approval_id is not an identifier" end
    local revision = bounds.integer(object.expected_revision)
    if not revision or revision < 0 then return nil, "expected_revision must be a nonnegative integer" end
    local state = bounds.member(object.state, M.STATES)
    if not state then return nil, "state must be approved, denied, expired or cancelled" end
    local decider_id, valid = values.optional_id(object, "decider_id")
    if not valid then return nil, "decider_id is not an identifier" end
    local response: types.Content? = nil
    if object.response ~= nil then
        local decoded, response_error = values.content(object.response)
        if not decoded then return nil, "response: " .. tostring(response_error) end
        response = decoded
    end
    local reason = bounds.text(object.reason, M.MAX_REASON_BYTES)
    if not reason then return nil, "reason must be bounded text" end
    local final_state = state :: types.ApprovalState
    return {approval_id = approval_id, expected_revision = revision, state = final_state, decider_id = decider_id, response = response, reason = reason}, nil
end
return M
