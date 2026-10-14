-- SPDX-License-Identifier: MIT
local registry = require("registry")
return {capture = function(): {ok: boolean, error: string?}
    local snapshot, err = registry.snapshot()
    return {ok = snapshot ~= nil, error = err and tostring(err) or nil}
end}
