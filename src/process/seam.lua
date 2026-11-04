-- SPDX-License-Identifier: MIT
-- Seam points: named places where a test composition observes or steers a
-- component.
--
-- A component imports `seam` and calls it at the point by name. The
-- bee.process:seams requirement links every such import; its default is this
-- library, which passes straight through: call returns nil, hold returns at
-- once, after is time.after and the clock reads the current instant. A test composition
-- binds the requirement to its own library with the same functions.
local time = require("time")
local channel = require("channel")

local M = {}

-- A value the point reads, or nil.
function M.call(point: string, payload: unknown?): unknown
    return nil
end

-- Holds the caller until released and returns the release payload; the
-- second result is true when the lifecycle channel delivered a cancellation.
function M.hold(point: string, payload: unknown?, lifecycle: channel.Channel<any>?): (unknown, boolean)
    return nil, false
end

-- A timer that fires after duration.
function M.after(point: string, duration: string, payload: unknown?): channel.Channel<any>
    return time.after(duration)
end

-- The current instant.
function M.now(point: string, payload: unknown?): time.Time
    return time.now()
end

return M
