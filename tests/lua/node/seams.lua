-- SPDX-License-Identifier: MIT
local M: {[string]: (unknown?) -> unknown} = {}

M["bee.node.application_tests.test_type"] = function(): unknown return "app_test" end

return M
