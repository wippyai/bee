-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local time = require("time")
local cdc = require("cdc")
local env = require("env")
local system = require("system")
local node_client = require("node_client")
local protocol = require("protocol")
local bounds = require("bounds")
local external = require("external")
local NAME = "bee.gateway.external"
type Waiting = {request: protocol.Forwarded, client: string}
local function main()
    if env.get("bee:role") == "client" then return end
    assert(process.registry.register(NAME))
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    local lifecycle = assert(process.events())
    local stream = assert(cdc.stream("bee:changes", {tables = {"bee_approval_requests", "bee_gateway_bindings"}, ops = {"update"}}))
    local changes = stream:channel()
    local waiting: {Waiting} = {}
    assert(protocol.ready(NAME))
    local function finish(item: Waiting): boolean
        if time.now():unix_nano() >= item.request.expires then
            assert(process.send(item.request.caller, item.request.reply_topic, protocol.fail("Pairing wait expires; connect again")))
            return true
        end
        local reply = external.complete(item.client, item.request.caller)
        local value = bounds.object(reply.value)
        if reply.ok and value and value.status == "pending" then return false end
        assert(process.send(item.request.caller, item.request.reply_topic, protocol.ok(reply)))
        return true
    end
    while true do
        local cases = {lifecycle:case_receive(), requests:case_receive(), changes:case_receive()}
        local earliest: integer? = nil
        for _, item in ipairs(waiting) do if not earliest or item.request.expires < earliest then earliest = item.request.expires end end
        if earliest then
            local deadline = time.after(tostring(math.max(1, math.floor((earliest - time.now():unix_nano()) / 1000000))) .. "ms")
            cases[#cases + 1] = deadline:case_receive()
        end
        local selected = channel.select(cases)
        if not selected.ok then return end
        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then return end
        elseif selected.channel == requests then
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then
                if request.op == "connect" then
                    local workspaces, workspace_error = node_client.call(assert(system.node.id()), "workspaces", {})
                    local workspace = workspaces and bounds.id(workspaces.home)
                    local reply: external.Reply
                    if not workspace or request.args.workspace_id ~= workspace then
                        reply = {ok = false, value = nil, error = {code = "DENIED", message = workspace_error or "Pairing names this node's home workspace"}}
                    else
                        reply = external.request({name = request.args.name, workspace_id = workspace, caller = request.caller})
                    end
                    assert(process.send(request.caller, request.reply_topic, protocol.ok(reply)))
                elseif request.op == "wait" then
                    local id = bounds.id(request.args.client_id)
                    if not id or #waiting >= 32 then
                        assert(process.send(request.caller, request.reply_topic, protocol.fail("Pairing wait is invalid or full")))
                    else
                        local item = {request = request, client = id}
                        if not finish(item) then waiting[#waiting + 1] = item end
                    end
                else
                    assert(process.send(request.caller, request.reply_topic, protocol.fail("Unknown MCP pairing operation")))
                end
            end
        else
            local remaining: {Waiting} = {}
            for _, item in ipairs(waiting) do if not finish(item) then remaining[#remaining + 1] = item end end
            waiting = remaining
        end
    end
end
return {main = main}
