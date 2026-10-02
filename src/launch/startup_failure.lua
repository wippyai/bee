-- MIT. Attribute an early retained-workspace failure to the local Hive supervisor.
local types = require("types")
local bounds = require("bounds")

local M = {}

function M.node_id(pid: string): string?
    local node = types.pid_parts(pid)
    return node ~= "" and node or nil
end

function M.stored(raw: unknown): string?
    local detail = bounds.text(raw, 4096)
    if not detail then return nil end
    detail = detail:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if detail == "" then return nil end
    return "Hive supervisor failed before retained workspace readiness: " .. detail
end

function M.decode(sender: string, raw: unknown, local_node: string): string?
    local node, host = types.pid_parts(sender)
    if not node or node ~= local_node or host ~= types.SUPERVISOR_HOST then return nil end
    local value = bounds.object(raw)
    if not value or bounds.fields(value, {"version", "error"}) or value.version ~= 1 then return nil end
    return M.stored(value.error)
end

return M
