-- MIT. Test-only broker for the bounded host open timeout regression.
-- It emits one catalog, accepts an origin open immediately, then delays the
-- requested open long enough for the host to answer uncertain. A second
-- dispatch is observable as a duplicate reply by the supervisor.
local process = require("process")
local channel = require("channel")
local time = require("time")
local contract = require("contract")
local ctx = require("ctx")

local function reply(owner: string, request_id: string, id: string, instance_id: string)
    local result = contract.reply(request_id, "open")
    result.workspace_id = tostring(ctx.get("bee.workspace_id"))
    result.id, result.instance_id = id, instance_id
    result.definition_id, result.title = "bee.workspace_hosts:delayed", "Delayed"
    assert(process.send(owner, "bee.app.reply", result))
end

local function main(owner: string)
    local requests = assert(process.listen("bee.app.request", {message = true}))
    local events = assert(process.events())
    assert(process.send(owner, "bee.application.catalog", {version = 1, items = {}}))
    local delayed = false
    local late_timer: time.Timer? = nil
    while true do
        local cases = {requests:case_receive(), events:case_receive()}
        if late_timer then cases[#cases + 1] = late_timer:channel():case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then break end
        if late_timer and selected.channel == late_timer:channel() then
            late_timer:stop()
            late_timer = nil
            reply(owner, "late-open", "late-view", "late-instance")
        elseif selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        else
            local value: unknown = selected.value:payload():data()
            if type(value) == "table" and value.version == 1 and value.op == "open" then
                if value.request_id == "origin-open" then
                    reply(owner, "origin-open", "origin-view", "origin-instance")
                elseif value.request_id == "late-open" then
                    if delayed then
                        -- A second dispatch would produce a duplicate reply.
                        reply(owner, "late-open", "duplicate-view", "duplicate-instance")
                    else
                        delayed = true
                        late_timer = assert(time.timer("31s"))
                    end
                end
            end
        end
    end
    if late_timer then late_timer:stop() end
    process.unlisten(requests)
end

return {main = main}
