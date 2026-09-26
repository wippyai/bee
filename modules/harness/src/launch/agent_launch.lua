-- MIT. The host-named allow-list that decides which launch definitions a
-- managed agent may start, the durable identity of a caller's launch, and the
-- run identities its status, wait and cancel name. It is pure: it reads no
-- store, starts nothing and grants nothing.
local hash = require("hash")
local bounds = require("bounds")
local M = {}
M.MAX_WAIT_MS = 60000
type Run = {thread_id: string, attempt_id: string}
-- The action a caller's own scope must grant on a workspace other than its
-- binding's before it may launch there.
M.LAUNCH_ACTION = "bee.workspace.manager.launch"
-- The action a host grants an application on a launch definition before the
-- application may start it.
M.APPLICATION_ACTION = "bee.harness.launch"
M.MAX_ANSWER_BYTES = 16384
local function fields(value: unknown, allowed: {string}): string?
    return bounds.fields(value, allowed)
end
-- A run the caller started: its thread and attempt.
function M.decode_run(value: unknown, allowed: {string}): (Run?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown = fields(object, allowed)
    if unknown then return nil, unknown end
    local thread_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.attempt_id)
    if not thread_id then return nil, "thread_id is not an identifier" end
    if not attempt_id then return nil, "attempt_id is not an identifier" end
    return {thread_id = thread_id, attempt_id = attempt_id}, nil
end
-- Whether the caller's own launch policy admits starting this definition at
-- all. A definition absent from the host-owned list is refused by name. The
-- launch runs in the caller's own workspace unless the caller names another
-- its own scope may launch into.
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
-- Whether the caller's own launch policy explicitly permits a definition
-- whose CLI runs without a usable workdir confinement. A definition the
-- host records as unconfined is refused without this explicit host flag.
function M.unconfined_permitted(policy: {[string]: unknown}, definition_ref: string): (boolean, string?)
    local object = bounds.object(policy)
    if not object then return false, "launch policy is unavailable" end
    local rows = object.agent_launch_unconfined
    if type(rows) ~= "table" then return false, nil end
    for _, raw in ipairs(rows) do
        if bounds.id(raw) == definition_ref then return true, nil end
    end
    return false, nil
end
-- Whether every gateway tool a child definition's policy would offer is one
-- the launching parent's own policy already holds. A host may flag one
-- definition to admit a child whose tools exceed its parent's; without that
-- flag an agent never starts a child with a gateway surface its own policy
-- does not already carry.
function M.tools_within(child: {string}, parent: {string}): (boolean, string?)
    local held: {[string]: boolean} = {}
    for _, name in ipairs(parent) do held[name] = true end
    for _, name in ipairs(child) do
        if not held[name] then return false, name end
    end
    return true, nil
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
