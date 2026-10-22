-- MIT. The placements a host derives from a native host and from a Docker
-- coding container, with the permission capabilities both allow.
local M = {}
local ALLOWS = {"prompt", "edit", "automatic", "deny-unapproved", "read", "bypass", "write-admitted", "write-anywhere", "network", "request-approval", "no-approvals"}
M.NATIVE = {kind = "native", mounts = {}, network = "host", allows = ALLOWS}
M.DOCKER = {kind = "container", mounts = {{resource = "project", target = "/workspace", access = "write"}}, network = "bee-coding", allows = ALLOWS}
return M
