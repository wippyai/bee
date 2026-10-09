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
local demand = require("demand")
local task = require("task")
local effects = require("effects")
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
    local demanded = assert(process.listen(demand.WAKE, {message = true}))
    local installation = task.new("gateway installation", function(): boolean return effects.drain("installation") end)
    local publication = task.new("gateway publication", function(): boolean return effects.drain("publication") end)
    local generation = 0
    assert(demand.ready(NAME))
    assert(protocol.ready(NAME))
    local function finish(item: Waiting): boolean
        if time.now():unix_nano() >= item.request.expires then
            assert(process.send(item.request.caller, item.request.reply_topic, protocol.fail("Pairing wait expires; connect again")))
            return true
        end
        local reply = external.complete(item.client, item.request.caller)
        local value = bounds.object(reply.value)
        if reply.ok and value and (value.status == "pending" or value.status == "approved") then return false end
        assert(process.send(item.request.caller, item.request.reply_topic, protocol.ok(reply)))
        return true
    end
    local function handle(request: protocol.Forwarded)
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
    while true do
        task.advance(installation)
        task.advance(publication)
        if #waiting == 0 and task.quiet(installation) and task.quiet(publication) then assert(demand.quiet(NAME, generation)) end
        local cases = {lifecycle:case_receive(), requests:case_receive(), changes:case_receive(), demanded:case_receive(),
            installation.completed:case_receive(), publication.completed:case_receive()}
        local install_retry = task.deadline(installation)
        local publish_retry = task.deadline(publication)
        if install_retry then cases[#cases + 1] = install_retry:case_receive() end
        if publish_retry then cases[#cases + 1] = publish_retry:case_receive() end
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
        elseif selected.channel == installation.completed then task.finish(installation, selected.value == true)
        elseif selected.channel == publication.completed then task.finish(publication, selected.value == true)
        elseif selected.channel == demanded then
            local message = selected.value
            local supervisor = process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)
            local envelope = bounds.object(message:payload():data())
            if supervisor and tostring(message:from()) == tostring(supervisor) and envelope and type(envelope.generation) == "number" then
                generation = math.floor(envelope.generation)
                task.wake(installation); task.wake(publication)
                for _, raw in ipairs(bounds.array(envelope.requests, 64) or {}) do
                    local request = bounds.object(raw)
                    local data = request and bounds.object(request.data)
                    local forwarded = data and protocol.forwarded(tostring(supervisor), data.hive)
                    if forwarded then handle(forwarded) end
                end
            end
        elseif selected.channel == requests then
            local message = selected.value
            local request = protocol.forwarded(tostring(message:from()), message:payload():data())
            if request then handle(request) end
        else
            local remaining: {Waiting} = {}
            for _, item in ipairs(waiting) do if not finish(item) then remaining[#remaining + 1] = item end end
            waiting = remaining
        end
    end
end
return {main = main}
