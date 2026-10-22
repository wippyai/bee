-- MIT. The placements a host derives from a native host and from a Docker
-- coding container, with the permission capabilities both allow.
local placement = require("placement")

local ALLOWS: {string} = {"prompt", "edit", "automatic", "deny-unapproved", "read", "bypass", "write-admitted", "write-anywhere", "network", "request-approval", "no-approvals"}
local NATIVE: placement.Placement = {kind = "native", mounts = {}, network = "host", allows = ALLOWS}
local DOCKER: placement.Placement = {kind = "container", mounts = {{resource = "project", target = "/workspace", access = "write"}}, network = "bee-coding", allows = ALLOWS}

return {NATIVE = NATIVE, DOCKER = DOCKER}
