-- MIT. Bee's planning envelope, independent of the WAPP transport byte limit.
-- See docs/hub-package-limits.md for the runtime contract and pack measurements.
local M = {}
M.MAX_PACKAGE_ENTRIES = 4096
M.MAX_STATE_ENTRIES = 16384
return M
