-- SPDX-License-Identifier: MIT
local display = require("display")
local remote = require("remote")
local delivery = require("delivery")
local M = {}
function M.choose(_ops: remote.Operations, node: string, workspace: string, mode: "control" | "observe",
    _key: string): (remote.Opened?, display.Fault?, display.Target?)
    assert(delivery.attach("viewer-fixture", "invalid-viewer-fixture-mount"))
    return {handle = {id = "viewer-fixture"}, target = {node_id = node, workspace_id = workspace,
        owner_execution = string.rep("a", 32), desktop_id = string.rep("c", 32), mode = mode}}, nil, nil
end
return M
