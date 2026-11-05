-- SPDX-License-Identifier: MIT
-- Seam points: named places where a host's test composition observes a
-- driver. A library imports `seam` and calls it at the point by name. The
-- bee.drivers:seams requirement links every such import; its default is this
-- library, whose call returns nil. A test composition binds the requirement to
-- its own library with the same function.
local M = {}

-- A value the point reads, or nil.
function M.call(point: string, payload: unknown?): unknown
    return nil
end

return M
