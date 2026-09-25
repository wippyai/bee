-- MIT. Pure derivation for workspace file and application database grants.
-- A grant names a verified workspace subroot or an isolated database; this
-- module derives the host-created volume, database and policy entries that
-- activation installs. It authorizes nothing on its own.
local hash = require("hash")

local M = {}
type Object = {[string]: unknown}
M.VOLUME_PREFIX = "bee.gov.grants:volume."
M.DATABASE_PREFIX = "bee.gov.grants:database."
-- Bee state and credentials live under this subtree; no approved readable
-- tree may contain it, so an ancestor subroot is refused as well.
local PRIVATE_ROOT = ".wippy"
local PRIVATE_PREFIX = ".wippy/"
-- Application databases live outside every approved readable tree.
M.DATABASE_DIR = ".wippy/app-db"

local function segments(value: string): ({string}?, string?)
    if type(value) ~= "string" or #value == 0 or #value > 160 or value:find("%c")
        or value:find("\\", 1, true) or value:find("//", 1, true) then
        return nil, "workspace subpath is malformed"
    end
    if value == "." then return nil, "workspace subpath exposes private state" end
    if value:sub(1, 1) == "/" or (#value > 1 and value:sub(-1) == "/") then
        return nil, "workspace subpath is malformed"
    end
    local result: {string} = {}
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." or not segment:match("^[A-Za-z0-9_.-]+$") then
            return nil, "workspace subpath is malformed"
        end
        result[#result + 1] = segment
    end
    if #result == 0 then return nil, "workspace subpath is malformed" end
    return result, nil
end

-- A verified workspace subroot: a narrow relative path that neither is nor
-- contains a private path, and is not an ancestor of one. The pinned runtime
-- confines traversal and symlinks below the installed volume root.
function M.verify_subpath(raw: unknown): (string?, string?)
    local parts, parts_error = segments(raw)
    if not parts then return nil, parts_error end
    local path = table.concat(parts, "/")
    if path == PRIVATE_ROOT or path:sub(1, #PRIVATE_PREFIX) == PRIVATE_PREFIX then
        return nil, "workspace subpath is private"
    end
    return path, nil
end

local function name(raw: unknown): (string?, string?)
    if type(raw) ~= "string" or not raw:match("^[A-Za-z][A-Za-z0-9_]*$") or #raw > 64 then
        return nil, "application database name is invalid"
    end
    return raw, nil
end

local function hex(value: string): (string?, string?)
    local digest, digest_error = hash.sha256(value)
    if not digest then return nil, tostring(digest_error or "measure grant identity") end
    return digest, nil
end

function M.volume_id(owner_raw: unknown, subpath_raw: unknown): (string?, string?)
    if type(owner_raw) ~= "string" or #owner_raw == 0 or #owner_raw > 160 then
        return nil, "file grant owner is invalid"
    end
    local subpath, subpath_error = M.verify_subpath(subpath_raw)
    if not subpath then return nil, subpath_error end
    local suffix, suffix_error = hex(owner_raw .. "\n" .. subpath)
    if not suffix then return nil, suffix_error end
    return M.VOLUME_PREFIX .. suffix, nil
end

-- The host-created directory at the verified subroot. It resolves against the
-- same project root as the workspace root, carries no auto-init, and refuses
-- every mutation for read grants at the filesystem boundary.
function M.volume(owner_raw: unknown, subpath_raw: unknown, writable_raw: unknown): (unknown?, string?)
    local id, id_error = M.volume_id(owner_raw, subpath_raw)
    local subpath = M.verify_subpath(subpath_raw)
    if not id or not subpath then return nil, id_error or subpath end
    if writable_raw ~= nil and type(writable_raw) ~= "boolean" then
        return nil, "file grant mode is invalid"
    end
    local entry: {[string]: unknown} = {id = id, kind = "fs.directory",
        directory = subpath, base = "project", auto_init = writable_raw == true,
        readonly = writable_raw ~= true}
    if writable_raw == true then entry.mode = "0700" else entry.mode = "0500" end
    return entry, nil
end

function M.database_id(owner_raw: unknown, name_raw: unknown): (string?, string?)
    if type(owner_raw) ~= "string" or #owner_raw == 0 or #owner_raw > 160 then
        return nil, "database grant owner is invalid"
    end
    local valid, valid_error = name(name_raw)
    if not valid then return nil, valid_error end
    local suffix, suffix_error = hex(owner_raw .. "\n" .. valid)
    if not suffix then return nil, suffix_error end
    return M.DATABASE_PREFIX .. suffix, nil
end

-- The host-provisioned dedicated database. Its file sits under Bee state,
-- outside every approved readable tree, and the runtime creates it on first
-- open before any migration or query runs.
function M.database(owner_raw: unknown, name_raw: unknown): (unknown?, string?)
    local id, id_error = M.database_id(owner_raw, name_raw)
    local valid, valid_error = name(name_raw)
    if not id or not valid then return nil, id_error or valid_error end
    local suffix, suffix_error = hex(owner_raw .. "\n" .. valid)
    if not suffix then return nil, suffix_error end
    return {id = id, kind = "db.sql.sqlite", file = M.DATABASE_DIR .. "/" .. suffix .. ".db"}, nil
end

local function policy(id: string, actions: {string}, resources: {string}, comment: string): Object?
    return {id = id, kind = "security.policy", meta = {comment = comment},
        data = {policy = {actions = actions, resources = resources, effect = "allow"}}}
end

-- Acquisition is the policy boundary; the installed volume's readonly flag
-- enforces the read-only mode below it.
function M.file_policy(owner_raw: unknown, subpath_raw: unknown, writable_raw: unknown,
    policy_id_raw: unknown): (Object?, string?)
    local volume, volume_error = M.volume(owner_raw, subpath_raw, writable_raw)
    if not volume or type(policy_id_raw) ~= "string" then
        return nil, volume_error or "file grant policy identity is invalid"
    end
    local id: string = policy_id_raw :: string
    if #id == 0 or #id > 160 then return nil, "file grant policy identity is invalid" end
    return policy(id, {"fs.get"}, {(volume :: {[string]: unknown}).id :: string},
        "Host-generated workspace file grant"), nil
end

-- The application reaches only its own database through this policy; every
-- other store stays denied by the application boundary.
function M.database_policy(owner_raw: unknown, name_raw: unknown, policy_id_raw: unknown): (Object?, string?)
    local database, database_error = M.database(owner_raw, name_raw)
    if not database or type(policy_id_raw) ~= "string" then
        return nil, database_error or "database grant policy identity is invalid"
    end
    local id: string = policy_id_raw :: string
    if #id == 0 or #id > 160 then return nil, "database grant policy identity is invalid" end
    return policy(id, {"db.get"}, {(database :: {[string]: unknown}).id :: string},
        "Host-generated isolated application database grant"), nil
end

return M
