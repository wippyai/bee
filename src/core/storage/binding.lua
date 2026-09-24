-- MIT. Core stores accept registry resources, never caller-supplied file paths.
local hash = require("hash")
local contract = require("contract")
local bounds = require("bounds")
type Selection = {workspace_id: string?, root_ref: string?, subpath: string?}
local M = {}
-- Classic mode: the node folder is the workspace rooted at the node's own
-- workspace root resource.
M.CLASSIC_ROOT = "bee:workspace_root"
function M.database(kind: "client" | "workspace", value: unknown): string?
    local default = "bee:" .. kind .. "_db"
    if value == nil or value == default then return default end
    if type(value) ~= "string" or #value > 160 then return nil end
    local prefix = "bee." .. kind .. ".db:"
    if value:sub(1, #prefix) ~= prefix then return nil end
    local name = value:sub(#prefix + 1)
    if name == "" or not name:match("^[%w_%-]+$") then return nil end
    return value
end
-- A workspace selection names exactly one catalog row: by identity, or by the
-- root that classic folder mode and root-bound workspaces are opened from.
function M.selection(value: unknown): Selection?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if key ~= "workspace_id" and key ~= "root_ref" and key ~= "subpath" then return nil end
    end
    if value.workspace_id ~= nil then
        if value.root_ref ~= nil or value.subpath ~= nil then return nil end
        local id = contract.workspace_id(value.workspace_id)
        if not id then return nil end
        return {workspace_id = id}
    end
    local root, subpath = bounds.id(value.root_ref), bounds.subpath(value.subpath)
    if not root or not subpath then return nil end
    return {root_ref = root, subpath = subpath}
end
function M.classic(): Selection
    return {root_ref = M.CLASSIC_ROOT, subpath = ""}
end
-- A registry-safe key for names that must exist before the host reports the
-- workspace identity. The host name bee.workspace.host/<workspace_id> remains
-- the one-host-per-workspace fence.
function M.key(value: unknown): string?
    local selection = M.selection(value)
    if not selection then return nil end
    local canonical: string
    if selection.workspace_id then
        canonical = "id\0" .. selection.workspace_id
    else
        canonical = "root\0" .. tostring(selection.root_ref) .. "\0" .. tostring(selection.subpath)
    end
    local digest, err = hash.sha256(canonical)
    if err or not digest then return nil end
    return digest:sub(1, 32)
end
return M
