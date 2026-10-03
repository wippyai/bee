-- MIT. Fixed private execution entry. The facade supplies the caller identity
-- through native scope replacement; callers cannot name an execution target.
local security = require("security")
local process = require("process")
local uuid = require("uuid")
local channel = require("channel")
local bounds = require("bounds")
local catalog = require("catalog")
local updates = require("updates")
local inventory_reader = require("inventory_reader")
local inspect = require("inspect")
local preview = require("preview")
local publication = require("publication")
local host_resources = require("host_resources")
local transaction = require("transaction")
type Result = transaction.Result

local function decode_reply(raw: unknown): Result?
    local value = bounds.object(raw)
    if not value then return nil end
    if type(value.ok) ~= "boolean" or type(value.replayed) ~= "boolean" then return nil end
    local code, message = value.code, value.message
    if code ~= nil and type(code) ~= "string" then return nil end
    if message ~= nil and type(message) ~= "string" then return nil end
    return {ok = value.ok, replayed = value.replayed, code = code, message = message, value = value.value}
end
local function publish(request: unknown, expected: string): Result
    local host, host_error = host_resources.process_host()
    if not host then return transaction.failure("UNAVAILABLE", host_error or "Hub worker host is unavailable") end
    local id, id_error = uuid.v4()
    if not id then return transaction.failure("UNAVAILABLE", tostring(id_error)) end
    local topic = "bee.hub.result." .. id
    local replies, listen_error = process.listen(topic, {message = true})
    if not replies then return transaction.failure("UNAVAILABLE", tostring(listen_error)) end
    local pid, spawn_error = process.spawn_monitored("bee.hub.service:worker", host, process.pid(), topic, request, expected)
    if not pid then process.unlisten(replies); return transaction.failure("UNAVAILABLE", tostring(spawn_error)) end
    local events = assert(process.events())
    while true do
        local event = channel.select({replies:case_receive(), events:case_receive()})
        if not event.ok then
            process.unlisten(replies)
            return transaction.failure("UNCERTAIN", "Hub worker reply channel closed")
        end
        if event.channel == events then
            local observed = event.value
            if observed.kind == process.event.CANCEL then
                process.unlisten(replies)
                return transaction.failure("CANCELLED", "Hub operation wait cancelled")
            end
            if observed.kind == process.event.EXIT and tostring(observed.from) == tostring(pid) then
                process.unlisten(replies)
                return transaction.failure("UNCERTAIN", "Hub worker exited before its reply: " .. tostring(type(observed.result) == "table" and observed.result.error or "without a result"))
            end
            goto next_worker_event
        end
        local message = event.value
        if message:from() == pid then
            local result = decode_reply(message:payload():data())
            process.unlisten(replies)
            return result or transaction.failure("UNCERTAIN", "invalid worker reply; check the operation result")
        end
        ::next_worker_event::
    end
    return transaction.failure("UNCERTAIN", "Hub worker did not return a result")
end
local function handle(raw: unknown): Result
    if not security.can("bee.hub.execute", "bee.hub.binding:backend") then return transaction.failure("DENIED", "Hub backend is private") end
    local value = bounds.object(raw)
    if not value then return transaction.failure("INVALID", "invalid Hub request") end
    local operation = bounds.line(value.operation, 32)
    if not operation then return transaction.failure("INVALID", "invalid Hub operation") end
    if value.operation == "catalog" then
        local result, problem = catalog.browse(value.request)
        if not result then return transaction.failure("UNAVAILABLE", problem or "catalog unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "details" then
        local result, problem = catalog.detail(value.request)
        if not result then return transaction.failure("UNAVAILABLE", problem or "package details unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "state" or value.operation == "files" or value.operation == "read_file" then
        local result, problem = preview.read(operation, value.request)
        if not result then return transaction.failure("UNAVAILABLE", problem or "package read unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "inspect" then
        local result, problem = inspect.read(value.request)
        if not result then return transaction.failure("UNAVAILABLE", problem or "package inspection unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "installed_source" then
        local result, problem = inventory_reader.sources(value.request)
        if not result then return transaction.failure("UNAVAILABLE", problem or "installed source unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "installed" then
        local result, problem = inventory_reader.read()
        if not result then return transaction.failure("UNAVAILABLE", problem or "inventory unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "updates" then
        local result, problem = updates.read()
        if not result then return transaction.failure("UNAVAILABLE", problem or "Bee update status unavailable") end
        return transaction.success(result, false)
    elseif value.operation == "plan" then
        local result, problem = publication.prepare(value.request)
        if not result then return transaction.failure("INVALID", problem or "package plan unavailable") end
        return transaction.success(result.plan, false)
    elseif value.operation == "apply" then
        local expected = bounds.line(value.expected_digest, 64)
        if not expected then return transaction.failure("INVALID", "confirmation digest is required") end
        return publish(value.request, expected)
    elseif value.operation == "status" then return publication.status(value.expected_digest, value.request) end
    if value.operation == "publish_request" or value.operation == "publish_apply" then
        local host, host_error = host_resources.process_host()
        if not host then return transaction.failure("UNAVAILABLE", host_error or "Hub worker host is unavailable") end
        local id, id_error = uuid.v4()
        if not id then return transaction.failure("UNAVAILABLE", tostring(id_error)) end
        local topic = "bee.hub.publish_result." .. id
        local replies, listen_error = process.listen(topic, {message = true})
        if not replies then return transaction.failure("UNAVAILABLE", tostring(listen_error)) end
        local operation = value.operation == "publish_request" and "plan" or "apply"
        local worker_request = value.request
        if operation == "apply" then
            local supplied = bounds.object(value.request) or {}
            worker_request = {plan_digest = value.expected_digest, component = supplied.component}
        end
        local pid, spawn_error = process.spawn_monitored("bee.hub.service:publish_worker", host,
            process.pid(), topic, operation, worker_request)
        if not pid then process.unlisten(replies); return transaction.failure("UNAVAILABLE", tostring(spawn_error)) end
        local events = assert(process.events())
        while true do
            local event = channel.select({replies:case_receive(), events:case_receive()})
            if not event.ok then
                process.unlisten(replies)
                return transaction.failure("UNCERTAIN", "Hub publication reply channel closed")
            end
            if event.channel == events then
                local observed = event.value
                if observed.kind == process.event.CANCEL then
                    process.unlisten(replies)
                    return transaction.failure("CANCELLED", "Hub operation wait cancelled")
                end
                if observed.kind == process.event.EXIT and tostring(observed.from) == tostring(pid) then
                    process.unlisten(replies)
                    return transaction.failure("UNCERTAIN", "Hub worker exited before its reply: " .. tostring(type(observed.result) == "table" and observed.result.error or "without a result"))
                end
                goto next_worker_event
            end
            local message = event.value
            if message:from() == pid then
                local result = decode_reply(message:payload():data())
                process.unlisten(replies)
                return result or transaction.failure("UNCERTAIN", "invalid publish worker reply; check the publication result")
            end
            ::next_worker_event::
        end
        return transaction.failure("UNCERTAIN", "Hub publish worker did not return a result")
    end
    return transaction.failure("INVALID", "unknown Hub operation")
end
return {handle = handle}
