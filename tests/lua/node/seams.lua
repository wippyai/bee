-- SPDX-License-Identifier: MIT
local process = require("process")
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
    ["bee.node.service.ready"] = function()
        controllers.notify("bee.test.node.ready")
        return nil
    end,
}
