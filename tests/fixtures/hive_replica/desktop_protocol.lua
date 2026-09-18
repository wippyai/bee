-- MIT. The replica acceptance has no desktop owner; this typed placeholder
-- keeps the supervisor's optional desktop seam out of the fixture composition.
local M = {}
type Configuration = {execution: string, expires_at: string, allowed_nodes: {string}, application: string?, local_clients: boolean?}
function M.configuration(value: unknown): (Configuration?, string?)
    if value ~= nil then return nil, "desktop is not enabled in this fixture" end
    return nil, nil
end
return M
