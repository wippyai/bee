-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Window = {actor: security.Actor, workspace: string, trait_ceiling: {string}?}
local function fail(message: string): Object return {ok = false, error = {code = "UNAVAILABLE", message = message}} end
local OWNER = "bee.session.window/"
local CALLER = "bee.session.viewer/"
local TOPIC = "bee.session.window.request"
local REPLY = "bee.session.window.reply"
local RESTORE = "bee.harness.binding:present_restore"
function M.rpc(target: string?, request: Object, startup: Object?, name: string?, operation_key: string?, owner: Window?): Object
    local token = CALLER .. assert(uuid.v7())
    local replies = assert(process.listen(REPLY, {message = true}))
    assert(process.registry.register(token))
    request.caller_token = token
    local permit: string? = nil
    local sent: boolean? = nil
    local err: unknown = nil
    if startup and name and owner then
        permit = "bee.session.launch/" .. assert(uuid.v7())
        assert(process.registry.register(permit))
        local supervisor, lookup_error = process.registry.lookup("bee.harness.presentation", process.registry.LOCAL)
        if supervisor then
            target = tostring(supervisor)
            sent, err = process.send(target, "bee.session.window.launch", {startup = startup, name = name,
                operation_key = operation_key, caller_token = token, permit = permit, workspace = owner.workspace,
                actor_id = owner.actor:id(), actor_meta = owner.actor:meta(), trait_ceiling = owner.trait_ceiling})
        else err = lookup_error end
    elseif target then sent, err = process.send(target, TOPIC, request) end
    local reply: Object = fail(tostring(err or "window owner did not answer"))
    if sent then
        local timer = assert(time.timer("30s"))
        while true do
            local event = channel.select({replies:case_receive(), timer:channel():case_receive()})
            if not event.ok or event.channel ~= replies then break end
            if tostring(event.value:from()) == target then
                local value = bounds.object(event.value:payload():data())
                if value and value.caller_token == token then reply = value; reply.caller_token = nil; break end
            end
        end
        timer:stop()
    end
    if permit then process.registry.unregister(permit, process.registry.LOCAL) end
    process.registry.unregister(token, process.registry.LOCAL)
    process.unlisten(replies)
    return reply
end
function M.attach(value: unknown): Object
    local request = bounds.object(value)
    local session = request and bounds.id(request.session)
    if not request or not session or bounds.fields(request, {"session", "detach"})
        or (request.detach ~= nil and type(request.detach) ~= "boolean") then return fail("invalid viewer request") end
    local raw, err = funcs.call("bee.threads.sessions.binding:get", {session = session})
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return fail(tostring(err or (fault and fault.message) or "session is not visible"))
    end
    local owner = process.registry.lookup(OWNER .. session)
    if not owner and request.detach ~= true then
        local resumed, resume_error = funcs.call(RESTORE, {session = session})
        local restored = bounds.object(resumed)
        if resume_error or not restored then return fail(tostring(resume_error or "window restore reply unavailable")) end
        if restored.ok ~= true then return restored end
        owner = process.registry.lookup(OWNER .. session)
    end
    if not owner then return fail("the session has no live terminal") end
    return M.rpc(tostring(owner), {op = request.detach == true and "detach" or "attach"})
end
return M
