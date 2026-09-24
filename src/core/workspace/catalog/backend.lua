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
local resources = require("resources")
local recovery = require("recovery")
local extensions = require("extensions")

local EXECUTE = "bee.workspaces.execute"
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

-- A workspace folder lies under a root the host admitted. An existing folder
-- must be a directory; a new one needs a write-admitted root, an existing
-- parent and an unused name, and is made inside the insert transaction.
local function create(request: protocol.Create): protocol.Reply
    local roots, roots_error = resources.host_roots()
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
    return transact(function(tx: sql.Transaction): (unknown, catalog.Fault?)
        return catalog.page(tx, query)
    end)
end

return {handle = handle}
