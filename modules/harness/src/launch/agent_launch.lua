-- MIT. The bounded request of an agent-started launch and the host-named
-- allow-list that decides which launch definitions a managed agent may
-- start. It is pure: it reads no store, starts nothing and grants nothing.
local hash = require("hash")
local bounds = require("bounds")
local M = {}
M.MAX_BRIEF_BYTES = 16384
M.MAX_KEY_BYTES = 64
type Request = {definition_ref: string, brief: string, idempotency_key: string}
local function fields(value: unknown, allowed: {string}): string?
    return bounds.fields(value, allowed)
end
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown = fields(object, {"definition_ref", "brief", "idempotency_key"})
    if unknown then return nil, unknown end
    local definition_ref = bounds.id(object.definition_ref)
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    local brief = bounds.text(object.brief, M.MAX_BRIEF_BYTES)
    if not brief or brief == "" then return nil, "brief must be nonempty bounded text" end
    local idempotency_key = bounds.id(object.idempotency_key)
    if not idempotency_key or #idempotency_key > M.MAX_KEY_BYTES then return nil, "idempotency_key is not a bounded identifier" end
    return {definition_ref = definition_ref, brief = brief, idempotency_key = idempotency_key}, nil
end
-- Whether the caller's own launch policy admits starting this definition at
-- all. A definition absent from the host-owned list is refused by name. The
-- launch runs in the caller's own workspace, never one a tool argument names.
function M.permitted(policy: {[string]: unknown}, definition_ref: string): (boolean, string?)
    local object = bounds.object(policy)
    if not object then return false, "launch policy is unavailable" end
    local rows = object.agent_launch
    if type(rows) ~= "table" then return false, nil end
    for _, raw in ipairs(rows) do
        if bounds.id(raw) == definition_ref then return true, nil end
    end
    return false, nil
end
-- The child's durable request identity: the caller's own action and the
-- retry key, so the same call replays the same child action and attempt and a
-- different brief under the same key conflicts instead of starting twice.
function M.request_id(action_id: string, idempotency_key: string): (string?, string?)
    local digest, hash_error = hash.sha256(action_id .. "\n" .. idempotency_key)
    if hash_error or not digest then return nil, "request identity failed" end
    return "agent-launch:" .. digest:sub(1, 32), nil
end
return M
