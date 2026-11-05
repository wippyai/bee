-- SPDX-License-Identifier: MIT
local process = require("process")
local registry = require("registry")
local ctx = require("ctx")
local bounds = require("bounds")

type Hold = {controller: string, report: string?, release: string, payload: unknown?}

local PREPARER_CONFIG = "bee.tests.placement.native:preparer_fixture_config"

local function environment(payload: unknown?): {[string]: unknown}
    local point = bounds.object(payload)
    return point and bounds.object(point.environment) or {}
end

local function attempt_of(payload: unknown?): unknown
    local point = bounds.object(payload)
    return point and point.attempt_id
end

local function fixture(): {[string]: unknown}
    local entry = registry.get(PREPARER_CONFIG)
    return entry and bounds.object(entry.data) or {}
end

-- The runner's drain clock and spool report are per runner process.
local drain_instant: integer = 0
local drain_proved = false
local spool_reported = false
local drain_timers = 0

local points: {[string]: (unknown?) -> unknown} = {}

points["bee.placement.native.service.runner.claimed"] = function(payload: unknown?): unknown
    local controller = environment(payload).BEE_TEST_CLAIM_CONTROLLER
    if type(controller) ~= "string" then return nil end
    return {controller = controller, report = "bee.test.claim.held", release = "bee.test.claim.release", payload = {attempt_id = attempt_of(payload)}}
end

points["bee.placement.native.service.runner.starting"] = function(payload: unknown?): unknown
    local env = environment(payload)
    local controller = env.BEE_TEST_STARTUP_CONTROLLER
    if type(controller) == "string" then
        return {controller = controller, report = "bee.test.runner.held", release = "bee.test.runner.release", payload = {attempt_id = attempt_of(payload)}}
    end
    if env.PROBE_VALUE == "hold-retention" then
        local point = assert(bounds.object(payload))
        return {controller = assert(bounds.text(point.recipient)), report = "bee.test.native.held", release = "bee.test.native.release", payload = {attempt_id = attempt_of(payload)}}
    end
    return nil
end

points["bee.placement.native.service.runner.drain_clock"] = function(payload: unknown?): unknown
    if type(environment(payload).BEE_TEST_DRAIN_CONTROLLER) ~= "string" then return nil end
    return drain_instant
end

points["bee.placement.native.service.runner.drain_timer"] = function(payload: unknown?): unknown
    local controller = environment(payload).BEE_TEST_DRAIN_CONTROLLER
    if type(controller) ~= "string" then return nil end
    drain_timers = drain_timers + 1
    return {controller = controller, release = "bee.test.drain.expire." .. tostring(drain_timers)}
end

points["bee.placement.native.service.runner.drain_state"] = function(payload: unknown?): unknown
    local point = assert(bounds.object(payload))
    local controller = environment(payload).BEE_TEST_DRAIN_CONTROLLER
    if type(controller) == "string" and point.exited and point.reads_paused and not drain_proved then
        drain_proved = true
        drain_instant = drain_instant + 10000000000
        assert(process.send(controller, "bee.test.drain.paused", {attempt_id = point.attempt_id,
            remaining = point.remaining, armed = point.armed, spooled = point.spooled}))
    end
    return nil
end

points["bee.placement.native.service.runner.spool_full"] = function(payload: unknown?): unknown
    local controller = environment(payload).BEE_TEST_BACKPRESSURE_CONTROLLER
    if type(controller) == "string" and not spool_reported then
        spool_reported = true
        local point = assert(bounds.object(payload))
        assert(process.send(controller, "bee.test.native.backpressure", {attempt_id = point.attempt_id, spooled = point.spooled}))
    end
    return nil
end

points["bee.placement.native.service.runner.drain_only"] = function(payload: unknown?): unknown
    return environment(payload).PROBE_VALUE == "expire-pipe"
end

points["bee.placement.native.service.runner.retention"] = function(payload: unknown?): unknown
    local controller = environment(payload).BEE_TEST_RETENTION_CONTROLLER
    if type(controller) ~= "string" then return nil end
    return {controller = controller, report = "bee.test.retention.armed", release = "bee.test.retention.expire", payload = {attempt_id = attempt_of(payload)}}
end

local function fence(phase: string): (unknown?) -> unknown
    return function(payload: unknown?): unknown
        local env = environment(payload)
        if env.BEE_TEST_FENCE_PHASE ~= phase then return nil end
        return {controller = assert(bounds.text(env.BEE_TEST_FENCE_CONTROLLER)), report = "bee.test.attach.held", release = "bee.test.attach.release", payload = {phase = phase}}
    end
end
points["bee.placement.native.service.runner.attach_installing"] = fence("before")
points["bee.placement.native.service.runner.attach_installed"] = fence("after")

points["bee.placement.native.service.service.attach_startup"] = function(): unknown
    local controller = ctx.get("bee.test.attach.controller")
    if type(controller) == "string" then
        assert(process.send(controller, "bee.test.attach.held", {phase = "startup"}))
    end
    return nil
end

points["bee.placement.native.service.service.fence_timer"] = function(): unknown
    local controller = ctx.get("bee.test.attach.controller")
    if type(controller) ~= "string" then return nil end
    return {controller = controller, report = "bee.test.attach.held", release = "bee.test.attach.timeout", payload = {phase = "waiting"}}
end

points["bee.placement.native.persist.store.attempt_read"] = function(payload: unknown?): unknown
    local controller = ctx.get("bee.test.attempt.snapshot")
    if type(controller) ~= "string" then return nil end
    return {controller = controller, report = "bee.test.attempt.snapshot", release = "bee.test.attempt.release", payload = {attempt_id = attempt_of(payload)}}
end

points["bee.placement.native.persist.store.transition_committed"] = function(payload: unknown?): unknown
    local point = assert(bounds.object(payload))
    local evidence = bounds.object(point.evidence)
    if evidence and evidence.kind == "test.transition_snapshot" then
        local transition = point.transition :: ((unknown) -> {ok: boolean})
        assert(transition({cleanup = "complete",
            evidence = {kind = "test.transition_advanced", detail = "subsequent committed transition"}}).ok)
    end
    return nil
end

points["bee.placement.native.service.workdir_preparers.cleanup_attempted"] = function(): unknown
    local observer = fixture().cleanup_observer
    if type(observer) == "string" then assert(process.send(observer, "bee.test.preparer.observed", {})) end
    return nil
end

points["bee.placement.native.service.workdir_preparers.cleanup_gate"] = function(): unknown
    local gate = fixture().cleanup_gate
    if type(gate) ~= "string" then return nil end
    return {controller = gate, report = "bee.test.preparer.gate", release = "bee.test.preparer.gate.release", payload = {}}
end

points["bee.placement.native.service.workdir_preparers.cleanup_claimed"] = function(payload: unknown?): unknown
    local config = fixture()
    if config.cleanup_crash_attempt ~= attempt_of(payload) or type(config.cleanup_crash) ~= "string" then return nil end
    local crash = assert(process.listen("bee.test.preparer.crash", {message = true}))
    assert(process.send(config.cleanup_crash, "bee.test.preparer.claimed", {}))
    assert((crash:receive()))
    error("fixture cleanup owner crashed")
end

points["bee.placement.native.service.workdir_preparers.cleanup_follow"] = function(payload: unknown?): unknown
    local waiter = fixture().cleanup_waiter
    if type(waiter) ~= "string" then return nil end
    local point = assert(bounds.object(payload))
    return {controller = waiter, report = "bee.test.preparer.waiting", release = "bee.test.preparer.proceed", payload = {holder = tostring(point.holder)}}
end

return points
