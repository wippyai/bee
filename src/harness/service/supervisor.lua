-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local security = require("security")
local bounds = require("bounds")
local canonical = require("canonical")
local NAME = "bee.harness.presentation"
local TOPIC = "bee.session.window.launch"
local REPLY = "bee.session.window.reply"
local CALLER = "bee.session.viewer/"
local PERMIT = "bee.session.launch/"
type Object = {[string]: unknown}
type Child = {pid: string, fingerprint: string, tokens: {string}, reply: Object?}
local function failure(message: string): Object
    return {ok = false, error = {code = "UNAVAILABLE", message = message}}
end
local function reply(token: string, value: Object)
    local recipient = process.registry.lookup(token)
    if recipient then
        local result: Object = {}
        for key, item in pairs(value) do result[key] = item end
        result.caller_token = token
        process.send(recipient, REPLY, result)
    end
end
local function main()
    assert(process.set_options({trap_links = true}))
    local requests = assert(process.listen(TOPIC, {message = true}))
    local replies = assert(process.listen(REPLY, {message = true}))
    local events = assert(process.events())
    local scope = assert(security.named_scope("bee.harness.security:presentation_execution_scope"))
    local children: {[string]: Child} = {}
    local names: {[string]: string} = {}
    local stopping = false
    assert(process.registry.register(NAME))
    while not stopping or next(children) do
        local event = channel.select({requests:case_receive(), replies:case_receive(), events:case_receive()})
        if not event.ok then break end
        if event.channel == events then
            local from = tostring(event.value.from)
            if event.value.kind == process.event.CANCEL then
                stopping = true
                process.registry.unregister(NAME)
                for _, child in pairs(children) do process.cancel(child.pid, "presentation service stopping") end
            elseif event.value.kind == process.event.EXIT or event.value.kind == process.event.MONITOR_DOWN then
                local name = names[from]
                local child = name and children[name]
                if child then
                    for _, token in ipairs(child.tokens) do reply(token, failure("presentation owner exited before admission")) end
                    children[name] = nil
                    names[from] = nil
                end
            end
        elseif event.channel == replies then
            local name = names[tostring(event.value:from())]
            local child = name and children[name]
            local value = bounds.object(event.value:payload():data())
            if child and value and value.caller_token == child.tokens[1] then
                child.reply = value
                for _, token in ipairs(child.tokens) do reply(token, value) end
                child.tokens = {}
            end
        else
            local value = bounds.object(event.value:payload():data())
            local token = value and bounds.id(value.caller_token)
            local permit = value and bounds.id(value.permit)
            local sender = tostring(event.value:from())
            if not token or token:sub(1, #CALLER) ~= CALLER
                or tostring(process.registry.lookup(token)) ~= sender then goto next_event end
            if not permit or permit:sub(1, #PERMIT) ~= PERMIT
                or tostring(process.registry.lookup(permit)) ~= sender then
                reply(token, failure("presentation launch capability is missing"))
                goto next_event
            end
            local name = bounds.id(value.name)
            local workspace = bounds.id(value.workspace)
            local actor_id = bounds.id(value.actor_id)
            local metadata = bounds.object(value.actor_meta)
            local startup = bounds.object(value.startup)
            local key = bounds.text(value.operation_key, 128)
            local ceiling = bounds.ids(value.trait_ceiling, true)
            local fingerprint = canonical.encode({startup = startup, actor_id = actor_id, actor_meta = metadata,
                workspace = workspace, operation_key = key, trait_ceiling = ceiling}, 65536, 24)
            if stopping or not name or not workspace or not actor_id or not metadata or not startup or not key or key == "" or not fingerprint
                or (value.trait_ceiling ~= nil and not ceiling) then
                reply(token, failure("invalid presentation launch"))
                goto next_event
            end
            local child = children[name]
            if child then
                local cached = child.reply
                if child.fingerprint ~= fingerprint then reply(token, failure("presentation launch identity changed"))
                elseif cached then reply(token, cached)
                else child.tokens[#child.tokens + 1] = token end
                goto next_event
            end
            local actor = assert(security.new_actor(actor_id, metadata))
            local pid, err = process.with_options({}):with_context({["bee.workspace_id"] = workspace, ["bee.agent.trait_ceiling"] = ceiling})
                :with_actor(actor):with_scope(scope):spawn_linked_monitored("bee.harness.service:presentation_owner", "bee:workers",
                    startup, name, token, key, tostring(process.pid()))
            if not pid then reply(token, failure(tostring(err)))
            else
                children[name] = {pid = tostring(pid), fingerprint = fingerprint, tokens = {token}}
                names[tostring(pid)] = name
            end
        end
        ::next_event::
    end
    process.registry.unregister(NAME)
end
return {main = main}
