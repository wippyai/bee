-- SPDX-License-Identifier: MIT
local process = require("process")
local function forger(owner: string, supervisor: string, workspace_id: string, desktop_id: string)
    assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id,
        desktop_id = desktop_id, request_id = "forged", recipient = owner, op = "attach", mode = "control"}))
    assert(process.send(supervisor, "bee.retained.launch", {version = 1, workspace_id = workspace_id,
        desktop_id = desktop_id, request_id = "forged-launch", recipient = owner, name = "terminal", arguments = {}}))
    assert(process.send(supervisor, "bee.retained.desktops", {version = 1, workspace_id = workspace_id,
        request_id = "forged-storage", op = "allocate", desktop_id = string.rep("b", 32)}))
    assert(process.send(supervisor, "bee.retained.activate", {version = 1, workspace_id = workspace_id,
        request_id = "forged-activation", desktop_id = string.rep("b", 32)}))
    assert(process.send(owner, "forged.sent", {}))
end
return {forger = forger}
