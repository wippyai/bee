-- SPDX-License-Identifier: MIT
local io = require("io")

local function main(message: string): integer
    assert(io.eprint(message))
    return 1
end

return {main = main}
