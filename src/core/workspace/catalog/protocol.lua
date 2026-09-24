-- MIT. Typed requests and replies of the node workspace catalog operations,
-- and the action and resource each request is authorized under.
local bounds = require("bounds")
local contract = require("contract")
local catalog = require("catalog")

type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Create = {label: string, root_ref: string, subpath: string, create_directory: boolean}
-- folders: one page of the folders inside path under root_ref, after a folder name.
type Folders = {root_ref: string, path: string, after: string?, limit: integer}
type Request = {operation: string, create: Create?, workspace_id: string?, label: string?, query: catalog.Query?, text: string?,
    limit: integer?, folders: Folders?}

local M = {}
M.READ = "bee.workspaces.read"
M.MANAGE = "bee.workspaces.manage"
M.CATALOG = "catalog"
M.DEFAULT_PAGE = 50
M.OPERATIONS = {"create", "read", "list", "search", "rename", "archive", "restore", "inspect", "search_within", "roots", "folders"}
M.MAX_WITHIN = 50

function M.fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end

function M.succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end

-- A label names a workspace for people: one bounded line, never empty.
local function label(value: unknown): string?
    return bounds.line(value, catalog.MAX_LABEL_BYTES)
end

local function listing(object: {[string]: unknown}, order: string, prefix: string, root_ref: string?): (catalog.Query?, string?)
    local state = "active"
    if object.state ~= nil then
        local selected = bounds.member(object.state, catalog.STATES)
        if not selected then return nil, "state must be active or archived" end
        state = selected
    end
    local limit = M.DEFAULT_PAGE
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > catalog.MAX_PAGE then
            return nil, "limit must be between 1 and " .. tostring(catalog.MAX_PAGE)
        end
        limit = number
    end
    local after: catalog.Cursor? = nil
    if object.after ~= nil then
        after = catalog.decode_cursor(object.after)
        if not after then return nil, "after is not a catalog cursor" end
    end
    return {state = state, order = order, prefix = prefix, root_ref = root_ref, after = after, limit = limit}, nil
end

local function workspace(object: {[string]: unknown}): (string?, string?)
    local id = contract.workspace_id(object.workspace_id)
    if not id then return nil, "workspace_id must be a workspace identity" end
    return id, nil
end

function M.decode(operation: unknown, value: unknown): (Request?, string?)
    local selected = bounds.member(operation, M.OPERATIONS)
    if not selected then return nil, "unknown catalog operation" end
    local name: string = selected
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    if selected == "create" then
        local extra = bounds.fields(object, {"label", "root_ref", "subpath", "create_directory"})
        if extra then return nil, extra end
        local title = label(object.label)
        if not title then return nil, "label must be one nonempty line of at most " .. tostring(catalog.MAX_LABEL_BYTES) .. " bytes" end
        local root_ref = bounds.id(object.root_ref)
        if not root_ref then return nil, "root_ref must be an identifier" end
        local subpath, subpath_error = bounds.subpath(object.subpath == nil and "" or object.subpath)
        if not subpath then return nil, subpath_error or "invalid subpath" end
        local create_directory = object.create_directory == true
        if object.create_directory ~= nil and type(object.create_directory) ~= "boolean" then
            return nil, "create_directory must be a boolean"
        end
        if create_directory and subpath == "" then return nil, "create_directory needs a subpath to create" end
        return {operation = name, create = {label = title, root_ref = root_ref, subpath = subpath,
            create_directory = create_directory}}, nil
    elseif selected == "roots" then
        local extra = bounds.fields(object, {})
        if extra then return nil, extra end
        return {operation = name}, nil
    elseif selected == "folders" then
        local extra = bounds.fields(object, {"root_ref", "path", "after", "limit"})
        if extra then return nil, extra end
        local root_ref = bounds.id(object.root_ref)
        if not root_ref then return nil, "root_ref must be an identifier" end
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
            if not number or number < 1 or number > catalog.MAX_PAGE then
                return nil, "limit must be between 1 and " .. tostring(catalog.MAX_PAGE)
            end
            limit = number
        end
        return {operation = name, folders = {root_ref = root_ref, path = path, after = after, limit = limit}}, nil
    elseif selected == "search_within" then
        local extra = bounds.fields(object, {"workspace_id", "text", "limit"})
        if extra then return nil, extra end
        local id, id_error = workspace(object)
        if not id then return nil, id_error end
        local text = bounds.line(object.text, catalog.MAX_LABEL_BYTES)
        if not text then return nil, "text must be one nonempty line of at most " .. tostring(catalog.MAX_LABEL_BYTES) .. " bytes" end
        local limit = 10
        if object.limit ~= nil then
            local number = bounds.integer(object.limit)
            if not number or number < 1 or number > M.MAX_WITHIN then return nil, "limit must be between 1 and " .. tostring(M.MAX_WITHIN) end
            limit = number
        end
        return {operation = name, workspace_id = id, text = text, limit = limit}, nil
    elseif selected == "read" or selected == "archive" or selected == "restore" or selected == "inspect" then
        local extra = bounds.fields(object, {"workspace_id"})
        if extra then return nil, extra end
        local id, id_error = workspace(object)
        if not id then return nil, id_error end
        return {operation = name, workspace_id = id}, nil
    elseif selected == "rename" then
        local extra = bounds.fields(object, {"workspace_id", "label"})
        if extra then return nil, extra end
        local id, id_error = workspace(object)
        if not id then return nil, id_error end
        local title = label(object.label)
        if not title then return nil, "label must be one nonempty line of at most " .. tostring(catalog.MAX_LABEL_BYTES) .. " bytes" end
        return {operation = name, workspace_id = id, label = title}, nil
    elseif selected == "list" then
        local extra = bounds.fields(object, {"state", "after", "limit"})
        if extra then return nil, extra end
        local query, query_error = listing(object, "label", "", nil)
        if not query then return nil, query_error end
        return {operation = name, query = query}, nil
    end
    local extra = bounds.fields(object, {"state", "label", "root_ref", "path", "after", "limit"})
    if extra then return nil, extra end
    -- A label prefix, a folder under one root, or, with a path and no
    -- root_ref, that folder under every admitted root.
    if object.label ~= nil and (object.root_ref ~= nil or object.path ~= nil) then return nil, "search takes a label or a path, not both" end
    if object.label == nil and object.root_ref == nil and object.path == nil then return nil, "search takes a label, a root_ref or a path" end
    if object.label ~= nil then
        local prefix = label(object.label)
        if not prefix then return nil, "label must be one nonempty line of at most " .. tostring(catalog.MAX_LABEL_BYTES) .. " bytes" end
        local query, query_error = listing(object, "label", prefix, nil)
        if not query then return nil, query_error end
        return {operation = name, query = query}, nil
    end
    local path, path_error = bounds.subpath(object.path == nil and "" or object.path)
    if not path then return nil, path_error or "invalid path" end
    if object.root_ref == nil then
        local across, across_error = listing(object, "roots", path, nil)
        if not across then return nil, across_error end
        return {operation = name, query = across}, nil
    end
    local root_ref = bounds.id(object.root_ref)
    if not root_ref then return nil, "root_ref must be an identifier" end
    local query, query_error = listing(object, "path", path, root_ref)
    if not query then return nil, query_error end
    return {operation = name, query = query}, nil
end

-- Reads of one workspace are checked against that workspace; listing, search
-- and the admitted roots against the catalog; creation and browsing a root's
-- folders for it against the root it names; every other change against the
-- workspace it changes.
function M.authority(request: Request): (string, string)
    local operation = request.operation
    if operation == "list" or operation == "search" or operation == "roots" then return M.READ, M.CATALOG end
    if operation == "folders" then
        local folders = request.folders
        return M.MANAGE, folders and folders.root_ref or ""
    end
    if operation == "read" or operation == "inspect" or operation == "search_within" then return M.READ, request.workspace_id or "" end
    if operation == "create" then
        local create = request.create
        return M.MANAGE, create and create.root_ref or ""
    end
    return M.MANAGE, request.workspace_id or ""
end

-- The reply shape every operation returns, checked where it crosses back
-- into the caller.
function M.reply(value: unknown): Reply?
    local object = bounds.object(value)
    if not object or type(object.ok) ~= "boolean" then return nil end
    if object.ok then return M.succeed(object.value) end
    local failure = bounds.object(object.error)
    if not failure then return nil end
    local code, message = bounds.line(failure.code, 64), bounds.text(failure.message, 4096)
    if not code or not message then return nil end
    return M.fail(code, message)
end

return M
