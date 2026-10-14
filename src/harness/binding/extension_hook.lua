local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local prestart = require("prestart")
local supervisor = require("supervisor")
type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: Object, error?: Object}
local function fail(message: string): Reply return {ok = false, error = {code = "HOOK_BOUNDARY", message = message}} end
local function handle(raw: unknown): Reply
    local input = bounds.object(raw)
    local binding_id = input and bounds.id(input.binding_id)
    local event_id = input and bounds.id(input.event_id)
    local payload = input and bounds.object(input.payload)
    local actor = security.actor()
    local subject = actor and bounds.id(actor:id())
    if not input or not binding_id or not event_id or not payload or not subject or not security.can("bee.harness.extension_hook", subject)
        or bounds.fields(input, {"binding_id", "event_id", "payload"}) then return fail("extension hook is not authenticated") end
    local checked, check_error = funcs.call("bee.gateway.binding:check", {binding_id = binding_id})
    local reply = bounds.object(checked)
    local binding = reply and reply.ok == true and bounds.object(reply.value) or nil
    local attempt = binding and bounds.id(binding.attempt_id)
    if check_error or not binding or not attempt or binding.valid ~= true or binding.subject ~= subject then return fail("hook binding changed") end
    local pid = process.registry.lookup(prestart.CARRIER_REGISTRY_PREFIX .. attempt)
    if not pid or not process.monitor(pid) then return fail("hook carrier is unavailable") end
    local events = assert(process.events())
    local topic = "bee.carrier.extension.reply/" .. assert(uuid.v4())
    local responses = assert(process.listen(topic, {message = true}))
    local budget = time.after(tostring(supervisor.budget("unknown", "tool.before").chain_ms) .. "ms")
    process.send(tostring(pid), "bee.carrier.extension.hook", {reply_topic = topic, binding_id = binding_id,
        event_id = event_id, payload = payload, subject = subject, attempt_id = attempt, epoch = binding.carrier_epoch})
    local result: Reply = fail("hook carrier invocation budget exceeded")
    while true do
        local selected = channel.select({responses:case_receive(), budget:case_receive(), events:case_receive()})
        if not selected.ok or selected.channel == budget then break end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL or (event.kind == process.event.EXIT and tostring(event.from) == tostring(pid)) then
                result = fail("hook carrier ended during invocation"); break
            end
        elseif selected.channel == responses then
            local message = selected.value
            if tostring(message:from()) == tostring(pid) then
                local answer = bounds.object(message:payload():data())
                local value = answer and bounds.object(answer.value)
                result = answer and answer.ok == true and value and {ok = true, value = value} or fail(answer and bounds.text(answer.error, 4096) or "hook carrier refused")
                break
            end
        end
    end
    process.unlisten(responses)
    process.unmonitor(pid)
    return result
end
return {handle = handle}
