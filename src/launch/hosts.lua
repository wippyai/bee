-- MIT. Which workspace hosts a node keeps live. A pure record of the hosts a
-- node manager started, the leases that keep them live, when an unleased
-- host falls idle, which idle host was used least recently, and which lease
-- holders admit desktops through the manager. The manager process owns the
-- effects; this module decides them.
-- attached: holders that admit desktops through the manager; recipients: the
-- holder that admitted each desktop client; requests: the holder awaiting
-- each relayed request's result.
type Host = {workspace_id: string, pid: string, phase: string, leases: {[string]: string}, lease_count: integer,
    used: integer, idle_at: number?, refused: boolean, attached: {[string]: boolean}, recipients: {[string]: string},
    requests: {[string]: string}, pending: integer}
type State = {cap: integer, idle: number, hosts: {[string]: Host}, live: integer, sequence: integer,
    leases: {[string]: string}}
type Decision = {kind: string, evict: string?}

local M = {}
M.MAX_CAP = 1024
-- Relayed requests one host may have outstanding.
M.MAX_RELAYED = 256

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
        refused = false, attached = {}, recipients = {}, requests = {}, pending = 0}
    state.hosts[workspace_id] = created
    state.live = state.live + 1
    hold(state, created, lease, holder)
    return {kind = "start", evict = nil}
end

function M.started(state: State, workspace_id: string, pid: string)
    local host = state.hosts[workspace_id]
    if host then host.pid = pid end
end
-- Keep live leases and attached holders while a failed code handoff replaces
-- the host. Old client routes belonged to the departed host and cannot be
-- forwarded to the new one until each holder admits its desktop again.
function M.replacing(state: State, workspace_id: string)
    local host = state.hosts[workspace_id]
    if not host then return end
    host.phase, host.pid, host.idle_at = "starting", "", nil
    host.recipients, host.requests, host.pending = {}, {}, 0
end

-- The host announced readiness. A host whose every lease ended while it
-- started begins its idle period now.
function M.ready(state: State, workspace_id: string, now: number)
    local host = state.hosts[workspace_id]
    if not host or host.phase ~= "starting" then return end
    host.phase = "ready"
    if host.lease_count == 0 then host.idle_at = now + state.idle end
end

local function holds(host: Host, holder: string): boolean
    for _, owner in pairs(host.leases) do
        if owner == holder then return true end
    end
    return false
end

-- A holder without a lease on the host keeps no relay state there.
local function detach_holder(host: Host, holder: string)
    host.attached[holder] = nil
    for recipient, owner in pairs(host.recipients) do
        if owner == holder then host.recipients[recipient] = nil end
    end
    for request_id, owner in pairs(host.requests) do
        if owner == holder then
            host.requests[request_id] = nil
            host.pending = host.pending - 1
        end
    end
end

-- End one lease; the workspace it held, if any.
function M.release(state: State, lease: string, now: number): string?
    local workspace_id = state.leases[lease]
    if not workspace_id then return nil end
    state.leases[lease] = nil
    local host = state.hosts[workspace_id]
    if not host then return workspace_id end
    local holder = host.leases[lease]
    if holder then
        host.leases[lease] = nil
        host.lease_count = host.lease_count - 1
        if not holds(host, holder) then detach_holder(host, holder) end
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

-- A holder of a lease on a ready host admits desktops through the manager
-- from now on. The manager is the host's owner and the only sender the host
-- accepts desktop admission from.
function M.attach(state: State, workspace_id: string, holder: string): boolean
    local host = state.hosts[workspace_id]
    if not host or host.phase ~= "ready" or not holds(host, holder) then return false end
    host.attached[holder] = true
    return true
end

-- The host pid to forward one desktop admission request to, or nil when the
-- holder may not make it: it must be attached to the ready host, and a
-- recipient another holder admitted stays that holder's.
function M.relay(state: State, workspace_id: string, holder: string, request_id: string, op: string, recipient: string): string?
    local host = state.hosts[workspace_id]
    if not host or host.phase ~= "ready" or not host.attached[holder] or request_id == "" then return nil end
    if host.requests[request_id] or host.pending >= M.MAX_RELAYED then return nil end
    local owner = host.recipients[recipient]
    if owner and owner ~= holder then return nil end
    if not owner and op ~= "admit" then return nil end
    host.recipients[recipient] = holder
    host.requests[request_id] = holder
    host.pending = host.pending + 1
    return host.pid
end

-- The holder a host's client result belongs to: the one that made the
-- request, or, for a release the host started itself, the one that admitted
-- the recipient. A release that took effect ends the recipient's route.
function M.route(state: State, workspace_id: string, request_id: string, op: string, recipient: string, released: boolean): string?
    local host = state.hosts[workspace_id]
    if not host then return nil end
    local holder: string? = nil
    if request_id ~= "" and host.requests[request_id] then
        holder = host.requests[request_id]
        host.requests[request_id] = nil
        host.pending = host.pending - 1
    elseif request_id == "" then
        holder = host.recipients[recipient]
    end
    if holder and op == "detach" and released and host.recipients[recipient] == holder then host.recipients[recipient] = nil end
    return holder
end

return M
