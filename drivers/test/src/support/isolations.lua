-- MIT. The isolation values a host derives from a native placement and from
-- a Docker coding placement, with the per-driver option ceilings both admit.
local M = {}
local CEILINGS = {
    claude = {permission_mode = {"prompt", "edit", "automatic", "deny-unapproved", "read", "bypass"}, permission_bypass = {"bypass"}, allow_permission_bypass = {"bypass"}},
    codex = {sandbox = {"read", "write-admitted", "write-anywhere", "network"}, approval_policy = {"request-approval", "no-approvals"}, dangerously_bypass_approvals_and_sandbox = {"bypass"}},
    agy = {dangerously_skip_permissions = {"bypass"}},
    grok = {permission_mode = {"bypass"}},
    muse = {approval_mode = {"no-approvals"}, yolo = {"bypass"}},
    opencode = {auto = {"bypass"}},
}
M.NATIVE = {kind = "native", credentials = {"admitted launch credentials"}, mounted_roots = {}, network = "host", option_ceilings = CEILINGS}
M.DOCKER = {kind = "container", credentials = {"admitted launch credentials", "session gateway tokens"},
    mounted_roots = {{resource = "project", target = "/workspace", access = "write"}}, network = "bee-coding", option_ceilings = CEILINGS}
return M
