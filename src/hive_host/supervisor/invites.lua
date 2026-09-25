-- MIT. Hive invites held by the supervisor. An invite admits one node to this
-- node's hive: it is minted and revoked by an admitted local client, redeemed
-- once by the native join listener, and refused when used, revoked, expired or
-- unknown. The supervisor keeps only the secret's digest. This library is pure:
-- the caller supplies identities, digests and clocks, and owns every side effect.
local bounds = require("bounds")
local M = {}
M.SERVICE = "bee.hive.join"
M.INVITE = "bee.hive.join:invite"
M.LIST = "bee.hive.join:invites"
M.REVOKE = "bee.hive.join:revoke"
M.PEERS = "bee.hive.join:peers"
M.REDEEM = "bee.hive.join:redeem"
-- JOIN_HOST is the native host of the owner's join listener. The runtime
-- derives a sender's host from the actual sending process, and no Lua process
-- can run on it, so only the listener can redeem.
M.JOIN_HOST = "bee.hive:join_host"
-- ACTION is the host-named permission the supervisor needs for every invite
-- operation; without the host policy no invite is minted or redeemed.
M.ACTION = "hive.invite"
M.LIFETIME_MS = 15 * 60 * 1000
M.CAP = 64
type Status = "pending" | "used" | "revoked" | "expired"
type Invite = {invite_id: string, digest: string, expires_ms: integer, expires_at: string, status: Status, node_id: string?}
type View = {invite_id: string, status: Status, expires_at: string, node_id: string?}
type State = {invites: {[string]: Invite}, order: {string}}
type Input = {invite_id: string?, secret: string?, node_id: string?}

local function hex(value: unknown, size: integer): string?
    if type(value) ~= "string" or #value ~= size or value:find("[^0-9a-f]") then return nil end
    return value
end
function M.invite_id(value: unknown): string? return hex(value, 32) end
function M.secret(value: unknown): string? return hex(value, 64) end

function M.new(): State
    return {invites = {}, order = {}}
end

local function view(invite: Invite): View
    return {invite_id = invite.invite_id, status = invite.status, expires_at = invite.expires_at, node_id = invite.node_id}
end

-- refresh marks every pending invite past its lifetime as expired.
local function refresh(state: State, now_ms: integer)
    for _, invite in pairs(state.invites) do
        if invite.status == "pending" and now_ms >= invite.expires_ms then invite.status = "expired" end
    end
end

-- mint records a fresh pending invite. At capacity the oldest settled record is
-- dropped; pending invites are never evicted, so capacity refuses instead.
function M.mint(state: State, invite_id: string, digest: string, now_ms: integer, expires_at: string): (View?, string?)
    if not M.invite_id(invite_id) then return nil, "invite_id must be 32 lowercase hexadecimal characters" end
    if not hex(digest, 64) then return nil, "digest must be 64 lowercase hexadecimal characters" end
    if not bounds.timestamp(expires_at) then return nil, "expires_at must be a canonical UTC timestamp" end
    if state.invites[invite_id] then return nil, "invite_id is already recorded" end
    refresh(state, now_ms)
    if #state.order >= M.CAP then
        local evicted = false
        for position, id in ipairs(state.order) do
            local settled = state.invites[id]
            if settled and settled.status ~= "pending" then
                state.invites[id] = nil
                table.remove(state.order, position)
                evicted = true
                break
            end
        end
        if not evicted then return nil, "pending invite capacity reached" end
    end
    local invite: Invite = {invite_id = invite_id, digest = digest, expires_ms = now_ms + M.LIFETIME_MS, expires_at = expires_at, status = "pending"}
    state.invites[invite_id] = invite
    state.order[#state.order + 1] = invite_id
    return view(invite), nil
end

-- list returns every recorded invite in mint order with its current status.
function M.list(state: State, now_ms: integer): {View}
    refresh(state, now_ms)
    local result: {View} = {}
    for _, id in ipairs(state.order) do
        local invite = state.invites[id]
        if invite then result[#result + 1] = view(invite) end
    end
    return result
end

-- revoke settles a pending invite so it can never be redeemed.
function M.revoke(state: State, invite_id: string, now_ms: integer): (View?, string?, string?)
    refresh(state, now_ms)
    local invite = state.invites[invite_id]
    if not invite then return nil, "NOT_FOUND", "invite is unknown" end
    if invite.status ~= "pending" then return nil, "INVALID_STATE", "invite is already " .. invite.status end
    invite.status = "revoked"
    return view(invite), nil, nil
end

-- redeem consumes a pending invite for node_id when digest matches the minted
-- secret. Every other state refuses and leaves the record unchanged. The
-- caller has already refused the local node and existing peers.
function M.redeem(state: State, invite_id: string, digest: string, node_id: string, now_ms: integer): (View?, string?, string?)
    refresh(state, now_ms)
    local invite = state.invites[invite_id]
    if not invite then return nil, "NOT_FOUND", "invite is unknown" end
    if invite.status == "used" then return nil, "CONFLICT", "invite was already used" end
    if invite.status == "revoked" then return nil, "DENIED", "invite was revoked" end
    if invite.status == "expired" then return nil, "DEADLINE_EXCEEDED", "invite expired" end
    if invite.digest ~= digest then return nil, "DENIED", "invite secret does not match" end
    invite.status = "used"
    invite.node_id = node_id
    return view(invite), nil, nil
end

-- decode validates an invite operation's exact input. Invite, list and peers
-- take no fields; revoke names an invite; redeem carries the presented secret
-- and the joining node.
function M.decode(operation: string, value: unknown): (Input?, string?)
    local object = bounds.object(value)
    if not object then return nil, "input must be an object" end
    if operation == M.INVITE or operation == M.LIST or operation == M.PEERS then
        local unknown = bounds.fields(object, {})
        if unknown then return nil, unknown end
        return {}, nil
    elseif operation == M.REVOKE then
        local unknown = bounds.fields(object, {"invite_id"})
        if unknown then return nil, unknown end
        local id = M.invite_id(object.invite_id)
        if not id then return nil, "invite_id must be 32 lowercase hexadecimal characters" end
        return {invite_id = id}, nil
    elseif operation == M.REDEEM then
        local unknown = bounds.fields(object, {"invite_id", "secret", "node_id"})
        if unknown then return nil, unknown end
        local id, secret, node = M.invite_id(object.invite_id), M.secret(object.secret), bounds.id(object.node_id)
        if not id then return nil, "invite_id must be 32 lowercase hexadecimal characters" end
        if not secret then return nil, "secret must be 64 lowercase hexadecimal characters" end
        if not node then return nil, "node_id is not an identifier" end
        return {invite_id = id, secret = secret, node_id = node}, nil
    end
    return nil, "unknown invite operation"
end
return M
