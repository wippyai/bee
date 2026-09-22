-- MIT. Fixed private execution entry. The facade supplies the caller identity
-- through native scope replacement; callers cannot name an execution target.
local security = require("security")
local process = require("process")
local uuid = require("uuid")
local time = require("time")
local channel = require("channel")
local bounds = require("bounds")
local catalog = require("catalog")
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
    local pid, spawn_error = process.spawn("bee.hub.service:worker", host, process.pid(), topic, request, expected)
    if not pid then process.unlisten(replies); return transaction.failure("UNAVAILABLE", tostring(spawn_error)) end
    local deadline = time.after("120s")
    while true do
        local event = channel.select({replies:case_receive(), deadline:case_receive()})
        if not event.ok or event.channel == deadline then
            process.unlisten(replies)
            return transaction.failure("UNCERTAIN", "operation is still running or its reply was lost; check its result")
        end
        local message = event.value
        if message:from() == pid then
            local result = decode_reply(message:payload():data())
            process.unlisten(replies)
            return result or transaction.failure("UNCERTAIN", "invalid worker reply; check the operation result")
        end
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
    elseif value.operation == "installed" then
        local result, problem = inventory_reader.read()
        if not result then return transaction.failure("UNAVAILABLE", problem or "inventory unavailable") end
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
    return transaction.failure("INVALID", "unknown Hub operation")
end
return {handle = handle}
