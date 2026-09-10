-- MIT. Linked references of the resource authority: the store and the
-- host's admitted roots, the ceiling every association stays under.
local registry = require("registry")
local M = {}
M.DATABASE_REF = "bee.resources:database_ref"
M.ROOTS_REF = "bee.resources:roots_ref"
local function reference(id: string, field: string, label: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, label .. " reference unavailable" end
    local data = entry.data
    local ref = type(data) == "table" and data[field] or nil
    if type(ref) ~= "string" or ref == "" then return nil, label .. " reference is not linked" end
    return ref, nil
end
function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "resource_ref", "resource database")
end
-- Host roots: fs.directory entries with the widest access the host allows.
function M.host_roots(): ({[string]: string}?, string?)
    local roots_entry, roots_error = reference(M.ROOTS_REF, "resource_ref", "host roots")
    if not roots_entry then return nil, roots_error end
    local entry, err = registry.get(roots_entry)
    if err or not entry then return nil, "host roots unavailable" end
    local data = entry.data
    local roots: {[string]: string} = {}
    local list = type(data) == "table" and data.roots or nil
    if type(list) ~= "table" then return roots, nil end
    for _, item in ipairs(list :: {unknown}) do
        if type(item) == "table" then
            local declared = item :: {[string]: unknown}
            if type(declared.root_ref) == "string" and (declared.access == "read" or declared.access == "write") then
                roots[declared.root_ref :: string] = declared.access :: string
            end
        end
    end
    return roots, nil
end
-- The fs.directory entry behind a root, as it is now.
function M.root(root_ref: string): ({[string]: unknown}?, string?)
    local entry, err = registry.get(root_ref)
    if err or not entry then return nil, "resource root " .. root_ref .. " is not in the registry" end
    if entry.kind ~= "fs.directory" then return nil, "resource root " .. root_ref .. " is not a directory" end
    local data = entry.data
    local directory = type(data) == "table" and data.directory or nil
    if type(directory) ~= "string" or directory == "" then return nil, "resource root " .. root_ref .. " has no directory" end
    return {kind = entry.kind, meta = entry.meta, data = data}, nil
end
return M
