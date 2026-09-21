-- MIT. The one client for Hive operations. Ordinary calls go through this
-- node's supervisor. A foreground native attachment may instead bind the
-- exact advertised supervisor for its already-selected owner node; its owner
-- still admits the native display PID and returns the recipient-bound mount.
-- Replies are accepted only from the supervisor the call was sent to.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local types = require("types")
local bounds = require("bounds")
type Reply = types.Reply
type OwnerRef = types.OwnerRef
type Target = types.Target
type Options = {idempotency_key: string?, deadline: string?, timeout: string?}
type Channel = channel.Channel
type Client = {
    replies: Channel<process.Message>,
    owner_node: string?,
    call: (Client, OwnerRef, Target, {[string]: unknown}, Options) -> Reply,
    close: (Client) -> boolean,
}
local M = {}
local DEFAULT_TIMEOUT = "30s"
local function failed(request_id: string, code: string, message: string): Reply
    return types.reply_error(request_id, types.fault(code, message))
end
-- A name is discovery, never authority: both the ordinary local name and a
-- qualified owner name are accepted only when their exact PID says supervisor
-- host on the expected native node.
local function supervisor(owner_node: string?): (string?, string?)
    local own_node = types.pid_parts(tostring(process.pid()))
    local requested = owner_node or own_node
    if not requested then return nil, "native node identity is unavailable" end
    local name = owner_node and types.SUPERVISOR_NAME .. "/" .. owner_node or types.SUPERVISOR_NAME
    local pid, err = process.registry.lookup(name)
    if err or not pid then return nil, owner_node and "owner supervisor is not running" or "supervisor is not running" end
    local node, host = types.pid_parts(pid)
    if host ~= types.SUPERVISOR_HOST then return nil, "supervisor name resolves outside the supervisor host" end
    if node == nil or node ~= requested then return nil, owner_node and "owner supervisor resolves outside its node" or "supervisor name resolves outside this node" end
    return pid, nil
end
function M.supervisor(): (string?, string?)
    return supervisor()
end
local function call(self: Client, owner_ref: OwnerRef, target: Target, input: {[string]: unknown}, settings: Options): Reply
    local request_id, id_error = uuid.v7()
    if id_error or not request_id then return failed("", "INTERNAL", "allocate request identifier") end
    local key = settings.idempotency_key
    if key == nil then
        local generated, key_error = uuid.v4()
        if key_error or not generated then return failed(request_id, "INTERNAL", "allocate idempotency key") end
        key = generated
    end
    -- The wire contract says the top-level input is an object. Preserve that
    -- allocation even when it is empty; an unshaped `{}` can otherwise cross a
    -- native transport as a list and no longer match the digest measured by
    -- the sending supervisor.
    local wire_input: {[string]: unknown} = table.create(0, 1)
    for name, value in pairs(input) do wire_input[name] = value end
    local body: {[string]: unknown} = {protocol_revision = types.REVISION, request_id = request_id, idempotency_key = key,
        owner_ref = owner_ref, target = target, input = wire_input, deadline = settings.deadline}
    local decoded, decode_error = types.decode_call(body)
    if not decoded then return failed(request_id, "INVALID_ARGUMENT", decode_error or "invalid call") end
    local pid, lookup_error = supervisor(self.owner_node)
    if not pid then return failed(request_id, "UNAVAILABLE", lookup_error or "supervisor unavailable") end
    local sent, send_error = process.send(pid, types.TOPIC_REQUEST, body)
    if send_error or not sent then return failed(request_id, "UNAVAILABLE", "supervisor did not accept the call") end
    local deadline = time.after(settings.timeout or DEFAULT_TIMEOUT)
    local outcome: Reply? = nil
    while not outcome do
        local selected = channel.select({self.replies:case_receive(), deadline:case_receive()})
        if not selected.ok then
            outcome = failed(request_id, "UNAVAILABLE", "reply channel closed")
        elseif selected.channel == deadline then
            outcome = failed(request_id, "DEADLINE_EXCEEDED", "no reply before the timeout")
        else
            local message = selected.value
            if tostring(message:from()) == pid then
                local data: unknown = message:payload():data()
                local reply, reply_error = types.decode_reply(data)
                if reply and reply.request_id == request_id then
                    outcome = reply
                elseif not reply and type(data) == "table" and data.request_id == request_id then
                    outcome = failed(request_id, "INTERNAL", "supervisor reply is malformed: " .. tostring(reply_error))
                end
            end
        end
    end
    return outcome
end
local function close(self: Client): boolean
    process.unlisten(self.replies)
    return true
end
-- `owner_node` is only for a native attachment whose owner already made that
-- node part of its admission configuration. It keeps the common client API
-- and avoids a second, display-specific wire client.
function M.open(owner_node: string?): (Client?, string?)
    if owner_node ~= nil and not bounds.id(owner_node) then
        return nil, "owner node identity is invalid"
    end
    local replies, err = process.listen(types.TOPIC_REPLY, {message = true})
    if err or not replies then return nil, "subscribe to replies" end
    local client: Client = {replies = replies, owner_node = owner_node, call = call, close = close}
    return client, nil
end
return M
