-- MIT. Removal of a closed session: every owner forgets what it keeps only
-- for the session, then the journal deletes the session itself. Its thread
-- and records go too when the removal asked for its history and no one else
-- takes part in the thread; otherwise they stay. The agent's own files stay.
local bounds = require("bounds")
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local journal = require("journal")
local M = {}

type Object = {[string]: unknown}

-- A function declaring this type forgets what its owner keeps for one
-- removed session. It takes {session, thread_id, owner_id, history}, where
-- history says the session's thread is removed with it, and answers
-- {ok, value} or {ok = false, error}; a repeated call forgets nothing.
M.FORGET = "bee.sessions.forget"

local function failure(target: string, raw: unknown, call_error: unknown): string?
    if call_error then return target .. ": " .. tostring(call_error) end
    local reply = bounds.object(raw)
    if not reply then return target .. " returned a malformed reply" end
    if reply.ok == true then return nil end
    local fault = bounds.object(reply.error)
    return target .. ": " .. tostring(fault and (fault.message or fault.code) or "refused")
end

-- forgetters lists every admitted function that forgets session state,
-- in a stable order.
local function forgetters(): ({string}?, string?)
    local found, find_error = registry.find({[".kind"] = "function.lua", ["meta.type"] = M.FORGET})
    if find_error or not found then return nil, "session forgetters are unreadable: " .. tostring(find_error) end
    local targets: {string} = {}
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local id = entry and bounds.id(entry.id)
        if id then targets[#targets + 1] = id end
    end
    table.sort(targets)
    return targets, nil
end

-- session_owner restores the actor that owns the session; each forgetter
-- answers that owner, as placement answers only the owner of its attempts.
local function session_owner(route: Object): (security.Actor?, string?, string?)
    local owner, workspace = bounds.id(route.owner_id), bounds.id(route.workspace_id)
    if not owner or not workspace then return nil, nil, "session route has no workspace-bound owner" end
    local actor, actor_error = security.new_actor(owner, {workspace_id = workspace})
    if not actor then return nil, nil, "session owner cannot be restored: " .. tostring(actor_error) end
    return actor, owner, nil
end

-- complete removes the closed session stored describes. operation_key keys
-- the journal removal; a repeated completion forgets nothing twice.
function M.complete(stored: Object, operation_key: string): (Object?, string?)
    local session, thread = bounds.id(stored.session), bounds.id(stored.thread_ref)
    local route = bounds.object(stored.route) or {}
    if not session or not thread then return nil, "session snapshot omits its identity" end
    local actor, owner, owner_error = session_owner(route)
    if not actor or not owner then return nil, owner_error end
    local history = stored.removal_history == true and stored.thread_shared ~= true
    local targets, targets_error = forgetters()
    if not targets then return nil, targets_error end
    for _, target in ipairs(targets) do
        local raw, call_error = funcs.new():with_actor(actor):call(target, {session = session, thread_id = thread, owner_id = owner, history = history})
        local refused = failure(target, raw, call_error)
        if refused then return nil, refused end
    end
    local removed, remove_error = journal.invoke("session_remove", {session = session, operation_key = operation_key, delete = true})
    if remove_error or not removed then return nil, remove_error or "Threads returned no removal receipt" end
    return bounds.object(removed), nil
end

return M
