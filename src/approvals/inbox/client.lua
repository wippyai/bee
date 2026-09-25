-- MIT. The inbox's caller toward the approval owner is the shared
-- application caller; this module adds only what the inbox reads.
local caller = require("caller")
local M = {}
M.new = caller.new
-- The workspaces this viewer's inbox reads: the launch workspace and what
-- the host admitted beside it.
function M.workspaces(launch_workspace: string, admitted: unknown): {string}
    local list: {string} = {launch_workspace}
    local seen: {[string]: boolean} = {[launch_workspace] = true}
    if type(admitted) == "table" then
        for _, item in ipairs(admitted :: {unknown}) do
            if type(item) == "string" and item ~= "" and #item <= 200 and not item:find("%c") and not seen[item] and #list < 16 then
                seen[item] = true
                list[#list + 1] = item
            end
        end
    end
    return list
end
return M
