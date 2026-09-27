-- MIT. Shared conversion from runtime time values to epoch seconds.
local time = require("time")

local M = {}

function M.epoch_seconds(value: time.Time): number
    return value:unix_nano() / 1000000000
end

return M
