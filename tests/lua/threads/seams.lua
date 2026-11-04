-- SPDX-License-Identifier: MIT
local controllers = require("controllers")
return {
    ["bee.threads.service.committed"] = function()
        return controllers.registered("bee.test.threads.hold", "bee.test.threads.release", nil, {})
    end,
    ["bee.threads.service.capture_closed"] = function()
        return controllers.registered("bee.test.threads.terminal", "bee.test.threads.resume", nil, {})
    end,
}
