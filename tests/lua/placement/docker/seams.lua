-- SPDX-License-Identifier: MIT
local process = require("process")
local ctx = require("ctx")
local bounds = require("bounds")
local controllers = require("controllers")

local function attempt_of(payload: unknown?): unknown
    local point = bounds.object(payload)
    return point and point.attempt_id
end

local points: {[string]: (unknown?) -> unknown} = {}

-- A registered controller orders the owner's cleanup and may refuse it.
points["bee.placement.docker.binding.methods.cleanup_loaded"] = function(payload: unknown?): unknown
    local controller = process.registry.lookup("bee.test.docker.cleanup", process.registry.LOCAL)
    if not controller then return nil end
    local release = assert(process.listen("bee.test.docker.cleanup.release", {message = true}))
    assert(process.send(tostring(controller), "bee.test.docker.cleanup", {attempt_id = attempt_of(payload)}))
    local response = assert((release:receive()))
    assert(tostring(response:from()) == tostring(controller), "cleanup gate released by another process")
    process.unlisten(release)
    local decision = bounds.object(response:payload():data())
    if decision and decision.fail == true then return "fixture cleanup refusal" end
    return nil
end

points["bee.placement.docker.binding.methods.cleanup_observed"] = function(payload: unknown?): unknown
    local controller = ctx.get("bee.test.docker.cleanup.snapshot")
    if type(controller) ~= "string" then return nil end
    return {controller = controller, report = "bee.test.docker.cleanup.snapshot", release = "bee.test.docker.cleanup.resume", payload = {attempt_id = attempt_of(payload)}}
end

points["bee.placement.docker.binding.methods.cleanup_failure_recorded"] = function(): unknown
    return controllers.registered("bee.test.docker.cleanup.outcome", "bee.test.docker.cleanup.continue", nil, {})
end

return points
