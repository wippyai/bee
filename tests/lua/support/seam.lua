-- SPDX-License-Identifier: MIT
-- The test composition's binding of bee.process:seams. Each point resolves to
-- a function an area's seams library exports under the point name; a point no
-- library names passes through as in the host.
--
-- call returns the point function's value. hold and after expect nil (pass)
-- or a Hold: the component sends report to controller from its own process
-- and waits for release from that controller.
local process_points = require("process_points")
local channel = require("channel")
local time = require("time")
local placement_native_points = require("placement_native_points")
local placement_docker_points = require("placement_docker_points")
local harness_points = require("harness_points")
local process_points = require("process_points")
local hive_points = require("hive_points")
local approvals_points = require("approvals_points")
local inbox_points = require("inbox_points")
local node_points = require("node_points")
local shell_points = require("shell_points")
local gov_points = require("gov_points")
local sync_points = require("sync_points")
local gateway_points = require("gateway_points")
local credentials_points = require("credentials_points")
local resources_points = require("resources_points")
local hub_points = require("hub_points")
local threads_points = require("threads_points")

type Hold = {controller: string, report: string?, release: string, payload: unknown?}
type Point = (unknown?) -> unknown

local POINTS: {[string]: Point} = {}
local AREAS = {placement_native_points, placement_docker_points, harness_points, process_points, hive_points, approvals_points, inbox_points, node_points, shell_points, gov_points, sync_points, gateway_points, credentials_points, resources_points, hub_points, threads_points}
for _, area in ipairs(AREAS) do
    for point, fn in pairs(area) do
        assert(POINTS[point] == nil, "seam point named twice: " .. point)
        POINTS[point] = fn
    end
end

local M = {}

function M.call(point: string, payload: unknown?): unknown
    local fn = POINTS[point]
    if not fn then return nil end
    return fn(payload)
end

local function held(point: string, payload: unknown?): Hold?
    local value = M.call(point, payload)
    if value == nil then return nil end
    assert(type(value) == "table" and type(value.controller) == "string" and type(value.release) == "string"
        and (value.report == nil or type(value.report) == "string"), "seam " .. point .. " returned an invalid hold")
    return value :: Hold
end

local function report(hold: Hold, payload: unknown?)
    if hold.report then
        assert(process.send(hold.controller, hold.report, hold.payload == nil and payload or hold.payload))
    end
end

function M.hold(point: string, payload: unknown?, lifecycle: channel.Channel<any>?): (unknown, boolean)
    local hold = held(point, payload)
    if not hold then return nil, false end
    local release = assert(process.listen(hold.release, {message = true}))
    report(hold, payload)
    while true do
        local cases = {release:case_receive()}
        if lifecycle then cases[2] = lifecycle:case_receive() end
        local selected = channel.select(cases)
        if selected.channel == release then
            local message = selected.value
            assert(tostring(message:from()) == hold.controller, "seam " .. point .. " released by another process")
            process.unlisten(release)
            return message:payload():data(), false
        end
        if not selected.ok or selected.value.kind == process.event.CANCEL then
            process.unlisten(release)
            return nil, true
        end
    end
end

function M.after(point: string, duration: string, payload: unknown?): channel.Channel<any>
    local hold = held(point, payload)
    if not hold then return time.after(duration) end
    local fire = assert(process.listen(hold.release, {message = true}))
    report(hold, payload)
    return fire
end

function M.now(point: string, payload: unknown?): time.Time
    local value = M.call(point, payload)
    if value == nil then return time.now() end
    assert(type(value) == "number" and math.tointeger(value), "seam " .. point .. " returned an invalid instant")
    local nanoseconds = math.floor(value)
    return time.unix(nanoseconds // 1000000000, nanoseconds % 1000000000)
end

return M
