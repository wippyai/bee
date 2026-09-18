-- MIT. Bounded pure typed peer state library for Bee Hive supervisor peer exchange.
-- No process or registry I/O; identity and payloads are validated through types and bounds.
local types = require("types")
local bounds = require("bounds")

local M = {}

M.CAP_MAX_NODES = 64
M.CAP_MAX_PENDING = 64
M.CAP_MAX_PEERS = 64
local MAX_TTL_MS = 60000
local MAX_TIME_MS = 9007199254680991

type Peer = {
    node_id: string,
    pid: string,
    supervisor_incarnation: string,
    established_at: integer,
    local_challenge: string?,
    remote_challenge: string?,
    answer_on_retry: boolean,
}

type Transition = {
    node_id: string,
    old_peer: Peer?,
    new_peer: Peer,
}

type PendingExchange = {
    node_id: string,
    pid: string,
    local_challenge: string,
    remote_challenge: string?,
    peer_incarnation: string?,
    created_at: integer,
    expires_at: integer,
    role: string,
    answered_remote: boolean,
    outbound_hello: types.Hello,
}

type Config = {
    local_node: string,
    local_incarnation: string,
    configured_nodes: {string},
    ttl_ms: integer,
    max_peers: integer?,
    max_pending: integer?,
}

type State = {
    local_node: string,
    local_incarnation: string,
    configured_nodes: {[string]: boolean},
    ttl_ms: integer,
    max_peers: integer,
    max_pending: integer,
    active: {[string]: Peer},
    pending: {[string]: PendingExchange},
    active_count: integer,
    pending_count: integer,
    last_time_ms: integer,
}

type PendingInfo = {
    node_id: string,
    pid: string,
    local_challenge: string,
    remote_challenge: string?,
    peer_incarnation: string?,
    created_at: integer,
    expires_at: integer,
    role: string,
}

local function clone_peer(peer: Peer): Peer
    return {
        node_id = peer.node_id,
        pid = peer.pid,
        supervisor_incarnation = peer.supervisor_incarnation,
        established_at = peer.established_at,
        local_challenge = peer.local_challenge,
        remote_challenge = peer.remote_challenge,
        answer_on_retry = peer.answer_on_retry,
    }
end

local function copy_peer(peer: Peer?): Peer?
    if not peer then return nil end
    return clone_peer(peer)
end

local function copy_hello(hello: types.Hello?): types.Hello?
    if not hello then return nil end
    return {
        protocol_revision = hello.protocol_revision,
        supervisor_incarnation = hello.supervisor_incarnation,
        challenge = hello.challenge,
        response = hello.response,
    }
end

local function is_nonce_in_use(state: State, nonce: string): boolean
    for _, p in pairs(state.pending) do
        if p.local_challenge == nonce or p.remote_challenge == nonce then
            return true
        end
    end
    for _, a in pairs(state.active) do
        if a.local_challenge == nonce or a.remote_challenge == nonce then
            return true
        end
    end
    return false
end

local function clock_value(state: State, value: integer): (integer?, string?)
    local now = bounds.integer(value)
    if not now or now < 0 or now > MAX_TIME_MS then
        return nil, "nowMS must be a bounded non-negative integer"
    end
    if now < state.last_time_ms then return nil, "nowMS moved backwards" end
    state.last_time_ms = now
    return now, nil
end

function M.new(config: Config): (State?, string?)
    local cfg = bounds.object(config)
    if not cfg then return nil, "config must be an object" end
    local unknown_field = bounds.fields(cfg, {"local_node", "local_incarnation", "configured_nodes", "ttl_ms", "max_peers", "max_pending"})
    if unknown_field then return nil, unknown_field end

    local local_node = bounds.id(cfg.local_node)
    if not local_node then return nil, "local_node is not an identifier" end

    local local_incarnation = bounds.id(cfg.local_incarnation)
    if not local_incarnation then return nil, "local_incarnation is not an identifier" end

    local ttl = bounds.integer(cfg.ttl_ms)
    if not ttl or ttl <= 0 then return nil, "ttl_ms must be a positive integer" end
    if ttl > MAX_TTL_MS then return nil, "ttl_ms exceeds 60000 milliseconds" end

    local nodes, nodes_err = bounds.ids(cfg.configured_nodes)
    if not nodes then return nil, "configured_nodes: " .. tostring(nodes_err) end
    if #nodes > M.CAP_MAX_NODES then return nil, "configured_nodes exceeds cap " .. tostring(M.CAP_MAX_NODES) end

    local configured_set: {[string]: boolean} = {}
    for _, node_id in ipairs(nodes) do
        if node_id == local_node then
            return nil, "configured_nodes cannot contain local_node"
        end
        if configured_set[node_id] then
            return nil, "duplicate configured node: " .. node_id
        end
        configured_set[node_id] = true
    end

    local max_peers = M.CAP_MAX_PEERS
    if cfg.max_peers ~= nil then
        local mp = bounds.integer(cfg.max_peers)
        if not mp or mp <= 0 or mp > M.CAP_MAX_PEERS then
            return nil, "max_peers must be between 1 and " .. tostring(M.CAP_MAX_PEERS)
        end
        max_peers = mp
    end

    local max_pending = M.CAP_MAX_PENDING
    if cfg.max_pending ~= nil then
        local mp = bounds.integer(cfg.max_pending)
        if not mp or mp <= 0 or mp > M.CAP_MAX_PENDING then
            return nil, "max_pending must be between 1 and " .. tostring(M.CAP_MAX_PENDING)
        end
        max_pending = mp
    end

    local state: State = {
        local_node = local_node,
        local_incarnation = local_incarnation,
        configured_nodes = configured_set,
        ttl_ms = ttl,
        max_peers = max_peers,
        max_pending = max_pending,
        active = {},
        pending = {},
        active_count = 0,
        pending_count = 0,
        last_time_ms = 0,
    }
    return state, nil
end

function M.begin(state: State, node: string, exactPID: string, freshNonce: string, nowMS: integer): (types.Hello?, string?)
    local now, clock_error = clock_value(state, nowMS)
    if not now then return nil, clock_error end

    local target_node = bounds.id(node)
    if not target_node then return nil, "node is not an identifier" end
    if not state.configured_nodes[target_node] then return nil, "target node is not configured" end
    if target_node == state.local_node then return nil, "cannot begin exchange with local node" end

    if type(exactPID) ~= "string" then return nil, "exactPID must be a string" end
    local pid_node, pid_host = types.pid_parts(exactPID)
    if not pid_node or not pid_host then return nil, "invalid exactPID format" end
    if pid_node ~= target_node then return nil, "exactPID node does not match target node" end
    if pid_host ~= types.SUPERVISOR_HOST then return nil, "exactPID host is not supervisor host" end

    local nonce = bounds.id(freshNonce)
    if not nonce then return nil, "freshNonce is not an identifier" end
    if is_nonce_in_use(state, nonce) then return nil, "nonce already in use in live state" end

    local existing = state.pending[target_node]
    if existing then
        if now >= existing.expires_at then
            state.pending[target_node] = nil
            state.pending_count = state.pending_count - 1
        else
            return nil, "pending exchange already in progress for node"
        end
    end

    if state.pending_count >= state.max_pending then
        return nil, "pending exchange capacity reached"
    end

    local outbound: types.Hello = {
        protocol_revision = types.REVISION,
        supervisor_incarnation = state.local_incarnation,
        challenge = nonce,
        response = nil,
    }
    state.pending[target_node] = {
        node_id = target_node,
        pid = exactPID,
        local_challenge = nonce,
        remote_challenge = nil,
        peer_incarnation = nil,
        created_at = now,
        expires_at = nowMS + state.ttl_ms,
        role = "initiator",
        answered_remote = false,
        outbound_hello = outbound,
    }
    state.pending_count = state.pending_count + 1

    return copy_hello(outbound), nil
end

function M.receive(state: State, actualSenderPID: string, unknownHello: unknown, freshNonce: string?, nowMS: integer): (types.Hello?, Transition?, string?)
    local now, clock_error = clock_value(state, nowMS)
    if not now then return nil, nil, clock_error end

    if type(actualSenderPID) ~= "string" then return nil, nil, "actualSenderPID must be a string" end
    local sender_node, sender_host = types.pid_parts(actualSenderPID)
    if not sender_node or not sender_host or sender_node == "" then
        return nil, nil, "invalid sender PID format"
    end

    if sender_host ~= types.SUPERVISOR_HOST then
        return nil, nil, "sender host is not supervisor host"
    end

    if sender_node == state.local_node then
        return nil, nil, "sender node cannot be local node"
    end

    if not state.configured_nodes[sender_node] then
        return nil, nil, "sender node is not configured"
    end

    -- Reject malformed payload before allocating any state
    local hello, decode_err = types.decode_hello(unknownHello)
    if not hello then
        return nil, nil, decode_err or "malformed hello payload"
    end

    -- Expire any stale pending exchange for sender_node
    local pending = state.pending[sender_node]
    if pending then
        if now >= pending.expires_at then
            state.pending[sender_node] = nil
            state.pending_count = state.pending_count - 1
            pending = nil
        end
    end

    local active = state.active[sender_node]

    if pending and hello.challenge == pending.local_challenge then
        return nil, nil, "peer challenge reflects local challenge"
    end

    -- Replay only the completed transcript. Keep any replacement candidate
    -- intact, and do not refresh establishment time or allocate another slot.
    if active and active.pid == actualSenderPID
        and active.supervisor_incarnation == hello.supervisor_incarnation
        and active.remote_challenge == hello.challenge then
        local local_challenge = active.local_challenge
        if local_challenge then
            if hello.response == nil or (hello.response == local_challenge and active.answer_on_retry) then
                return {
                    protocol_revision = types.REVISION,
                    supervisor_incarnation = state.local_incarnation,
                    challenge = local_challenge,
                    response = hello.challenge,
                }, nil, nil
            end
            if hello.response == local_challenge then return nil, nil, nil end
        end
    end

    -- Branch based on whether hello contains a response
    if hello.response == nil then
        -- Initial incoming hello
        if pending then
            if pending.remote_challenge ~= nil then
                -- Already answered an initial hello; check if duplicate of same initial hello
                if pending.pid == actualSenderPID
                    and pending.peer_incarnation == hello.supervisor_incarnation
                    and pending.remote_challenge == hello.challenge then
                    -- Duplicate same initial replays same response with no new nonce/state/deadline
                    return copy_hello(pending.outbound_hello), nil, nil
                else
                    return nil, nil, "pending exchange in progress with different parameters"
                end
            else
                -- We are initiator (simultaneous begin!)
                if pending.pid ~= actualSenderPID then
                    return nil, nil, "sender PID does not match pending exchange PID"
                end
                local outbound: types.Hello = {
                    protocol_revision = types.REVISION,
                    supervisor_incarnation = state.local_incarnation,
                    challenge = pending.local_challenge,
                    response = hello.challenge,
                }
                pending.remote_challenge = hello.challenge
                pending.peer_incarnation = hello.supervisor_incarnation
                pending.answered_remote = true
                pending.outbound_hello = outbound
                return copy_hello(outbound), nil, nil
            end
        else
            -- No pending exchange: candidate responder
            if state.pending_count >= state.max_pending then
                return nil, nil, "pending exchange capacity reached"
            end
            local nonce = freshNonce and bounds.id(freshNonce)
            if not nonce then return nil, nil, "freshNonce is required and must be an identifier" end
            if nonce == hello.challenge then return nil, nil, "local and peer challenges must differ" end
            if is_nonce_in_use(state, nonce) then return nil, nil, "nonce already in use in live state" end

            local outbound: types.Hello = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = state.local_incarnation,
                challenge = nonce,
                response = hello.challenge,
            }
            state.pending[sender_node] = {
                node_id = sender_node,
                pid = actualSenderPID,
                local_challenge = nonce,
                remote_challenge = hello.challenge,
                peer_incarnation = hello.supervisor_incarnation,
                created_at = now,
                expires_at = nowMS + state.ttl_ms,
                role = "responder",
                answered_remote = true,
                outbound_hello = outbound,
            }
            state.pending_count = state.pending_count + 1

            return copy_hello(outbound), nil, nil
        end
    else
        -- Hello contains a response
        if not pending then
            return nil, nil, "unsolicited or unexpected response"
        end

        -- Pending exchange exists
        if pending.pid ~= actualSenderPID then
            return nil, nil, "sender PID does not match pending exchange PID"
        end

        if hello.response ~= pending.local_challenge then
            return nil, nil, "response does not match pending challenge"
        end

        if pending.peer_incarnation ~= nil and pending.peer_incarnation ~= hello.supervisor_incarnation then
            return nil, nil, "supervisor_incarnation does not match pending exchange"
        end

        if pending.remote_challenge ~= nil and pending.remote_challenge ~= hello.challenge then
            return nil, nil, "challenge does not match recorded peer challenge"
        end

        if pending.peer_incarnation == nil then
            -- Initiator learning remote peer incarnation & challenge
            pending.peer_incarnation = hello.supervisor_incarnation
            pending.remote_challenge = hello.challenge
        end

        -- Check capacity if establishing new active peer
        local old_peer = state.active[sender_node]
        if not old_peer and state.active_count >= state.max_peers then
            return nil, nil, "active peer capacity reached"
        end

        local outbound: types.Hello? = nil
        if not pending.answered_remote then
            local my_challenge = bounds.id(pending.local_challenge)
            if not my_challenge then return nil, nil, "missing pending challenge" end
            outbound = {
                protocol_revision = types.REVISION,
                supervisor_incarnation = state.local_incarnation,
                challenge = my_challenge,
                response = hello.challenge,
            }
            pending.answered_remote = true
        end

        local new_peer: Peer = {
            node_id = sender_node,
            pid = actualSenderPID,
            supervisor_incarnation = hello.supervisor_incarnation,
            established_at = now,
            local_challenge = pending.local_challenge,
            remote_challenge = hello.challenge,
            answer_on_retry = outbound ~= nil,
        }
        state.active[sender_node] = new_peer
        if not old_peer then
            state.active_count = state.active_count + 1
        end

        state.pending[sender_node] = nil
        state.pending_count = state.pending_count - 1

        local transition: Transition = {
            node_id = sender_node,
            old_peer = copy_peer(old_peer),
            new_peer = clone_peer(new_peer),
        }

        return copy_hello(outbound), transition, nil
    end
end

function M.expire(state: State, nowMS: integer): (integer, string?)
    local now, clock_error = clock_value(state, nowMS)
    if not now then return 0, clock_error end
    local expired_count = 0
    for node_id, p in pairs(state.pending) do
        if now >= p.expires_at then
            state.pending[node_id] = nil
            state.pending_count = state.pending_count - 1
            expired_count = expired_count + 1
        end
    end
    return expired_count, nil
end

-- Native connection loss invalidates both an established peer and its exchange.
-- The actor separately retires routes and retains charges for running workers.
function M.forget(state: State, node: string): Peer?
    local previous = state.active[node]
    if previous then
        state.active[node] = nil
        state.active_count = state.active_count - 1
    end
    if state.pending[node] then
        state.pending[node] = nil
        state.pending_count = state.pending_count - 1
    end
    return copy_peer(previous)
end

function M.current(state: State, node: string): Peer?
    local id = bounds.id(node)
    if not id then return nil end
    return copy_peer(state.active[id])
end

function M.pending(state: State, node: string): PendingInfo?
    local id = bounds.id(node)
    if not id then return nil end
    local p = state.pending[id]
    if not p then return nil end
    return {
        node_id = p.node_id,
        pid = p.pid,
        local_challenge = p.local_challenge,
        remote_challenge = p.remote_challenge,
        peer_incarnation = p.peer_incarnation,
        created_at = p.created_at,
        expires_at = p.expires_at,
        role = p.role,
    }
end

function M.is_configured(state: State, node: string): boolean
    local id = bounds.id(node)
    if not id then return false end
    return state.configured_nodes[id] == true
end

function M.active_peers(state: State): {Peer}
    local result: {Peer} = {}
    for _, a in pairs(state.active) do
        local cp = copy_peer(a)
        if cp then
            result[#result + 1] = cp
        end
    end
    return result
end

return M
