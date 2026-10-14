-- SPDX-License-Identifier: MIT
local process = require("process")
local client = require("client")
return {main = function(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local selected = launch.resume_state == "" and (#launch.arguments == 0 or launch.arguments[1] == "--session")
    assert(process.upgrade(selected and "bee.harness.app:selection" or "bee.harness.app:execution", value))
end}
