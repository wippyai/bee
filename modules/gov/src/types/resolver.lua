-- MIT. Destination-local resolution shared by staging and activation.
local preflight = require("preflight")

local M = {}
type Resolver = {resolve: (Resolver, unknown) -> (preflight.Candidate?, preflight.Context?, string?)}

return M
