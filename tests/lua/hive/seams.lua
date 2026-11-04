-- SPDX-License-Identifier: MIT
local process = require("process")
local system = require("system")
local controllers = require("controllers")

local function registered(name: string): boolean
    return process.registry.lookup(name, process.registry.LOCAL) ~= nil
end

local M: {[string]: (unknown?) -> unknown} = {}

M["bee.hive.service.supervisor.started"] = function(): unknown
    controllers.notify("bee.test.hive.upgrade_ready")
    return nil
end

M["bee.hive.service.supervisor.parked"] = function(): unknown
    controllers.notify("bee.test.hive.upgrade_parked")
    return nil
end

M["bee.hive.service.supervisor.announced"] = function(payload: any): unknown
    if payload.name ~= "bee.test.transaction.owner" or not registered("bee.test.transaction.demand") then return nil end
    local owner = assert(payload.owner)
    local current = assert(system.supervisor.state(owner.id))
    controllers.notify("bee.test.transaction.demand", "bee.test.transaction.running",
        {phase = owner.state.phase, queued = #owner.queue, parked = payload.parked, status = current.status, desired = current.desired})
    return nil
end

M["bee.hive.service.supervisor.backlog_closed"] = function(): unknown
    if registered("bee.test.hive.backlog_hold") then return nil end
    return controllers.registered("bee.test.hive.backlog_terminal", "bee.test.hive.backlog_resume")
end

M["bee.hive.service.supervisor.backlog_changed"] = function(): unknown
    return controllers.registered("bee.test.hive.backlog_hold", "bee.test.hive.backlog_release")
end

M["bee.hive.service.supervisor.defer_readiness"] = function(payload: any): unknown
    local owner = payload.demanded["bee.gateway.external"]
    return owner ~= nil and owner.state.phase ~= "absent" and registered("bee.test.hive.demand_ready")
end

M["bee.hive.service.supervisor.listen"] = function(payload: any): unknown
    if not registered("bee.test.hive.backlog_terminal") then return nil end
    return {registered("bee.test.hive.backlog_registry") and payload.registry or payload.backlog, payload.events}
end

M["bee.hive.remote.find_fault"] = function(): unknown
    return registered("bee.test.hive.find_failure") and "injected registry failure" or nil
end

M["bee.hive.remote.overlay_fault"] = function(): unknown
    return registered("bee.test.hive.overlay_failure") and "injected overlay failure" or nil
end

return M
