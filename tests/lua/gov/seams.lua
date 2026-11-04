-- SPDX-License-Identifier: MIT
local M: {[string]: (unknown?) -> unknown} = {}

M["bee.gov.service.backlog.disabled"] = function(): unknown return true end

return M
