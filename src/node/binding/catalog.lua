-- MIT. The node workspace catalog: requests, authority and replies, and the
-- private backend that answers them from the node's workspaces and the roots
-- the node admits. A root is an fs.directory a bee.node.roots registry entry
-- admits for read or write; a workspace is listed under the root its folder
-- lies in, by the subpath inside it.
local bounds = require("bounds")
local registry = require("registry")
local fs = require("fs")
local workspaces = require("workspaces")

type Object = {[string]: unknown}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, value: unknown?, error: Fault?}
type Folders = {root_ref: string, path: string, after: string?, limit: integer}
type Request = {operation: "read", workspace_id: string}
    | {operation: "roots"}
    | {operation: "folders", folders: Folders}
type Root = {root_ref: string, access: string, directory: string}
type Row = {workspace_id: string, label: string, root_ref: string, subpath: string}

local M = {}

M.READ = "bee.node.workspace.read"
M.BROWSE = "bee.node.workspace.browse"
M.CATALOG = "catalog"
M.ROOTS_TYPE = "bee.node.roots"
M.DEFAULT_PAGE = 50
M.MAX_PAGE = 100

function M.fail(code: string, message: string): Object
    return {ok = false, error = {code = code, message = message}}
end

function M.succeed(value: unknown): Object
    return {ok = true, value = value}
end

local function workspace_id(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end

function M.decode(operation: string, raw: unknown): (Request?, string?)
    local object = bounds.object(raw == nil and {} or raw)
    if not object then return nil, "request must be an object" end
    if operation == "read" then
        local extra = bounds.fields(object, {"workspace_id"})
        if extra then return nil, extra end
        local id = workspace_id(object.workspace_id)
        if not id then return nil, "workspace_id must be 32 lowercase hex digits" end
        return {operation = "read", workspace_id = id}, nil
    elseif operation == "roots" then
        local extra = bounds.fields(object, {})
        if extra then return nil, extra end
        return {operation = "roots"}, nil
    elseif operation == "folders" then
        local extra = bounds.fields(object, {"root_ref", "path", "after", "limit"})
        if extra then return nil, extra end
        local root_ref = bounds.id(object.root_ref)
        if not root_ref then return nil, "root_ref must be a registry id" end
        local path, path_error = bounds.subpath(object.path == nil and "" or object.path)
        if not path then return nil, path_error or "invalid path" end
        local after: string? = nil
        if object.after ~= nil then
            local segment = bounds.subpath(object.after)
            if not segment or segment == "" or segment:find("/", 1, true) then return nil, "after must be one folder name" end
            after = segment
        end
        local limit = M.DEFAULT_PAGE
        if object.limit ~= nil then
            local number = bounds.integer(object.limit)
            if not number or number < 1 or number > M.MAX_PAGE then return nil, "limit must be 1 to " .. tostring(M.MAX_PAGE) end
            limit = number
        end
        return {operation = "folders", folders = {root_ref = root_ref, path = path, after = after, limit = limit}}, nil
    end
    return nil, "unknown catalog operation " .. operation
end

-- authority is the action and resource a request needs the caller to hold.
function M.authority(request: Request): (string, string)
    if request.operation == "read" then return M.READ, request.workspace_id end
    if request.operation == "folders" then return M.BROWSE, request.folders.root_ref end
    return M.READ, M.CATALOG
end

local function directory_of(root_ref: string): string?
    local entry = registry.get(root_ref)
    local data = entry and bounds.object(entry.data) or nil
    if not entry or entry.kind ~= "fs.directory" or not data or type(data.directory) ~= "string" then return nil end
    return workspaces.normalize(data.directory)
end

-- admitted lists the roots every bee.node.roots entry admits, by root_ref.
local function admitted(): ({[string]: Root}?, string?)
    local entries, find_error = registry.find({[".kind"] = "registry.entry", ["meta.type"] = M.ROOTS_TYPE})
    if not entries then return nil, "node roots: " .. tostring(find_error) end
    local found: {[string]: Root} = {}
    for _, entry in ipairs(entries) do
        local data = bounds.object(entry.data)
        local list = data and data.roots
        if type(list) == "table" then
            for _, raw in ipairs(list :: {unknown}) do
                local item = bounds.object(raw)
                local root_ref = item and bounds.id(item.root_ref) or nil
                local access = item and item.access
                local directory = root_ref and directory_of(root_ref) or nil
                if root_ref and directory and (access == "read" or access == "write") and not found[root_ref] then
                    found[root_ref] = {root_ref = root_ref, access = tostring(access), directory = directory}
                end
            end
        end
    end
    return found, nil
end

-- inside is the subpath of path under directory, or nil outside it.
local function inside(directory: string, path: string): string?
    if path == directory then return "" end
    local prefix = directory:sub(-1) == "/" and directory or directory .. "/"
    if path:sub(1, #prefix) ~= prefix then return nil end
    return path:sub(#prefix + 1)
end

-- locate places a folder under the admitted root holding it most closely.
local function locate(roots: {[string]: Root}, path: string): (string?, string?)
    local chosen: Root? = nil
    local subpath: string? = nil
    for _, root in pairs(roots) do
        local within = inside(root.directory, path)
        if within and (not chosen or #root.directory > #chosen.directory
            or (#root.directory == #chosen.directory and root.root_ref < chosen.root_ref)) then
            chosen, subpath = root, within
        end
    end
    if not chosen then return nil, nil end
    return chosen.root_ref, subpath
end

local function read(id: string): Object
    local roots, roots_error = admitted()
    if not roots then return M.fail("UNAVAILABLE", roots_error or "node roots are unavailable") end
    local workspace, workspace_error = workspaces.workspace(id)
    if not workspace then return M.fail("NOT_FOUND", workspace_error or "workspace is not on this node") end
    local root_ref, subpath = locate(roots, workspace.path)
    if not root_ref or not subpath then
        return M.fail("UNAVAILABLE", "workspace folder " .. workspace.path .. " lies under no admitted root")
    end
    local row: Row = {workspace_id = workspace.id, label = workspace.label, root_ref = root_ref, subpath = subpath}
    return M.succeed({workspace = row})
end

local function list_roots(): Object
    local roots, roots_error = admitted()
    if not roots then return M.fail("UNAVAILABLE", roots_error or "node roots are unavailable") end
    local names: {string} = {}
    for root_ref in pairs(roots) do names[#names + 1] = root_ref end
    table.sort(names)
    local listed: {Object} = {}
    for index, root_ref in ipairs(names) do listed[index] = {root_ref = root_ref, access = roots[root_ref].access} end
    return M.succeed({roots = listed})
end

-- One page of the folders inside a folder of an admitted root, in name order,
-- each with the workspace that holds it. Hidden folders (a leading ".") are
-- left out.
local function folders(request: Folders): Object
    local roots, roots_error = admitted()
    if not roots then return M.fail("UNAVAILABLE", roots_error or "node roots are unavailable") end
    local root = roots[request.root_ref]
    if not root then return M.fail("FORBIDDEN", "root " .. request.root_ref .. " is not admitted on this node") end
    local volume, volume_error = fs.get(request.root_ref)
    if not volume then return M.fail("UNAVAILABLE", "root " .. request.root_ref .. " is unavailable: " .. tostring(volume_error)) end
    local directory = request.path == "" and "." or request.path
    if not volume:isdir(directory) then return M.fail("NOT_FOUND", "folder " .. directory .. " does not exist") end
    local fetch = request.limit + 1
    local names: {string} = {}
    for entry in volume:readdir(directory) do
        local name = tostring(entry.name)
        if entry.type == "directory" and name:sub(1, 1) ~= "." and (not request.after or name > request.after) then
            local position = #names + 1
            while position > 1 and names[position - 1] > name do position = position - 1 end
            if position <= fetch then
                table.insert(names, position, name)
                if #names > fetch then table.remove(names) end
            end
        end
    end
    local next_after: string? = nil
    if #names > request.limit then
        table.remove(names)
        next_after = names[#names]
    end
    local listed_workspaces, list_error = workspaces.list()
    if not listed_workspaces then return M.fail("STORAGE", list_error or "node workspaces are unavailable") end
    local held: {[string]: string} = {}
    for _, workspace in ipairs(listed_workspaces) do
        local root_ref, subpath = locate(roots, workspace.path)
        if root_ref == request.root_ref and subpath then held[subpath] = workspace.id end
    end
    local function child(name: string): string
        if request.path == "" then return name end
        return request.path .. "/" .. name
    end
    local listed: {Object} = {}
    for index, name in ipairs(names) do listed[index] = {name = name, workspace_id = held[child(name)]} end
    return M.succeed({root_ref = request.root_ref, path = request.path, access = root.access,
        workspace_id = held[request.path], folders = listed, next_after = next_after})
end

-- handle is the backend the facade calls after authorizing the caller; it
-- decodes the request again, since it trusts no caller's shape.
function M.handle(raw: unknown): Object
    local call = bounds.object(raw)
    if not call or type(call.operation) ~= "string" then return M.fail("INVALID", "invalid catalog call") end
    local request, decode_error = M.decode(call.operation, call.request)
    if not request then return M.fail("INVALID", decode_error or "invalid catalog request") end
    if request.operation == "read" then return read(request.workspace_id) end
    if request.operation == "folders" then return folders(request.folders) end
    return list_roots()
end

return M
