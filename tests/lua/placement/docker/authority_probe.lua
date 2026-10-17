-- SPDX-License-Identifier: MIT
local environment = require("environment")
local bounds = require("bounds")
local M = {}
function M.run(raw: unknown): {[string]: unknown}
    local input = assert(bounds.object(raw))
    local grant, err = environment.authority({state = "approved", selection_digest = tostring(input.digest), approval_id = tostring(input.approval_id),
        proposal_digest = string.rep("0", 64), owner_incarnation = 1, address = "192.168.48.1:0"},
        {workspace = tostring(input.workspace), profile = "bee.placement.docker.profiles:coding", digest = tostring(input.digest), network = tostring(input.network), policy = "docker-environment"})
    return {grant_id = grant and grant.grant_id or nil, error = err}
end
return M
