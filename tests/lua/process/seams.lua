-- SPDX-License-Identifier: MIT
local process = require("process")
local controllers = require("controllers")

type Observer = {pid: string, topic: string, controller: string}

local delivery_stopped = false
local stopped_observers: {[string]: Observer} = {}
local materialization_wakes: {[string]: integer} = {}

local function notify_stopped(name: string, phase: string)
    if phase ~= "absent" then return end
    local observer = stopped_observers[name]
    if not observer then return end
    local controller = process.registry.lookup(observer.controller, process.registry.LOCAL)
    if controller and tostring(controller) == observer.pid then
        assert(process.send(observer.pid, observer.topic, {}))
    end
end

local M: {[string]: (unknown?) -> unknown} = {}

M["bee.process.demand_owner.admitted"] = function(payload: any): unknown
    return payload.id == "bee.tests.process:transaction_service"
end

M["bee.process.demand_owner.command"] = function(payload: any): unknown
    if payload.owner == "bee.test.transaction.owner" then
        controllers.notify("bee.test.transaction.demand", "bee.test.transaction.command",
            {action = payload.action, phase = payload.phase, queued = payload.queued})
    end
    return nil
end

M["bee.process.demand_owner.delivering"] = function(payload: any): unknown
    if delivery_stopped or payload.name ~= "bee.gateway.external" then return nil end
    local hold = controllers.registered("bee.test.hive.delivery_stop", "bee.test.hive.delivery_release", nil, {pid = payload.pid})
    if hold then delivery_stopped = true end
    return hold
end

M["bee.process.demand_owner.commanding"] = function(payload: any): unknown
    if payload.owner ~= "bee.gateway.access" or payload.action ~= "start" then return nil end
    return controllers.registered("bee.test.hive.commanding", "bee.test.hive.command")
end

M["bee.process.demand_owner.delivered"] = function(payload: any): unknown
    controllers.notify("bee.test.effect_delivery", nil,
        {name = payload.name, pid = payload.pid, generation = payload.generation, requests = payload.requests})
    return nil
end

M["bee.process.demand_owner.transitioned"] = function(payload: any): unknown
    notify_stopped(payload.name, payload.phase)
    return nil
end

M["bee.process.demand_owner.received"] = function(payload: any): unknown
    local from: string = payload.from
    local raw: any = payload.message
    local wake = process.registry.lookup("bee.test.materialization.wake", process.registry.LOCAL)
    if wake and tostring(wake) == from and type(raw) == "table" and raw.name == "bee.placement.sweeper" then
        if raw.action == "bee.test.materialization.wakes" then
            assert(process.send(from, "bee.test.materialization.wakes", {count = materialization_wakes[from] or 0}))
            return true
        elseif raw.action == "wake" then
            materialization_wakes[from] = (materialization_wakes[from] or 0) + 1
        end
    end
    if type(raw) == "table" and raw.action == "bee.test.owner.stopped" and type(raw.name) == "string" and type(raw.topic) == "string" then
        local name = "bee.test.owner.stopped." .. raw.name
        local controller = process.registry.lookup(name, process.registry.LOCAL)
        if controller and tostring(controller) == from then
            stopped_observers[raw.name] = {pid = from, topic = raw.topic, controller = name}
            local owner = payload.owners[raw.name]
            if owner then notify_stopped(raw.name, owner.state.phase) end
        end
        return true
    end
    local delivery = process.registry.lookup("bee.test.effect_delivery", process.registry.LOCAL)
    if delivery and tostring(delivery) == from and type(raw) == "table" and raw.action == "bee.test.boot_backlog" then
        payload.recover()
        assert(process.send(from, "bee.test.boot_backlog.recovered", {}))
        return true
    end
    return nil
end

M["bee.process.worker.ready"] = function(payload: any): unknown
    if payload.name ~= "bee.gateway.access" then return nil end
    return controllers.registered("bee.test.access.start", "bee.test.access.release")
end

-- The approval delivery worker skips its passes while a test holds the
-- local name bee.test.approvals.delivery_paused.
M["bee.process.worker.pass"] = function(payload: any): unknown
    if payload.name == "bee.approvals.outbox" then
        return process.registry.lookup("bee.test.approvals.delivery_paused", process.registry.LOCAL) ~= nil
    end
    return payload.name == "bee.approvals.configuration_effect_worker" or payload.name == "bee.gov.activation_worker"
end

return M
