-- MIT. Pure callee-side check for contract calls admitted by capability
-- grants. The caller grant authorizes the call; the callee owner verifies the
-- authenticated caller, workspace and object before using its own authority.
-- This helper decides on a decoded grant record and refuses anything else.
local bounds = require("bounds")

local M = {}
type Object = {[string]: unknown}

local function methods(raw: unknown): {string}?
    if type(raw) ~= "table" then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(raw :: {unknown}) do
        if type(item) ~= "string" or seen[item :: string] then return nil end
        seen[item :: string] = true
        result[#result + 1] = item :: string
    end
    return result
end

-- The callee owner calls this with the caller it authenticated: the owning
-- overlay, workspace and application the grant was installed for, the exact
-- binding and method invoked, and whether the grant record is still live.
-- Only an installed grant for that exact caller, binding and method passes.
function M.authorize(record_raw: unknown, owner_raw: unknown, workspace_raw: unknown,
    app_raw: unknown, binding_raw: unknown, method_raw: unknown, live_raw: unknown): (boolean?, string?)
    local record = bounds.object(record_raw)
    local owner, workspace, app = bounds.id(owner_raw), bounds.id(workspace_raw), bounds.id(app_raw)
    local binding = bounds.id(binding_raw)
    local method = type(method_raw) == "string" and (method_raw :: string):match("^[A-Za-z][A-Za-z0-9_]*$") or nil
    if not record or not owner or not workspace or not app or not binding or not method
        or live_raw ~= true then
        return nil, "contract caller is not authenticated for this call"
    end
    if record.overlay_owner ~= owner or record.workspace_id ~= workspace or record.application ~= app then
        return nil, "contract grant belongs to another caller or workspace"
    end
    local capabilities = record.capabilities
    if type(capabilities) ~= "table" then return nil, "contract grant set is malformed" end
    for _, raw_grant in ipairs(capabilities :: {unknown}) do
        local grant = bounds.object(raw_grant)
        local scope = grant and bounds.object(grant.scope) or nil
        local names = scope and methods(scope.methods) or nil
        if grant and grant.capability == "contract.call" and grant.operation == "contract.call"
            and grant.resource == binding and names then
            for _, name in ipairs(names) do
                if name == method then return true, nil end
            end
        end
    end
    return nil, "contract grant covers no such binding and method"
end

return M
