-- Canonical time conversions used at Bee protocol and presentation boundaries.
local time = require("time")
local M = {}
M.FORMAT = "2006-01-02T15:04:05.000Z07:00"

function M.utc(value: time.Time): string
    return value:utc():format(M.FORMAT)
end

function M.now(): string
    return M.utc(time.now())
end

function M.deadline(duration: string): string
    return M.utc(time.now():add(duration))
end

function M.elapsed_ms(started: time.Time, current: time.Time?): integer
    local instant = current or time.now()
    return math.floor(instant:sub(started):milliseconds())
end

function M.elapsed_seconds(current_nanoseconds: integer, previous_nanoseconds: integer): number
    return (current_nanoseconds - previous_nanoseconds) / 1000000000
end

return M
