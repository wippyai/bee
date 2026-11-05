-- SPDX-License-Identifier: MIT
local process = require("process")
local ctx = require("ctx")
local bounds = require("bounds")
local measure_clock = require("measure_clock")
local controllers = require("controllers")

return {
    ["bee.harness.service.carrier.step"] = function(payload: unknown?): unknown
        local point = bounds.object(payload)
        if point and type(point.controller) == "string" and ctx.get("bee.test.carrier.progress") == true then
            assert(process.send(point.controller, "bee.test.carrier.progress", point.step))
        end
        return nil
    end,
    -- A suite registered as bee.test.schema.reads hears each driver schema read.
    ["bee.drivers.descriptor.profile_values.schema"] = function(payload: unknown?): unknown
        controllers.notify("bee.test.schema.reads", "bee.test.schema.read", payload)
        return nil
    end,
    ["bee.harness.launch.measure"] = function(): unknown
        return measure_clock.instant
    end,
}
