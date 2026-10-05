-- MIT. The node's workspaces, its desktops and the app instances each desktop
-- runs. A workspace is a folder on this machine; the folder the node runs in
-- is always one. Desktops are one set per node; each works in one workspace,
-- which the apps opened on it start in. Instances are kept so the node
-- reopens its desktops' apps when it starts.
local sql = require("sql")
local uuid = require("uuid")
local time = require("time")
local json = require("json")

type Desktop = {id: string, workspace_id: string, title: string}
type Workspace = {id: string, path: string, label: string}
-- workspace_id is the workspace an instance was opened in.
type Instance = {id: string, desktop_id: string, workspace_id: string, app: string, args: {[string]: unknown}}

local M = {}
M.DB = "bee:db"

local function open(): (sql.DB?, string?)
    local db, err = sql.get(M.DB)
    if not db then return nil, "node database: " .. tostring(err) end
    return db, nil
end

local function now(): string
    return time.now():format_rfc3339()
end

-- identity mints a workspace's canonical identity: a UUIDv7 as 32 lowercase
-- hex digits, the form app principals, sessions and governance carry.
local function identity(): string
    local value = tostring(uuid.v7()):gsub("%-", "")
    return value
end

-- label_of is the last element of path.
function M.label_of(path: string): string
    return path:match("([^/\\]+)[/\\]*$") or path
end

-- normalize collapses repeated separators and "." and ".." segments and drops
-- a trailing separator, so one folder has one workspace path.
function M.normalize(path: string): string
    local separator = path:find("\\", 1, true) and not path:find("/", 1, true) and "\\" or "/"
    local prefix = ""
    local rest = path
    if path:match("^%a:[/\\]") then prefix, rest = path:sub(1, 2), path:sub(3)
    elseif path:sub(1, 2) == "\\\\" then prefix, rest = "\\\\", path:sub(3) end
    local parts: {string} = {}
    for part in rest:gmatch("[^/\\]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    if prefix == "\\\\" then return prefix .. table.concat(parts, separator) end
    return prefix .. separator .. table.concat(parts, separator)
end

-- absolute reports whether path is absolute on this or a Windows machine.
function M.absolute(path: string): boolean
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
end

-- list returns the workspaces, oldest first.
function M.list(): ({Workspace}?, string?)
    local db, err = open()
    if not db then return nil, err end
    local rows, query_err = db:query("SELECT id, path, label FROM bee_node_workspaces ORDER BY created_at, id")
    db:release()
    if not rows then return nil, tostring(query_err) end
    local workspaces: {Workspace} = {}
    for _, row in ipairs(rows) do
        workspaces[#workspaces + 1] = {id = tostring(row.id), path = tostring(row.path), label = tostring(row.label)}
    end
    return workspaces, nil
end

-- desktops returns the node's desktops, oldest first.
function M.desktops(): ({Desktop}?, string?)
    local db, err = open()
    if not db then return nil, err end
    local rows, query_err = db:query("SELECT id, workspace_id, title FROM bee_node_desktops ORDER BY created_at, id")
    db:release()
    if not rows then return nil, tostring(query_err) end
    local found: {Desktop} = {}
    for _, row in ipairs(rows) do
        found[#found + 1] = {id = tostring(row.id), workspace_id = tostring(row.workspace_id), title = tostring(row.title)}
    end
    return found, nil
end

-- ensure returns the workspace at the normalized path, adding it labelled
-- label (or by its folder name) when the node has none there.
function M.ensure(given: string, label: string?): (Workspace?, string?)
    local path = M.normalize(given)
    local db, err = open()
    if not db then return nil, err end
    local _, insert_err = db:execute(
        "INSERT INTO bee_node_workspaces (id, path, label, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(path) DO NOTHING",
        {identity(), path, label or M.label_of(path), now()})
    if insert_err then db:release(); return nil, tostring(insert_err) end
    local rows, query_err = db:query("SELECT id, path, label FROM bee_node_workspaces WHERE path = ?", {path})
    db:release()
    if not rows or not rows[1] then return nil, tostring(query_err or "workspace not stored") end
    return {id = tostring(rows[1].id), path = tostring(rows[1].path), label = tostring(rows[1].label)}, nil
end

-- workspace returns the workspace id.
function M.workspace(id: string): (Workspace?, string?)
    local db, err = open()
    if not db then return nil, err end
    local rows, query_err = db:query("SELECT id, path, label FROM bee_node_workspaces WHERE id = ?", {id})
    db:release()
    if not rows then return nil, tostring(query_err) end
    if not rows[1] then return nil, "no workspace " .. id end
    return {id = tostring(rows[1].id), path = tostring(rows[1].path), label = tostring(rows[1].label)}, nil
end

-- remove_workspace deletes workspace id.
function M.remove_workspace(id: string): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local _, exec_err = db:execute("DELETE FROM bee_node_workspaces WHERE id = ?", {id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

-- desktop returns the desktop id.
function M.desktop(id: string): (Desktop?, string?)
    local db, err = open()
    if not db then return nil, err end
    local rows, query_err = db:query("SELECT id, workspace_id, title FROM bee_node_desktops WHERE id = ?", {id})
    db:release()
    if not rows then return nil, tostring(query_err) end
    if not rows[1] then return nil, "no desktop " .. id end
    return {id = tostring(rows[1].id), workspace_id = tostring(rows[1].workspace_id), title = tostring(rows[1].title)}, nil
end

-- create_desktop adds a desktop working in workspace_id, titled title or
-- with the first desktop number no desktop uses.
function M.create_desktop(workspace_id: string, title: string?): (Desktop?, string?)
    local db, err = open()
    if not db then return nil, err end
    local titles, titles_err = db:query("SELECT title FROM bee_node_desktops")
    if not titles then db:release(); return nil, tostring(titles_err) end
    local name = title
    if not name or name == "" then
        local taken: {[string]: boolean} = {}
        for _, row in ipairs(titles) do taken[tostring(row.title)] = true end
        local number = 1
        while taken["Desktop " .. tostring(number)] do number = number + 1 end
        name = "Desktop " .. tostring(number)
    end
    local id = tostring(uuid.v7())
    local _, insert_err = db:execute("INSERT INTO bee_node_desktops (id, workspace_id, title, created_at) VALUES (?, ?, ?, ?)",
        {id, workspace_id, name, now()})
    db:release()
    if insert_err then return nil, tostring(insert_err) end
    return {id = id, workspace_id = workspace_id, title = name}, nil
end

-- use_workspace makes desktop id work in workspace_id.
function M.use_workspace(id: string, workspace_id: string): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local _, exec_err = db:execute("UPDATE bee_node_desktops SET workspace_id = ? WHERE id = ?", {workspace_id, id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

function M.rename_desktop(id: string, title: string): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local _, exec_err = db:execute("UPDATE bee_node_desktops SET title = ? WHERE id = ?", {title, id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

-- remove_desktop deletes desktop id and the instances it holds.
function M.remove_desktop(id: string): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local _, instances_err = db:execute("DELETE FROM bee_node_instances WHERE desktop_id = ?", {id})
    if instances_err then db:release(); return false, tostring(instances_err) end
    local _, exec_err = db:execute("DELETE FROM bee_node_desktops WHERE id = ?", {id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

-- keep records an app instance on its desktop.
function M.keep(instance: Instance): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local encoded, encode_err = json.encode(instance.args)
    if not encoded then db:release(); return false, tostring(encode_err) end
    local _, exec_err = db:execute("INSERT INTO bee_node_instances (id, desktop_id, workspace_id, app, args, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        {instance.id, instance.desktop_id, instance.workspace_id, instance.app, encoded, now()})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

-- remember replaces the arguments kept with instance id, which carry the
-- checkpoint the node gives the app back when it reopens it.
function M.remember(id: string, args: {[string]: unknown}): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local encoded, encode_err = json.encode(args)
    if not encoded then db:release(); return false, tostring(encode_err) end
    local result, exec_err = db:execute("UPDATE bee_node_instances SET args = ? WHERE id = ?", {encoded, id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    if not result or result.rows_affected ~= 1 then return false, "instance " .. id .. " is not kept" end
    return true, nil
end

-- move_instance puts instance id on desktop_id.
function M.move_instance(id: string, desktop_id: string): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local _, exec_err = db:execute("UPDATE bee_node_instances SET desktop_id = ? WHERE id = ?", {desktop_id, id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

function M.forget(id: string): (boolean, string?)
    local db, err = open()
    if not db then return false, err end
    local _, exec_err = db:execute("DELETE FROM bee_node_instances WHERE id = ?", {id})
    db:release()
    if exec_err then return false, tostring(exec_err) end
    return true, nil
end

-- instances returns the kept app instances, oldest first.
function M.instances(): ({Instance}?, string?)
    local db, err = open()
    if not db then return nil, err end
    local rows, query_err = db:query("SELECT id, desktop_id, workspace_id, app, args FROM bee_node_instances ORDER BY created_at, id")
    db:release()
    if not rows then return nil, tostring(query_err) end
    local found: {Instance} = {}
    for _, row in ipairs(rows) do
        local decoded: unknown = json.decode(tostring(row.args))
        local args: {[string]: unknown} = {}
        if type(decoded) == "table" then args = decoded end
        found[#found + 1] = {id = tostring(row.id), desktop_id = tostring(row.desktop_id), workspace_id = tostring(row.workspace_id),
            app = tostring(row.app), args = args}
    end
    return found, nil
end

return M
