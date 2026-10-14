-- SPDX-License-Identifier: MIT
local registry = require("registry")
local process = require("process")
local events = require("events")
local system = require("system")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local time = require("time")
local channel = require("channel")
local worker = require("worker")
local bounds = require("bounds")
local clock = require("clock")
local demand = require("demand")
local state = require("state")
local M = {}
local ALLOWED: {[string]: boolean} = {
    ["bee.credentials.service:configuration_service"] = true,
    ["bee.node.service:tests_service"] = true,
    ["bee.gov.service:activation_service"] = true,
    ["bee.gateway.service:external_service"] = true,
    ["bee.gateway.service:access_service"] = true,
    ["bee.placement.docker.service:image_owner_service"] = true,
    ["bee.placement.native.service:sweeper_service"] = true,
}
type Dispatch = {caller: string, data: unknown}
type Owner = {id: string, name: string, probe: string?, state: state.Owner, queue: {Dispatch}, tables: {[string]: boolean}, feeds: {[string]: boolean},
    actor: string, policies: {string}, probe_error: string?, retry_at: integer?, retry_ms: integer}
type Owners = {[string]: Owner}
type Found = {[string]: unknown}
type Find = (selector: {[string]: string}) -> ({Found}?, string?)
M.Owners = Owners
local function names(list: unknown): {[string]: boolean}
    local seen: {[string]: boolean} = {}
    if type(list) == "table" then
        for _, name in ipairs(list) do if type(name) == "string" then seen[name] = true end end
    end
    return seen
end
local function declare(entry: Found, spec: {[string]: unknown}, name: string, previous: Owners?): (Owner?, string?)
    local id = tostring(entry.id)
    local data = bounds.object(entry.data)
    local lifecycle = data and bounds.object(data.lifecycle)
    local declared = lifecycle and bounds.object(lifecycle.security)
    local actor = declared and bounds.object(declared.actor)
    local listed = declared and bounds.array(declared.policies, 64)
    local actor_id = actor and bounds.id(actor.id)
    if not (data and lifecycle and declared and actor and listed and actor_id) then
        return nil, id .. ": demand service lifecycle security is invalid"
    end
    local policies: {string} = {}
    for _, policy in ipairs(listed) do
        if type(policy) ~= "string" then return nil, id .. ": demand service policy identifier is invalid" end
        policies[#policies + 1] = policy
    end
    local existing = previous and previous[name]
    local probe = type(spec.probe) == "string" and spec.probe or nil
    local retry = existing and existing.probe == probe and existing or nil
    return {id = id, name = name, actor = actor_id, policies = policies,
        probe = probe, probe_error = retry and retry.probe_error or nil,
        retry_at = retry and retry.retry_at or nil, retry_ms = retry and retry.retry_ms or worker.RETRY_FIRST_MS,
        state = existing and existing.state or state.new(), queue = existing and existing.queue or {},
        tables = names(spec.tables), feeds = names(spec.feeds)}, nil
end
-- discover reads the demand-driven services; a failed registry read or a
-- malformed declaration returns its error and leaves the previous owners as they are.
function M.discover(previous: Owners?, find: Find?): (Owners?, string?)
    local entries, problem = (find or registry.find)({["meta.type"] = "bee.process.demand"})
    if not entries then return nil, tostring(problem or "registry find returned no entries") end
    local owners: Owners = {}
    for _, entry in ipairs(entries) do
        local meta: unknown = entry.meta
        local spec = type(meta) == "table" and meta.demand or nil
        if ALLOWED[tostring(entry.id)] and entry.kind == "process.service" and type(spec) == "table" and type(spec.name) == "string" then
            local owner, owner_error = declare(entry, spec, spec.name, previous)
            if not owner then return nil, owner_error end
            owners[spec.name] = owner
        end
    end
    return owners, nil
end
local function snapshot(owner: Owner): state.Snapshot?
    local current = system.supervisor.state(owner.id)
    if not current then return nil end
    local holder = process.registry.lookup(owner.name, process.registry.LOCAL)
    return {status = current.status, desired = current.desired, started = current.started_at,
        holder = holder and tostring(holder) or nil}
end
local function command(owner: Owner, action: string)
    if action == "start" or action == "stop" then
        assert(events.send("supervisor", "service." .. action, owner.id))
    end
end
local function deliver(owner: Owner)
    local pid = owner.state.pid
    if not pid then return end
    local first = true
    repeat
        local requests: {Dispatch} = {}
        for index = 1, math.min(64, #owner.queue) do requests[index] = owner.queue[index] end
        if not first then state.transition(owner.state, "batch", nil, nil, nil) end
        first = false
        local sent = process.send(pid, demand.WAKE, {generation = owner.state.generation, requests = requests})
        if not sent then
            command(owner, state.transition(owner.state, "failed", pid, nil, snapshot(owner)))
            return
        end
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
    state.transition(owner.state, "delivered", pid, nil, nil)
end
local function transition(owner: Owner, event: string, pid: string?, generation: integer?)
    local action = state.transition(owner.state, event, pid, generation, snapshot(owner))
    if action == "deliver" then deliver(owner)
    else command(owner, action) end
end
function M.wake(owners: Owners, name: string, request: Dispatch?): boolean
    local owner = owners[name]
    if not owner then return false end
    if request then
        local queue = owner.queue
        queue[#queue + 1] = request
    end
    transition(owner, "wake", nil, nil)
    return true
end
function M.feed(owners: Owners, path: string)
    for name, owner in pairs(owners) do
        if owner.feeds[path] then M.wake(owners, name, nil) end
    end
end
function M.ready(owners: Owners, name: string, pid: string)
    local owner = owners[name]
    if not owner then return end
    local holder = process.registry.lookup(name, process.registry.LOCAL)
    if not holder or tostring(holder) ~= pid then return end
    process.monitor(pid)
    transition(owner, "ready", pid, nil)
end
function M.receive(owners: Owners, from: string, raw: unknown)
    if type(raw) ~= "table" or type(raw.name) ~= "string" then return end
    local owner = owners[raw.name]
    if not owner then return end
    if raw.action == "wake" then M.wake(owners, raw.name, nil)
    elseif raw.action == "dispatch" then M.wake(owners, raw.name, {caller = from, data = raw.value})
    elseif raw.action == "ready" then M.ready(owners, raw.name, from)
    elseif raw.action == "quiet" and type(raw.value) == "number" then
        transition(owner, "quiet", from, math.floor(raw.value))
    end
end
function M.exit(owners: Owners, pid: string)
    for _, owner in pairs(owners) do transition(owner, "exit", pid, nil) end
end
function M.update(owners: Owners)
    for _, owner in pairs(owners) do transition(owner, "update", nil, nil) end
end
function M.tables(owners: Owners): {string}
    local seen: {[string]: boolean} = {}
    for _, owner in pairs(owners) do for name in pairs(owner.tables) do seen[name] = true end end
    local tables: {string} = {}
    for name in pairs(seen) do tables[#tables + 1] = name end
    return tables
end

local function probe(owner: Owner): boolean
    local policies: {security.Policy} = {}
    for _, id in ipairs(owner.policies) do policies[#policies + 1] = assert(security.policy(id)) end
    local executor = funcs.new():with_actor(security.new_actor(owner.actor)):with_scope(security.new_scope(policies))
    local pending, problem = assert(executor):call(assert(owner.probe))
    if problem then error(problem) end
    assert(type(pending) == "boolean", "demand backlog probe must return a boolean")
    return pending
end

-- A domain's failed probe is an unknown backlog, not an empty one or a Hive
-- failure. Retain its error and retry independently with the worker backoff.
local function recover(owners: Owners, name: string, owner: Owner)
    local called, pending = pcall(probe, owner)
    if not called then
        owner.probe_error = tostring(pending)
        owner.retry_at = clock.milliseconds() + owner.retry_ms
        logger:error("Demand backlog probe failed", {owner = owner.id, probe = owner.probe,
            cause = owner.probe_error, retry_ms = owner.retry_ms})
        owner.retry_ms = math.min(owner.retry_ms * 2, worker.RETRY_LAST_MS)
        return
    end
    owner.probe_error, owner.retry_at, owner.retry_ms = nil, nil, worker.RETRY_FIRST_MS
    if pending == true then M.wake(owners, name, nil) end
end

function M.recover(owners: Owners, changed: string?)
    for name, owner in pairs(owners) do
        if not changed and owner.state.phase == "absent" then
            local pid = process.registry.lookup(name, process.registry.LOCAL)
            if pid then M.ready(owners, name, tostring(pid)); M.wake(owners, name, nil) end
        end
        if owner.probe and (not changed or owner.tables[changed]) then
            recover(owners, name, owner)
        end
    end
end
function M.retry(owners: Owners)
    local current = clock.milliseconds()
    for name, owner in pairs(owners) do
        if owner.probe and owner.retry_at and owner.retry_at <= current then recover(owners, name, owner) end
    end
end
function M.deadline(owners: Owners): channel.Channel<time.Time>?
    local earliest: integer? = nil
    for _, owner in pairs(owners) do
        if owner.retry_at and (not earliest or owner.retry_at < earliest) then earliest = owner.retry_at end
    end
    return earliest and time.after(tostring(math.max(1, earliest - clock.milliseconds())) .. "ms") or nil
end
function M.available(owners: Owners, name: string): boolean
    local owner = owners[name]
    return not owner or owner.state.phase == "ready"
end
return M
