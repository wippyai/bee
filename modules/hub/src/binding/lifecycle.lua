-- MIT. Owner drains and readiness use the runtime's existing supervisor.
local registry = require("registry")
local events = require("events")
local system = require("system")
local funcs = require("funcs")
local security = require("security")
local channel = require("channel")
local process = require("process")
local bounds = require("bounds")
local lifecycle = require("lifecycle")
local M = {}
local function definitions(work: lifecycle.Work, candidate: boolean): string?
    local snapshot, problem = registry.snapshot()
    local state = snapshot and snapshot:state()
    local entries, entry_error = lifecycle.entries(state)
    if not entries then return tostring(problem or entry_error) end
    local by_id: {[string]: lifecycle.Entry} = {}
    for _, entry in ipairs(entries) do by_id[entry.id] = entry end
    for _, service in ipairs(work.services) do
        local expected = candidate and service.candidate or service.before
        local handler_expected = candidate and service.handler_candidate or service.handler_before
        local registration = by_id[service.id]
        local registration_expected = candidate and service.registration_candidate or service.registration_before
        if registration_expected == "" then
            if registration then return "departed service registration remains: " .. service.id end
        elseif not registration or lifecycle.fingerprint(registration) ~= registration_expected then
            return "service registration differs from captured intent: " .. service.id
        end
        local source, handler = by_id[service.process], by_id[service.handler]
        if expected == "" then
            if source or handler then return "departed service definitions remain: " .. service.id end
        elseif not source or source.owner ~= service.owner or lifecycle.fingerprint(source) ~= expected
            or not handler or handler.owner ~= service.owner or lifecycle.fingerprint(handler) ~= handler_expected then
            return "service candidate differs from captured intent: " .. service.id
        end
    end
    return nil
end
local function removal_obligations(): string?
    local snapshot = registry.snapshot()
    local state = snapshot and snapshot:state()
    if not state then return "component removal inventory is unavailable" end
    local withdrawn = lifecycle.withdrawn(state)
    if next(withdrawn) == nil then return nil end
    local hosts, hosts_error = system.hosts.list()
    if not hosts then return tostring(hosts_error or "component process inventory is unavailable") end
    for _, host in ipairs(hosts) do
        local processes, process_error = system.hosts.processes(host.id)
        if not processes then return tostring(process_error or "component process inventory is unavailable") end
        for _, process in ipairs(processes) do
            if withdrawn[process.source] then return "close or drain running component process before removal: " .. process.source end
        end
    end
    return nil
end
function M.allowed(work: lifecycle.Work): string?
    for _, service in ipairs(work.services) do
        if not security.can("funcs.call", service.handler) then return "host lifecycle grant required: " .. service.handler end
        if not security.can("events.send", "supervisor") or not security.can("system.read", "supervisor") then
            return "host supervisor lifecycle grants required"
        end
    end
    return nil
end
local function owner(service: lifecycle.Service, digest: string, phase: string): string?
    local scope, scope_error = security.named_scope("bee.hub.security:lifecycle_scope")
    if not scope then return tostring(scope_error) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return tostring(executor_error) end
    local reply, problem = executor:call(service.handler, {version = 1, digest = digest, service = service.id,
        phase = phase, definition = phase == "quiesce" and service.before or service.candidate, retention = service.retention})
    if problem then return "owner lifecycle result is uncertain: " .. tostring(problem) end
    local value = bounds.object(reply)
    if not value or bounds.fields(value, {"version", "digest", "service", "phase", "definition", "retention", "ok", "message"})
        or value.version ~= 1 or value.digest ~= digest or value.service ~= service.id or value.phase ~= phase
        or value.definition ~= (phase == "quiesce" and service.before or service.candidate)
        or value.retention ~= "retain" or value.ok ~= true then
        return "owner has not verified " .. phase .. " for " .. service.id
    end
    return nil
end
local function supervisor(id: string, action: string, expected: string): string?
    local subscription, subscribe_error = events.subscribe("supervisor", "service.update")
    if not subscription then return tostring(subscribe_error) end
    local updates = subscription:channel()
    local signals = assert(process.events())
    local function finish(problem: string?): string?
        subscription:close()
        return problem
    end
    local function reached(status: string, desired: string): boolean
        return desired == expected and (status == expected or (expected == "stopped" and status == "exited"))
    end
    local current, read_error = system.supervisor.state(id)
    if not current then return finish(tostring(read_error or "service is not supervised: " .. id)) end
    if reached(current.status, current.desired) then return finish(nil) end
    local sent, send_error = events.send("supervisor", "service." .. action, id)
    if not sent then return finish(tostring(send_error or "supervisor refused service transition")) end
    while true do
        local state, problem = system.supervisor.state(id)
        if not state then return finish(tostring(problem or "service state unavailable")) end
        if reached(state.status, state.desired) then return finish(nil) end
        if state.status == "failed" or (expected == "running" and state.status == "exited") then
            return finish("service " .. id .. " entered " .. state.status .. ": " .. tostring(state.details))
        end
        local selected = channel.select({updates:case_receive(), signals:case_receive()})
        if not selected.ok then return finish("service transition event channel closed: " .. id) end
        if selected.channel == signals and selected.value.kind == process.event.CANCEL then
            return finish("service transition wait cancelled: " .. id)
        end
    end
end
function M.quiesce(work: lifecycle.Work, digest: string): string?
    local problem = definitions(work, false) or M.allowed(work)
    if problem then return problem end
    for _, service in ipairs(work.services) do
        if service.change ~= "install" then
            if work.phase ~= "quiesced" then
                local drained = owner(service, digest, "quiesce")
                if drained then return drained end
            end
            local stopped = supervisor(service.id, "stop", "stopped")
            if stopped then return stopped end
        end
    end
    return definitions(work, false) or removal_obligations()
end
function M.ready(work: lifecycle.Work, digest: string): string?
    local problem = definitions(work, true) or M.allowed(work)
    if problem then return problem end
    for _, service in ipairs(work.services) do
        if service.change ~= "remove" then
            local started = supervisor(service.id, "start", "running")
            if started then return started end
            local verified = owner(service, digest, "ready")
            if verified then return verified end
        else
            local state = system.supervisor.state(service.id)
            if state and state.status ~= "stopped" and state.status ~= "exited" then return "removed service remains running: " .. service.id end
        end
    end
    return definitions(work, true)
end
return M
