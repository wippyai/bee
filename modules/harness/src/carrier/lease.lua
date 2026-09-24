-- MIT. A run holds a host lease on its workspace while it runs, so the node
-- host manager keeps that workspace's host serving until the run ends. The
-- manager starts the host when none serves, and a workspace another
-- composition serves (the folder workspace) is reported as served.
local leases = require("leases")
local M = {}
M.TIMEOUT = "30s"
-- The lease for a catalog workspace. Catalog identities are 32 lowercase
-- hexadecimal characters; any other identity names no host, so nothing is
-- held for it.
function M.hold(workspace_id: string?): (leases.Lease?, string?)
    if not workspace_id then return nil, nil end
    local identity: string = workspace_id
    if #identity ~= 32 or identity:find("[^0-9a-f]") then return nil, nil end
    return leases.acquire(identity, M.TIMEOUT)
end
function M.release(held: leases.Lease)
    leases.release(held)
end
return M
