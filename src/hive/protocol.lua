-- MIT. The Hive call protocol: every node runs one supervisor registered under
-- a mesh-wide name; a caller on any node sends it a request and waits for the
-- reply on a topic of its own.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local system = require("system")

-- ttl is how long the caller keeps waiting, in nanoseconds; the receiving
-- supervisor turns it into a deadline on its own clock.
type Request = {op: string, args: {[string]: unknown}, reply_topic: string, ttl: integer}
type Reply = {ok: boolean, value: {[string]: unknown}?, error: string?}

local M = {}
M.CALL = "bee.hive.call"
M.SUPERVISOR = "bee.hive.supervisor"
-- FORWARD is the topic the supervisor uses to hand a routed operation to a
-- node-local service, with the authenticated caller.
M.FORWARD = "bee.hive.forward"
-- ROUTE is the registry type of entries that route operations: an entry with
-- data {prefix = "node", name = "bee.node"} sends op "node.list" as "list" to
-- the process registered under bee.node on the called node.
M.ROUTE = "bee.hive.route"
-- READY is the topic a routed service uses to tell its node's supervisor it
-- serves requests; requests that arrived while it was not running wait for it.
M.READY = "bee.hive.ready"

type Forwarded = {op: string, args: {[string]: unknown}, caller: string, reply_topic: string, expires: integer}

function M.supervisor_name(node: string): string
    return M.SUPERVISOR .. "/" .. node
end

function M.ok(value: {[string]: unknown}): Reply
    return {ok = true, value = value, error = nil}
end

function M.fail(message: string): Reply
    return {ok = false, value = nil, error = message}
end

-- node_of is the node a PID belongs to, or local_node for a PID without one.
-- The mesh authenticates the node of a remote sender's PID.
function M.node_of(pid: string, local_node: string): string
    return pid:match("^{([^@|{}]+)@") or local_node
end

-- clustered reports whether this node is part of a mesh.
function M.clustered(): boolean
    local members = system.cluster.members()
    return members ~= nil
end

-- local_supervisor resolves this node's supervisor through its node-local
-- name. Node-local names are read in the LOCAL scope only: an unscoped lookup
-- consults the hive-wide registries first.
local function local_supervisor(): (string?, string?)
    local pid, lookup_error = process.registry.lookup(M.SUPERVISOR, process.registry.LOCAL)
    if not pid then return nil, "this node's supervisor is not running: " .. tostring(lookup_error) end
    return tostring(pid), nil
end

-- supervisor resolves the supervisor of node: this node's through its local
-- name, another node's through its mesh-wide name, waiting up to timeout for
-- that name to reach this node.
local function supervisor(node: string, timeout: string): (string?, string?)
    if node == system.node.id() then return local_supervisor() end
    if not M.clustered() then return nil, "this node is not part of a hive" end
    local pid, lookup_error = process.registry.lookup(M.supervisor_name(node), process.registry.EVENTUAL, {timeout = timeout})
    if not pid then return nil, "no supervisor on node " .. node .. ": " .. tostring(lookup_error) end
    return tostring(pid), nil
end

-- known is the supervisor this process announced itself to or last accepted
-- an operation from; forwarded resolves the supervisor again only when an
-- operation arrives from another process, which happens after the supervisor
-- restarted.
local known: string? = nil

-- ready tells this node's supervisor that the calling process, registered
-- under name, serves requests, and returns that supervisor's PID.
function M.ready(name: string): (string?, string?)
    local pid, lookup_error = local_supervisor()
    if not pid then return nil, lookup_error end
    local sent, send_error = process.send(pid, M.READY, {name = name})
    if not sent then return nil, tostring(send_error) end
    known = pid
    return pid, nil
end

-- forward hands an operation to the node-local service process pid.
function M.forward(pid: string, request: Forwarded): (boolean, string?)
    local sent, send_error = process.send(pid, M.FORWARD, request)
    if not sent then return false, tostring(send_error) end
    return true, nil
end

-- forwarded decodes an operation handed over by this node's supervisor and
-- refuses any other sender.
function M.forwarded(from: string, data: unknown): Forwarded?
    if from ~= known then
        local current = local_supervisor()
        if current ~= from then return nil end
        known = current
    end
    if type(data) ~= "table" or type(data.op) ~= "string" or type(data.caller) ~= "string"
        or type(data.reply_topic) ~= "string" or type(data.args) ~= "table" or type(data.expires) ~= "number" then return nil end
    return {op = data.op, args = data.args, caller = data.caller, reply_topic = data.reply_topic, expires = math.floor(data.expires)}
end

-- supervisor_pid is the supervisor this process last announced itself to or
-- accepted an operation from.
function M.supervisor_pid(): string?
    return known
end

-- call sends op to the supervisor of node and waits up to timeout to resolve
-- it and up to timeout for its reply. The request carries how long the caller
-- waits, so a supervisor never delivers it after the caller gave up.
function M.call(node: string, op: string, args: {[string]: unknown}, timeout: string): (Reply?, string?)
    local pid, resolve_error = supervisor(node, timeout)
    if not pid then return nil, resolve_error end
    local reply_topic = "bee.hive.reply." .. tostring(uuid.v7())
    local replies = assert(process.listen(reply_topic, {message = true}))
    local wait = assert(time.parse_duration(timeout))
    local request: Request = {op = op, args = args, reply_topic = reply_topic, ttl = math.floor(wait:nanoseconds())}
    local sent, send_error = process.send(pid, M.CALL, request)
    if not sent then
        process.unlisten(replies)
        return nil, "send to " .. node .. ": " .. tostring(send_error)
    end
    local deadline = time.after(timeout)
    local selected = channel.select({replies:case_receive(), deadline:case_receive()})
    process.unlisten(replies)
    if not selected.ok or selected.channel == deadline then return nil, "no reply from " .. node .. " within " .. timeout end
    local data: unknown = selected.value:payload():data()
    if type(data) ~= "table" or type(data.ok) ~= "boolean" then return nil, "malformed reply from " .. node end
    local reply: Reply = {ok = data.ok, value = nil, error = nil}
    if type(data.value) == "table" then reply.value = data.value end
    if type(data.error) == "string" then reply.error = data.error end
    return reply, nil
end

return M
