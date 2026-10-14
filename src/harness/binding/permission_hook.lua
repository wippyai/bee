-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local prestart = require("prestart")
type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: Object, error?: {code: string, message: string}}
local function fail(message: string): Reply return {ok = false, error = {code = "PERMISSION_REFUSED", message = message}} end
local function handle(raw: unknown): Reply
    local input = bounds.object(raw)
    local binding_id = input and bounds.id(input.binding_id)
    local event_id = input and bounds.id(input.event_id)
    local payload = input and bounds.object(input.payload)
    local actor = security.actor()
    local subject = actor and bounds.id(actor:id())
    if not binding_id or not event_id or not payload or not subject or not security.can("bee.harness.permission_hook", subject)
        or bounds.fields(assert(input), {"binding_id", "event_id", "payload"}) then return fail("permission hook is not authenticated") end
    local checked, check_error = funcs.call("bee.gateway.binding:check", {binding_id = binding_id})
    local reply = bounds.object(checked)
    local binding = reply and reply.ok == true and bounds.object(reply.value) or nil
    local attempt = binding and bounds.id(binding.attempt_id)
    if check_error or not binding or not attempt or binding.valid ~= true or binding.subject ~= subject then return fail("permission binding changed") end
    local pid = process.registry.lookup(prestart.CARRIER_REGISTRY_PREFIX .. attempt)
    if not pid then return fail("permission carrier is unavailable") end
    if not process.monitor(pid) then return fail("permission carrier cannot be monitored") end
    local events = assert(process.events())
    local correlation = assert(uuid.v4())
    local topic = "bee.carrier.permission.reply/" .. correlation
    local responses = assert(process.listen(topic, {message = true}))
    local deadline = time.after("600s")
    local function finish(result: Reply): Reply process.unlisten(responses); process.unmonitor(pid); return result end
    while true do
        process.send(tostring(pid), "bee.carrier.permission.hook", {reply_topic = topic, binding_id = binding_id,
            event_id = event_id, payload = payload, subject = subject, attempt_id = attempt, epoch = binding.carrier_epoch})
        local selected = channel.select({responses:case_receive(), deadline:case_receive(), events:case_receive()})
        if selected.channel == deadline or not selected.ok then return finish(fail("permission hook expired")) end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then return finish(fail("permission hook cancelled")) end
            if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then return finish(fail("permission carrier exited")) end
        else
        local message = selected.value
        if tostring(message:from()) ~= tostring(pid) then return finish(fail("permission response has a different carrier")) end
        local answer = bounds.object(message:payload():data())
        if not answer or answer.ok ~= true then return finish(fail(answer and bounds.text(answer.error, 4096) or "permission carrier refused")) end
        local value = bounds.object(answer.value)
        if not value then return finish(fail("permission carrier returned invalid data")) end
        if value.pending ~= true then return finish({ok = true, value = {permission_response = value.permission_response}}) end
        time.sleep("50ms")
        end
    end
end
return {handle = handle}
