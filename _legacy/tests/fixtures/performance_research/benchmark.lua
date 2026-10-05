-- SPDX-License-Identifier: MIT
local canonical = require("canonical")
local measure = require("measure")
local function run(): {[string]: unknown}
    return measure.run(canonical.encode)
end
return {run = run}
