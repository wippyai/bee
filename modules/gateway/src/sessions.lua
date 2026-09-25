-- MIT. Session discovery values, pure. A session is one running managed
-- agent: the live binding of an action, under its newest carrier epoch.
-- An address names a session by its action, by one of its attempts, or by
-- its thread when that thread holds exactly one running session. Nothing
-- here reads a store or decides who may see or reach a session; the thread
-- owner's membership rules do.
local M = {}
M.MAX_SESSIONS = 64
type Candidate = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, carrier_epoch: integer, name: string?}
type View = {session: string, action_id: string, attempt_id: string, thread_id: string, title: string, self: boolean}
type Address = {node_id: string, action_id: string}
type DirectoryCandidate = {session: Candidate, node_id: string, name: string, grant_epoch: integer, discoverable: boolean, sendable: boolean?, attempt_state: string?, delivery_state: string?, last_inbox_sequence: integer?}
type DirectoryView = {name: string, address: Address, action_id: string, attempt_id: string, grant_epoch: integer, sendable: boolean, self: boolean, attempt_state: string?, delivery_state: string?, last_inbox_sequence: integer?}
-- One candidate per action, the newest carrier epoch winning, ordered by
-- thread and then action so a listing is stable across calls.
function M.latest(candidates: {Candidate}): {Candidate}
    local by_action: {[string]: Candidate} = {}
    for _, item in ipairs(candidates) do
        local held = by_action[item.action_id]
        if not held or item.carrier_epoch > held.carrier_epoch then by_action[item.action_id] = item end
    end
    local result: {Candidate} = {}
    for _, item in pairs(by_action) do result[#result + 1] = item end
    table.sort(result, function(left: Candidate, right: Candidate): boolean
        if left.thread_id ~= right.thread_id then return left.thread_id < right.thread_id end
        return left.action_id < right.action_id
    end)
    return result
end
-- Resolves an address among visible sessions: an action first, then an
-- attempt, then a thread with one session. Returns the session, or a code
-- and message naming why none was chosen.
function M.resolve(candidates: {Candidate}, address: string): (Candidate?, string?, string?)
    for _, item in ipairs(candidates) do
        if item.action_id == address then return item, nil, nil end
    end
    for _, item in ipairs(candidates) do
        if item.attempt_id == address then return item, nil, nil end
    end
    local on_thread: {Candidate} = {}
    for _, item in ipairs(candidates) do
        if item.thread_id == address then on_thread[#on_thread + 1] = item end
    end
    if #on_thread == 1 then return on_thread[1], nil, nil end
    if #on_thread > 1 then
        local actions: {string} = {}
        for index, item in ipairs(on_thread) do actions[index] = item.action_id end
        return nil, "AMBIGUOUS", "thread " .. address .. " holds " .. tostring(#on_thread) .. " running sessions; name one by action: " .. table.concat(actions, ", ")
    end
    return nil, "NOT_FOUND", "no running session you can reach is named " .. address
end
function M.view(item: Candidate, title: string, self_action_id: string): View
    return {session = item.action_id, action_id = item.action_id, attempt_id = item.attempt_id, thread_id = item.thread_id, title = title, self = item.action_id == self_action_id}
end
-- A stable cursor page over an already ordered view list. The cursor is an
-- offset into that order; the reply names the next cursor or its absence.
function M.page(views: {unknown}, cursor: integer, limit: integer): {items: {unknown}, next_cursor: integer?, eof: boolean}
    local items: {unknown} = {}
    local start = cursor + 1
    for index = start, math.min(start + limit - 1, #views) do items[#items + 1] = views[index] end
    local consumed = cursor + #items
    return {items = items, next_cursor = consumed < #views and consumed or nil, eof = consumed >= #views}
end
-- The MCP paging arguments both session listings share, decoded once here so
-- the advertised schema and the accepted cursor cannot drift apart.
M.PAGE_DEFAULT = 32
function M.page_schema(): {[string]: unknown}
    return {cursor = {type = "integer", minimum = 0,
            description = "offset into the stable session order; omit for the first page"},
        limit = {type = "integer", minimum = 1, maximum = M.MAX_SESSIONS,
            description = "page size, at most " .. tostring(M.MAX_SESSIONS)}}
end
-- The owner supplies discoverability and current acceptance epoch. A send
-- grant alone never makes a peer appear in the directory.
function M.directory(peers: {DirectoryCandidate}, self_action_id: string): {DirectoryView}
    local result: {DirectoryView} = {}
    for _, peer in ipairs(peers) do
        local item = peer.session
        if peer.discoverable or item.action_id == self_action_id then
            result[#result + 1] = {name = peer.name, address = {node_id = peer.node_id, action_id = item.action_id},
                action_id = item.action_id, attempt_id = item.attempt_id, grant_epoch = peer.grant_epoch,
                sendable = peer.sendable == true, self = item.action_id == self_action_id,
                attempt_state = peer.attempt_state, delivery_state = peer.delivery_state, last_inbox_sequence = peer.last_inbox_sequence}
        end
    end
    table.sort(result, function(left: DirectoryView, right: DirectoryView): boolean
        if left.name ~= right.name then return left.name < right.name end
        if left.address.node_id ~= right.address.node_id then return left.address.node_id < right.address.node_id end
        return left.action_id < right.action_id
    end)
    return result
end
return M
