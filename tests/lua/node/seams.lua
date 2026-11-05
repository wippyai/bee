-- SPDX-License-Identifier: MIT
local process = require("process")
local security = require("security")
local controllers = require("controllers")

return {
    ["bee.node.service.tests.quiet"] = function()
        return controllers.registered("bee.test.node.quiet", "bee.test.node.quiet.release", "bee.test.node.quiet", {})
    end,
    ["bee.node.service.catalog.find"] = function()
        local controller = process.registry.lookup("bee.test.node.registry_failure", process.registry.LOCAL)
        if not controller then return nil end
        process.send(tostring(controller), "bee.test.node.registry_failed", {pid = tostring(process.pid())})
        return "injected registry failure"
    end,
    ["bee.node.service.stop"] = function(instance)
        return controllers.registered("bee.test.retired.cancel", "bee.test.retired.release", "bee.test.retired.held",
            {id = (instance :: {id: string}).id})
    end,
    ["bee.node.service.desktop_chosen"] = function()
        return controllers.registered("bee.test.display.snapshot", "bee.test.display.release", nil, {})
    end,
    ["bee.node.service.ready"] = function()
        controllers.notify("bee.test.node.ready")
        return nil
    end,
    -- The fixture actor overlay-listing-fault receives a malformed overlay
    -- list from the overlay call the tests facade makes.
    ["bee.node.binding.overlay_listing"] = function()
        local actor = security.actor()
        if not actor or actor:id() ~= "overlay-listing-fault" then return nil end
        return {ok = true, value = {overlays = {{overlay_id = "runner_fixture"}, {overlay_id = 7}}}}
    end,
    -- The runner finds the fixture applications' tests by their own type, so
    -- the suites' unrestricted runner leaves them alone.
    ["bee.node.application_tests.test_type"] = function() return "app_test" end,
}
