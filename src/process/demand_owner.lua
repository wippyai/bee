-- SPDX-License-Identifier: MIT
local registry = require("registry")
local process = require("process")
local events = require("events")
local system = require("system")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local demand = require("demand")
local state = require("state")
local M = {}
local ALLOWED: {[string]: boolean} = {
    ["bee.credentials.service:configuration_service"] = true,
    ["bee.node.service:tests_service"] = true,
    ["bee.gov.service:activation_service"] = true,
    ["bee.gateway.service:external_service"] = true,
    ["bee.placement.docker.service:image_owner_service"] = true,
    ["bee.placement.native.service:sweeper_service"] = true,
}
type Dispatch = {caller: string, data: unknown}
type Owner = {id: string, name: string, probe: string?, state: state.Owner, queue: {Dispatch}, tables: {[string]: boolean}, actor: string, policies: {string}}
type Owners = {[string]: Owner}
M.Owners = Owners
function M.discover(previous: Owners?): Owners
    local owners: Owners = {}
    for _, entry in ipairs(registry.find({["meta.type"] = "bee.process.demand"}) or {}) do
        local meta: unknown = entry.meta
        local spec = type(meta) == "table" and meta.demand or nil
        if ALLOWED[entry.id] and entry.kind == "process.service" and type(spec) == "table" and type(spec.name) == "string" then
            local tables: {[string]: boolean} = {}
            if type(spec.tables) == "table" then
                for _, name in ipairs(spec.tables) do if type(name) == "string" then tables[name] = true end end
            end
            local existing = previous and previous[spec.name]
            local data = assert(bounds.object(entry.data), "demand service data")
            local lifecycle = assert(bounds.object(data.lifecycle), "demand service lifecycle")
            local declared = assert(bounds.object(lifecycle.security), "demand service security")
            local actor = assert(bounds.object(declared.actor), "demand service actor")
            local policies: {string} = {}
            for _, id in ipairs(assert(bounds.array(declared.policies, 64))) do
                assert(type(id) == "string", "demand service policy identifier")
                policies[#policies + 1] = id :: string
            end
            owners[spec.name] = {id = entry.id, name = spec.name, actor = assert(bounds.id(actor.id)), policies = policies,
                probe = type(spec.probe) == "string" and spec.probe or nil,
                state = existing and existing.state or state.new(), queue = existing and existing.queue or {},
                tables = tables}
        end
    end
    return owners
end
local function start(owner: Owner)
    assert(events.send("supervisor", "service.start", owner.id))
end
local function deliver(owner: Owner)
    local pid = owner.state.pid
    if not pid then return end
    local first = true
    repeat
        local requests: {Dispatch} = {}
        for index = 1, math.min(64, #owner.queue) do requests[index] = owner.queue[index] end
        if not first then owner.state.generation = owner.state.generation + 1 end
        first = false
        local sent = process.send(pid, demand.WAKE, {generation = owner.state.generation, requests = requests})
        if not sent then owner.state.pid, owner.state.phase = nil, "starting"; return end
        for _, request in ipairs(requests) do
            local data: unknown = request.data
            if type(data) == "table" and type(data.request_id) == "string" then
                process.send(request.caller, demand.ACCEPTED, {name = owner.name, pid = pid, request_id = data.request_id})
            end
        end
        local remaining: {Dispatch} = {}
        for index = #requests + 1, #owner.queue do remaining[#remaining + 1] = owner.queue[index] end
        owner.queue = remaining
    until #owner.queue == 0
end
function M.wake(owners: Owners, name: string, request: Dispatch?): boolean
    local owner = owners[name]
    if not owner then return false end
    if request then owner.queue[#owner.queue + 1] = request end
    local action = state.wake(owner.state)
    if action == "start" then start(owner :: Owner)
    elseif action == "deliver" then deliver(owner :: Owner) end
    return true
end
function M.ready(owners: Owners, name: string, pid: string)
    local owner = owners[name]
    if not owner then return end
    local holder = process.registry.lookup(name, process.registry.LOCAL)
    if not holder or tostring(holder) ~= pid then return end
    if state.ready(owner.state, pid) then
        process.monitor(pid)
        deliver(owner :: Owner)
    end
end
function M.receive(owners: Owners, from: string, raw: unknown)
    if type(raw) ~= "table" or type(raw.name) ~= "string" then return end
    local owner = owners[raw.name]
    if not owner then return end
    if raw.action == "wake" then M.wake(owners, raw.name, nil)
    elseif raw.action == "dispatch" then M.wake(owners, raw.name, {caller = from, data = raw.value})
    elseif raw.action == "ready" then M.ready(owners, raw.name, from)
    elseif raw.action == "quiet" and type(raw.value) == "number" then
        if state.quiet(owner.state, from, math.floor(raw.value)) then
            assert(events.send("supervisor", "service.stop", owner.id))
        elseif owner.state.phase == "ready" and owner.state.pid == from then deliver(owner :: Owner) end
    end
end
function M.exit(owners: Owners, pid: string)
    for _, owner in pairs(owners) do
        if owner.state.pid == pid then
            owner.state.pid = nil
            if owner.state.phase ~= "stopping" then owner.state.phase = "starting" end
        end
    end
end
function M.update(owners: Owners)
    for _, owner in pairs(owners) do
        local current = system.supervisor.state(owner.id)
        if current and current.desired == "stopped" and owner.state.phase == "stopping"
            and (current.status == "stopped" or current.status == "exited") then
            if state.stopped(owner.state) == "start" then start(owner :: Owner) end
        end
    end
end
function M.tables(owners: Owners): {string}
    local seen: {[string]: boolean} = {}
    for _, owner in pairs(owners) do for name in pairs(owner.tables) do seen[name] = true end end
    local tables: {string} = {}
    for name in pairs(seen) do tables[#tables + 1] = name end
    return tables
end
function M.recover(owners: Owners, changed: string?)
    for name, owner in pairs(owners) do
        if not changed and owner.state.phase == "absent" then
            local pid = process.registry.lookup(name, process.registry.LOCAL)
            if pid then M.ready(owners, name, tostring(pid)); M.wake(owners, name, nil) end
        end
        if owner.probe and (not changed or owner.tables[changed]) then
            local policies: {security.Policy} = {}
            for _, id in ipairs(owner.policies) do policies[#policies + 1] = assert(security.policy(id)) end
            local executor = funcs.new():with_actor(security.new_actor(owner.actor)):with_scope(security.new_scope(policies))
            local pending, problem = assert(executor):call(owner.probe)
            if problem then error("demand backlog " .. owner.id .. ": " .. tostring(problem)) end
            if pending == true then M.wake(owners, name, nil) end
        end
    end
end
function M.available(owners: Owners, name: string): boolean
    local owner = owners[name]
    return not owner or owner.state.phase == "ready"
end
return M
