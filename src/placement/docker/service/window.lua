-- SPDX-License-Identifier: MIT
local window = require("window")
local execution = require("execution")
return {open = function(attempt_id: string, options: unknown): (window.Window?, string?)
    return window.open_local(attempt_id, options, execution.backend())
end}
