-- MIT. Fixed private execution entry. The facade supplies the caller identity
-- through native scope replacement; callers cannot name an execution target.
local security = require("security")
local process = require("process")
local bounds = require("bounds")
local catalog = require("catalog")
local updates = require("updates")
local inventory_reader = require("inventory_reader")
local inspect = require("inspect")
local preview = require("preview")
local publication = require("publication")
local hub_package = require("hub_package")
local plan = require("plan")
local hub_result = require("hub_result")
type Result = hub_result.Result

local WORKER = "bee.hub.service:worker"
local HOST = "bee:workers"

-- publish runs apply in the publication worker and returns the result its
-- exit carries. A caller cancelled first leaves the worker to finish; its
-- receipt records the outcome.
local function publish(request: unknown, expected: string): Result
    local events = process.events()
    local pid, spawn_error = process.spawn_monitored(WORKER, HOST, request, expected)
    if not pid then return hub_result.failure("UNAVAILABLE", tostring(spawn_error)) end
    while true do
        local event, ok = events:receive()
        if not ok then return hub_result.failure("UNCERTAIN", "Hub call lost its lifecycle events; check the operation result") end
        if event.kind == process.event.CANCEL then
            return hub_result.failure("UNCERTAIN", "Hub call was cancelled while the operation runs; check its result")
        end
        if event.kind == process.event.EXIT and event.from == pid then
            local exit = event.result
            if exit and exit.value ~= nil then return hub_result.decode(exit.value) end
            return hub_result.failure("UNCERTAIN", "Hub worker stopped: " .. tostring(exit and exit.error) .. "; check the operation result")
        end
    end
end

local function handle(raw: unknown): Result
    if not security.can("bee.hub.execute", "bee.hub.binding:backend") then return hub_result.failure("DENIED", "Hub backend is private") end
    local value = bounds.object(raw)
    if not value then return hub_result.failure("INVALID", "invalid Hub request") end
    local operation = bounds.line(value.operation, 32)
    if not operation then return hub_result.failure("INVALID", "invalid Hub operation") end
    if value.operation == "catalog" then
        local result, problem = catalog.browse(value.request)
        if not result then return hub_result.failure("UNAVAILABLE", problem or "catalog unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "details" then
        local result, problem = catalog.detail(value.request)
        if not result then return hub_result.failure("UNAVAILABLE", problem or "package details unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "state" or value.operation == "files" or value.operation == "read_file" then
        local result, problem = preview.read(operation, value.request)
        if not result then return hub_result.failure("UNAVAILABLE", problem or "package read unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "inspect" then
        local result, problem = inspect.read(value.request)
        if not result then return hub_result.failure("UNAVAILABLE", problem or "package inspection unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "installed_source" then
        local result, problem = inventory_reader.sources(value.request)
        if not result then return hub_result.failure("UNAVAILABLE", problem or "installed source unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "installed" then
        local result, problem = inventory_reader.read()
        if not result then return hub_result.failure("UNAVAILABLE", problem or "inventory unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "updates" then
        local result, problem = updates.read()
        if not result then return hub_result.failure("UNAVAILABLE", problem or "Bee update status unavailable") end
        return hub_result.success(result, false)
    elseif value.operation == "plan" then
        local request, invalid = plan.decode(value.request)
        if not request then return hub_result.failure("INVALID", invalid or "invalid package request") end
        if request.action ~= "uninstall" and request.component ~= "bee/bee" then
            local expanded, problem = hub_package.read({component = request.component, version = request.version,
                parameters = request.parameters})
            if not expanded then return hub_result.failure("BLOCKED", problem or "package unavailable") end
            if expanded.governed then
                if #request.parameters > 0 then return hub_result.failure("INVALID", "governed application grants are selected by the host") end
                return hub_result.success({route = "governed", component = request.component, version = request.version,
                    artifact_digest = expanded.artifact.digest}, false)
            end
        end
        local result, problem = publication.prepare(value.request)
        if not result then return hub_result.failure("INVALID", problem or "package plan unavailable") end
        return hub_result.success(result.plan, false)
    elseif value.operation == "apply" then
        local request, invalid = plan.decode(value.request)
        if not request then return hub_result.failure("INVALID", invalid or "invalid package request") end
        if request.action ~= "uninstall" and request.component ~= "bee/bee" then
            local expanded, problem = hub_package.read({component = request.component, version = request.version,
                parameters = request.parameters})
            if not expanded then return hub_result.failure("BLOCKED", problem or "package unavailable") end
            if expanded.governed then return hub_result.failure("GOVERNED_DELIVERY", "install this application through governed delivery") end
        end
        local expected = bounds.line(value.expected_digest, 64)
        if not expected then return hub_result.failure("INVALID", "confirmation digest is required") end
        return publish(value.request, expected)
    elseif value.operation == "status" then return publication.status(value.expected_digest, value.request) end
    return hub_result.failure("INVALID", "unknown Hub operation")
end
return {handle = handle}
