-- SPDX-License-Identifier: MIT
-- The fixture actor overlay-listing-fault receives a malformed overlay list
-- from the overlay call the tests facade makes.
local security = require("security")
local M: {[string]: (unknown?) -> unknown} = {}
M["bee.node.binding.overlay_listing"] = function(): unknown
    local actor = security.actor()
    if not actor or actor:id() ~= "overlay-listing-fault" then return nil end
    return {ok = true, value = {overlays = {{overlay_id = "runner_fixture"}, {overlay_id = 7}}}}
end
return M
