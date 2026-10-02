-- MIT. Scheduler fences derive from the installer's existing durable intent.
local registry = require("registry")
local hash = require("hash")
local canonical = require("canonical")
local bounds = require("bounds")
local M = {}
M.SERVICE = "bee.sessions.service:scheduler_service"
M.PROCESS = "bee.sessions.service:scheduler_worker"
M.TOPIC = "bee.sessions.lifecycle"
type Request = {version: integer, digest: string, service: string, phase: string, definition: string, retention: string}
function M.request(raw: unknown): Request?
    local value = bounds.object(raw)
    if not value or bounds.fields(value, {"version", "digest", "service", "phase", "definition", "retention"})
        or value.version ~= 1 or value.service ~= M.SERVICE or value.retention ~= "retain" then return nil end
    local digest, definition = bounds.line(value.digest, 64), bounds.line(value.definition, 64)
    local phase = bounds.member(value.phase, {"quiesce", "ready"})
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") or not definition or #definition ~= 64
        or not definition:match("^[0-9a-f]+$") or not phase then return nil end
    return {version = 1, digest = digest, service = M.SERVICE, phase = phase, definition = definition, retention = "retain"}
end
function M.definition(): string?
    local snapshot = registry.snapshot()
    local entry = snapshot and snapshot:get(M.PROCESS)
    if not entry then return nil end
    local encoded = canonical.encode({id = entry.id, kind = entry.kind, meta = entry.meta or {}, data = entry.data}, 1048576)
    return encoded and hash.sha256(encoded) or nil
end
function M.intent(request: Request): boolean
    local snapshot = registry.snapshot()
    local entry = snapshot and snapshot:get("bee.hub.operations:" .. request.digest)
    local receipt = entry and bounds.object(entry.data)
    local work = receipt and bounds.object(receipt.lifecycle_work)
    local services = work and bounds.array(work.services, 128)
    if not services or not work or work.version ~= 1 then return false end
    if request.phase == "quiesce" and (work.phase ~= "prepared" and work.phase ~= "quiesced") then return false end
    if request.phase == "ready" and (work.phase ~= "published" and work.phase ~= "ready") then return false end
    for _, raw in ipairs(services) do
        local service = bounds.object(raw)
        if service and service.id == M.SERVICE and service.owner == "bee/sessions"
            and service.retention == "retain" and service.process == M.PROCESS
            and service[request.phase == "quiesce" and "before" or "candidate"] == request.definition then return true end
    end
    return false
end
function M.fenced(): (boolean, string?)
    local snapshot, problem = registry.snapshot()
    local state = snapshot and snapshot:state()
    if not state then return true, tostring(problem or "scheduler admission fence unavailable") end
    for _, entry in ipairs(state.entries) do
        if entry.id:sub(1, 19) == "bee.hub.operations:" then
            local receipt = bounds.object(entry.data)
            local work = receipt and bounds.object(receipt.lifecycle_work)
            local services = work and bounds.array(work.services, 128)
            if receipt and receipt.lifecycle_work ~= nil and (not work or not services) then
                return true, "component lifecycle intent is malformed"
            end
            if work and services and work.phase ~= "ready" then
                for _, raw in ipairs(services) do
                    local service = bounds.object(raw)
                    if service and service.owner == "bee/sessions" then return true, "Sessions is draining for a component transition" end
                end
            end
        end
    end
    return false, nil
end
return M
