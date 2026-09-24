-- MIT. Which workspace hosts a node keeps live. A pure record of the hosts a
-- node manager started, the leases that keep them live, when an unleased
-- host falls idle and which idle host was used least recently. The manager
-- process owns the effects; this module decides them.
type Host = {workspace_id: string, pid: string, phase: string, leases: {[string]: string}, lease_count: integer,
    used: integer, idle_at: number?, refused: boolean}
type State = {cap: integer, idle: number, hosts: {[string]: Host}, live: integer, sequence: integer,
    leases: {[string]: string}}
type Decision = {kind: string, evict: string?}

local M = {}
M.MAX_CAP = 1024

-- cap: live hosts at most; idle: seconds an unleased ready host stays live.
function M.new(cap: integer, idle: number): State
    return {cap = cap, idle = idle, hosts = {}, live = 0, sequence = 0, leases = {}}
end

local function touch(state: State, host: Host)
    state.sequence = state.sequence + 1
    host.used = state.sequence
end

local function hold(state: State, host: Host, lease: string, holder: string)
    if not host.leases[lease] then host.lease_count = host.lease_count + 1 end
    host.leases[lease] = holder
    host.idle_at = nil
    host.refused = false
    state.leases[lease] = host.workspace_id
    touch(state, host)
end

-- The least recently used ready host no lease holds.
local function idlest(state: State): Host?
    local selected: Host? = nil
    for _, host in pairs(state.hosts) do
        if host.phase == "ready" and host.lease_count == 0 and not host.refused and (not selected or host.used < selected.used) then
            selected = host
        end
    end
    return selected
end

-- A lease on a workspace. "ready": its host serves now; "wait": its host is
-- starting; "start": the caller spawns it now; "stopping": its host is
-- stopping and the request waits for the stop; "evict": the caller stops
-- the named idle host first and asks again; "full": every live host is leased.
-- Only "ready", "wait" and "start" record the lease.
function M.acquire(state: State, workspace_id: string, lease: string, holder: string): Decision
    local host = state.hosts[workspace_id]
    if host then
        if host.phase == "stopping" then return {kind = "stopping", evict = nil} end
        hold(state, host, lease, holder)
        if host.phase == "ready" then return {kind = "ready", evict = nil} end
        return {kind = "wait", evict = nil}
    end
    if state.live >= state.cap then
        local victim = idlest(state)
        if not victim then return {kind = "full", evict = nil} end
        victim.phase = "stopping"
        victim.idle_at = nil
        return {kind = "evict", evict = victim.workspace_id}
    end
    local created: Host = {workspace_id = workspace_id, pid = "", phase = "starting", leases = {}, lease_count = 0, used = 0, idle_at = nil,
        refused = false}
    state.hosts[workspace_id] = created
    state.live = state.live + 1
    hold(state, created, lease, holder)
    return {kind = "start", evict = nil}
end

function M.started(state: State, workspace_id: string, pid: string)
    local host = state.hosts[workspace_id]
    if host then host.pid = pid end
end

-- The host announced readiness. A host whose every lease ended while it
-- started begins its idle period now.
function M.ready(state: State, workspace_id: string, now: number)
    local host = state.hosts[workspace_id]
    if not host or host.phase ~= "starting" then return end
    host.phase = "ready"
    if host.lease_count == 0 then host.idle_at = now + state.idle end
end

-- End one lease; the workspace it held, if any.
function M.release(state: State, lease: string, now: number): string?
    local workspace_id = state.leases[lease]
    if not workspace_id then return nil end
    state.leases[lease] = nil
    local host = state.hosts[workspace_id]
    if not host then return workspace_id end
    if host.leases[lease] then
        host.leases[lease] = nil
        host.lease_count = host.lease_count - 1
    end
    if host.lease_count == 0 and host.phase == "ready" then host.idle_at = now + state.idle end
    return workspace_id
end

-- Every lease a holder held ends when the holder exits.
function M.holder_exited(state: State, holder: string, now: number)
    local ended: {string} = {}
    for _, host in pairs(state.hosts) do
        for lease, owner in pairs(host.leases) do
            if owner == holder then ended[#ended + 1] = lease end
        end
    end
    for _, lease in ipairs(ended) do M.release(state, lease, now) end
end

function M.held(state: State, lease: string): string?
    return state.leases[lease]
end

function M.holder(state: State, lease: string): string?
    local workspace_id = state.leases[lease]
    local host = workspace_id and state.hosts[workspace_id] or nil
    return host and host.leases[lease] or nil
end

-- Ready hosts whose idle period has ended; each is marked stopping.
function M.due(state: State, now: number): {string}
    local stopping: {string} = {}
    for _, host in pairs(state.hosts) do
        if host.phase == "ready" and host.lease_count == 0 and host.idle_at and host.idle_at <= now then
            host.phase = "stopping"
            host.idle_at = nil
            stopping[#stopping + 1] = host.workspace_id
        end
    end
    table.sort(stopping)
    return stopping
end

function M.next_deadline(state: State): number?
    local deadline: number? = nil
    for _, host in pairs(state.hosts) do
        if host.idle_at and (not deadline or host.idle_at < deadline) then deadline = host.idle_at end
    end
    return deadline
end

-- The host is gone: stopped, failed to start or exited. Its leases end.
function M.gone(state: State, workspace_id: string)
    local host = state.hosts[workspace_id]
    if not host then return end
    for lease in pairs(host.leases) do state.leases[lease] = nil end
    state.hosts[workspace_id] = nil
    state.live = state.live - 1
end

-- A stop the host refused leaves it serving. It is neither stopped when idle
-- nor evicted until a new lease on it ends, so a refused stop is never
-- retried blindly.
function M.stop_refused(state: State, workspace_id: string)
    local host = state.hosts[workspace_id]
    if host and host.phase == "stopping" then
        host.phase = "ready"
        host.refused = true
    end
end

function M.host(state: State, workspace_id: string): Host?
    return state.hosts[workspace_id]
end

return M
