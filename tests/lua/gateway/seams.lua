-- SPDX-License-Identifier: MIT
local M: {[string]: (unknown?) -> unknown} = {}

M["bee.gateway.service.external.drain_disabled"] = function(): unknown return true end
M["bee.gateway.service.backlog.disabled"] = function(): unknown return true end

return M
