-- MIT. Host-owned stores accept registry resources, never caller-supplied file paths.
local registry = require("registry")
local hash = require("hash")
local contract = require("contract")
local bounds = require("bounds")
type Selection = {workspace_id: string?, root_ref: string?, subpath: string?}
local M = {}
-- Classic mode: the node folder is the workspace rooted at the node's own
-- workspace root resource.
M.CLASSIC_ROOT = "bee.env:workspace_root"
function M.database(kind: "client" | "workspace", value: unknown): (string?, string?)
    local selected = bounds.id(value == nil and ("bee.env:" .. kind .. "_db") or value)
    if not selected then return nil, "Invalid database resource reference" end
    local entry, lookup_error = registry.get(selected)
    if lookup_error or not entry then return nil, "Read database selection " .. selected .. ": " .. tostring(lookup_error) end
    if not entry.kind:match("^db%.sql%.") then return nil, "Database selection is not a SQL resource: " .. selected end
    return selected, nil
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
-- Whether a decoded selection names the node folder.
function M.is_classic(selection: Selection): boolean
    return selection.workspace_id == nil and selection.root_ref == M.CLASSIC_ROOT and selection.subpath == ""
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
