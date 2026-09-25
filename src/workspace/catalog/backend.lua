-- MIT. The private side of the node workspace catalog operations. It runs
-- only under the operations' execution scope, which holds the node workspace
-- store, the host's admitted roots and their volumes; the facade has already
-- authorized the caller for the decoded request.
local sql = require("sql")
local fs = require("fs")
local security = require("security")
local process = require("process")
local store = require("store")
local catalog = require("catalog")
local protocol = require("protocol")
local registry = require("registry")
local recovery = require("recovery")
local extensions = require("extensions")

local EXECUTE = "bee.workspace.manager.execute"
local BACKEND = "bee.workspace.catalog:backend"
local HOST_PREFIX = "bee.workspace.host/"

type Work = (sql.Transaction) -> (unknown, catalog.Fault?)

-- One transaction per operation. A fault rolls it back; a value commits it.
local function transact(work: Work): protocol.Reply
    local db, open_error = store.database(nil)
    if not db then return protocol.fail("STORAGE", open_error or "open the node workspace database") end
    local tx, begin_error = db:begin()
    if not tx then
        db:release()
        return protocol.fail("STORAGE", "begin catalog transaction: " .. tostring(begin_error))
    end
    local value, failure = work(tx)
    if failure then
        tx:rollback()
        db:release()
        return protocol.fail(failure.code, failure.message)
    end
    local _, commit_error = tx:commit()
    if commit_error then
        tx:rollback()
        db:release()
        return protocol.fail("STORAGE", "commit catalog transaction: " .. tostring(commit_error))
    end
    db:release()
    return protocol.succeed(value)
end

local function fault(code: string, message: string): catalog.Fault
    return {code = code, message = message}
end

local function live(workspace_id: string): boolean
    local host = process.registry.lookup(HOST_PREFIX .. workspace_id)
    return host ~= nil
end

local function folder(path: string): string
    if path == "" then return "." end
    return path
end

local function host_roots(): ({[string]: string}?, string?)
    local entry, err = registry.get("bee:resource_roots")
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

-- A workspace folder lies under a root the host admitted. An existing folder
-- must be a directory; a new one needs a write-admitted root, an existing
-- parent and an unused name, and is made inside the insert transaction.
local function create(request: protocol.Create): protocol.Reply
    local roots, roots_error = host_roots()
    if not roots then return protocol.fail("UNAVAILABLE", roots_error or "host roots are unavailable") end
    local ceiling = roots[request.root_ref]
    if not ceiling then return protocol.fail("FORBIDDEN", "root " .. request.root_ref .. " is not admitted on this host") end
    if request.create_directory and ceiling ~= "write" then
        return protocol.fail("FORBIDDEN", "root " .. request.root_ref .. " is admitted read only")
    end
    local volume, volume_error = fs.get(request.root_ref)
    if not volume then return protocol.fail("UNAVAILABLE", "root " .. request.root_ref .. " is unavailable: " .. tostring(volume_error)) end
    if request.create_directory then
        local parent = request.subpath:match("^(.*)/[^/]+$") or ""
        local parent_exists = volume:isdir(folder(parent))
        if not parent_exists then return protocol.fail("NOT_FOUND", "parent folder " .. folder(parent) .. " does not exist") end
        local taken = volume:exists(request.subpath)
        if taken then return protocol.fail("CONFLICT", "folder " .. request.subpath .. " already exists") end
    else
        local present = volume:isdir(folder(request.subpath))
        if not present then return protocol.fail("NOT_FOUND", "folder " .. folder(request.subpath) .. " does not exist") end
    end
    return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        local created, failure = catalog.insert(tx, {label = request.label, root_ref = request.root_ref, subpath = request.subpath})
        if not created then return nil, failure or fault("STORAGE", "create workspace") end
        if request.create_directory then
            local made, mkdir_error = volume:mkdir(request.subpath)
            if not made then return nil, fault("STORAGE", "create folder " .. request.subpath .. ": " .. tostring(mkdir_error)) end
        end
        return created, nil
    end)
end

-- The roots the host admits, in name order, with the access it admits.
local function roots(): protocol.Reply
    local admitted, roots_error = host_roots()
    if not admitted then return protocol.fail("UNAVAILABLE", roots_error or "host roots are unavailable") end
    local names: {string} = {}
    for root_ref in pairs(admitted) do names[#names + 1] = root_ref end
    table.sort(names)
    local listed: {{root_ref: string, access: string}} = {}
    for index, root_ref in ipairs(names) do listed[index] = {root_ref = root_ref, access = admitted[root_ref]} end
    return protocol.succeed({roots = listed})
end

-- One page of the folders inside a folder of an admitted root, in name order,
-- each with the workspace that holds it. Hidden folders (a leading ".") are
-- left out. The directory is read once and only the page's names are kept.
local function folders(request: protocol.Folders): protocol.Reply
    local admitted, roots_error = host_roots()
    if not admitted then return protocol.fail("UNAVAILABLE", roots_error or "host roots are unavailable") end
    local access = admitted[request.root_ref]
    if not access then return protocol.fail("FORBIDDEN", "root " .. request.root_ref .. " is not admitted on this host") end
    local volume, volume_error = fs.get(request.root_ref)
    if not volume then return protocol.fail("UNAVAILABLE", "root " .. request.root_ref .. " is unavailable: " .. tostring(volume_error)) end
    local directory = folder(request.path)
    if not volume:isdir(directory) then return protocol.fail("NOT_FOUND", "folder " .. directory .. " does not exist") end
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
    local function child(name: string): string
        if request.path == "" then return name end
        return request.path .. "/" .. name
    end
    local subpaths: {string} = {request.path}
    for _, name in ipairs(names) do subpaths[#subpaths + 1] = child(name) end
    return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        local held, failure = catalog.holders(tx, request.root_ref, subpaths)
        if not held then return nil, failure end
        local listed: {{name: string, workspace_id: string?}} = {}
        for index, name in ipairs(names) do listed[index] = {name = name, workspace_id = held[child(name)]} end
        return {root_ref = request.root_ref, path = request.path, access = access, workspace_id = held[request.path],
            folders = listed, next_after = next_after}, nil
    end)
end

local function read(workspace_id: string): protocol.Reply
    return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        local found, failure = catalog.get(tx, workspace_id)
        if failure then return nil, failure end
        if not found then return nil, fault("NOT_FOUND", "workspace is not in the node catalog") end
        return {workspace = found, live = live(workspace_id)}, nil
    end)
end

-- What a workspace holds: its row, whether a host serves it, the
-- applications its checkpoint keeps open and what every extension attached
-- to it describes. The store transaction ends before any extension runs.
local function inspect(workspace_id: string): protocol.Reply
    local found: catalog.Summary? = nil
    local saved: string? = nil
    local read = transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        local row, failure = catalog.get(tx, workspace_id)
        if failure then return nil, failure end
        if not row then return nil, fault("NOT_FOUND", "workspace is not in the node catalog") end
        local state, state_failure = catalog.state(tx, workspace_id)
        if state_failure then return nil, state_failure end
        found, saved = row, state
        return true, nil
    end)
    if not read.ok or not found then return read end
    local applications: {{[string]: unknown}} = {}
    if saved then
        local snapshot = recovery.decode(saved)
        if not snapshot then return protocol.fail("STORAGE", "workspace state is invalid") end
        for index, record in ipairs(snapshot.applications) do
            applications[index] = {view_id = record.id, instance_id = record.instance_id, definition_id = record.definition_id,
                restart_policy = record.restart_policy}
        end
    end
    local bindings, bindings_error = extensions.bindings()
    if not bindings then return protocol.fail("UNAVAILABLE", bindings_error or "workspace extensions are unavailable") end
    local described: {extensions.Described} = {}
    for index, binding in ipairs(bindings) do described[index] = extensions.describe(binding, workspace_id) end
    return protocol.succeed({workspace = found, live = live(workspace_id), applications = applications, extensions = described})
end

-- Search inside one workspace: every extension answers for itself.
local function search_within(workspace_id: string, text: string, limit: integer): protocol.Reply
    local present = transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        local row, failure = catalog.get(tx, workspace_id)
        if failure then return nil, failure end
        if not row then return nil, fault("NOT_FOUND", "workspace is not in the node catalog") end
        return true, nil
    end)
    if not present.ok then return present end
    local bindings, bindings_error = extensions.bindings()
    if not bindings then return protocol.fail("UNAVAILABLE", bindings_error or "workspace extensions are unavailable") end
    local results: {extensions.Found} = {}
    for index, binding in ipairs(bindings) do results[index] = extensions.search(binding, workspace_id, text, limit) end
    return protocol.succeed({workspace_id = workspace_id, results = results})
end

-- An archived workspace is never served, so a running host is stopped
-- before its row is archived.
local function archive(workspace_id: string): protocol.Reply
    if live(workspace_id) then return protocol.fail("BUSY", "workspace host is running; stop it before archiving") end
    return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        return catalog.transition(tx, workspace_id, "active", "archived")
    end)
end

local function handle(value: unknown): protocol.Reply
    if not security.can(EXECUTE, BACKEND) then return protocol.fail("DENIED", "the catalog backend is private") end
    if type(value) ~= "table" then return protocol.fail("INVALID", "backend request must be an object") end
    local request, decode_error = protocol.decode(value.operation, value.request)
    if not request then return protocol.fail("INVALID", decode_error or "invalid catalog request") end
    local operation = request.operation
    if operation == "create" then
        local definition = request.create
        if not definition then return protocol.fail("INVALID", "create request is missing") end
        return create(definition)
    elseif operation == "roots" then
        return roots()
    elseif operation == "folders" then
        local definition = request.folders
        if not definition then return protocol.fail("INVALID", "folders request is missing") end
        return folders(definition)
    elseif operation == "read" then
        return read(request.workspace_id or "")
    elseif operation == "inspect" then
        return inspect(request.workspace_id or "")
    elseif operation == "search_within" then
        return search_within(request.workspace_id or "", request.text or "", request.limit or 10)
    elseif operation == "archive" then
        return archive(request.workspace_id or "")
    elseif operation == "restore" then
        local id = request.workspace_id or ""
        return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
            return catalog.transition(tx, id, "archived", "active")
        end)
    elseif operation == "rename" then
        local id, label = request.workspace_id or "", request.label or ""
        return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
            return catalog.rename(tx, id, label)
        end)
    end
    local query = request.query
    if not query then return protocol.fail("INVALID", "listing request is missing") end
    if query.order == "roots" then
        -- A search across roots walks every root the host admits, in name order.
        local admitted, roots_error = host_roots()
        if not admitted then return protocol.fail("UNAVAILABLE", roots_error or "host roots are unavailable") end
        local roots: {string} = {}
        for root_ref in pairs(admitted) do roots[#roots + 1] = root_ref end
        table.sort(roots)
        query.roots = roots
    end
    return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        return catalog.page(tx, query)
    end)
end

return {handle = handle}
