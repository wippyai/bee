-- MIT. Durable identity for an interactive Agent continuation.
--
-- This value is application data. It contains no grant, process, mount or
-- provider secret; the launch owner validates it again through admission.
local bounds = require("bounds")
local json = require("json")
local M = {}
M.SCHEMA = "bee.agent.window@1"
type Saved = {definition_ref: string, plan_digest: string, origin_request_id: string, previous_attempt_id: string, thread_id: string}
type Launch = {broker_pid: string}

local function digest(value: string): boolean
    return #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

function M.decode(value: unknown): (Saved?, string?)
    local object = bounds.object(value)
    if not object then return nil, "Agent checkpoint must be an object" end
    local unknown = bounds.fields(object, {"definition_ref", "plan_digest", "origin_request_id", "previous_attempt_id", "thread_id"})
    if unknown then return nil, "Agent checkpoint: " .. unknown end
    local definition_ref = bounds.id(object.definition_ref)
    local plan_digest = bounds.text(object.plan_digest, 64)
    local origin = bounds.id(object.origin_request_id)
    local previous = bounds.id(object.previous_attempt_id)
    local thread = bounds.id(object.thread_id)
    if not definition_ref then return nil, "Agent checkpoint has invalid identity fields" end
    if not plan_digest or not digest(plan_digest) then return nil, "Agent checkpoint has invalid identity fields" end
    if not origin then return nil, "Agent checkpoint has invalid identity fields" end
    if not previous then return nil, "Agent checkpoint has invalid identity fields" end
    if not thread then return nil, "Agent checkpoint has invalid identity fields" end
    return {definition_ref = definition_ref, plan_digest = plan_digest, origin_request_id = origin,
        previous_attempt_id = previous, thread_id = thread}, nil
end

function M.encode(saved: Saved): (string?, string?)
    local encoded, encode_error = json.encode({definition_ref = saved.definition_ref, plan_digest = saved.plan_digest,
        origin_request_id = saved.origin_request_id, previous_attempt_id = saved.previous_attempt_id, thread_id = saved.thread_id})
    if not encoded then return nil, tostring(encode_error or "encode checkpoint") end
    return encoded, nil
end

-- Only the broker's authenticated, correlated success is an application
-- checkpoint acknowledgement. Everything else is ignored by the caller.
function M.acknowledged(launch: Launch, sender: string, value: unknown, request_id: string): (boolean, string?)
    if sender ~= launch.broker_pid or type(value) ~= "table" then return false, nil end
    local result = value :: {[string]: unknown}
    if result.version ~= 1 or result.request_id ~= request_id then return false, nil end
    local code = result.error_code
    local message = result.error
    if type(code) ~= "string" or type(message) ~= "string" then return false, "Invalid Agent checkpoint result" end
    if code ~= "" or message ~= "" then return false, message ~= "" and message or code end
    return true, nil
end

return M
