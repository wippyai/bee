-- MIT. Attempt homes and retained session directories under the placement
-- root. Directory keys are derived digests, never caller identifiers; a
-- key that already exists is a collision, not a reuse.
local fs = require("fs")
local hash = require("hash")
local resources = require("resources")
local M = {}
M.ATTEMPTS = "attempts"
M.SESSIONS = "sessions"
M.MAX_REPLAY_BYTES = 16384
M.REPLAY_CHUNK_BYTES = 4096
local function key(kind: string, id: string): (string?, string?)
    local digest, err = hash.sha256(kind .. "\n" .. id)
    if err or not digest then return nil, "derive directory key" end
    return digest:sub(1, 32), nil
end
function M.attempt_key(owner_id: string, attempt_id: string): (string?, string?)
    return key("attempt/" .. owner_id, attempt_id)
end
function M.session_key(owner_id: string, session_ref: string): (string?, string?)
    return key("session/" .. owner_id, session_ref)
end
local function volume(): (fs.FS?, string?)
    local root, root_error = resources.root()
    if not root then return nil, root_error end
    local vol, err = fs.get(root)
    if not vol then return nil, "placement root unavailable" end
    return vol, nil
end
local function ensure(vol: fs.FS, path: string): string?
    local exists = vol:exists(path)
    if exists then
        if not vol:isdir(path) then return path .. " is not a directory" end
        return nil
    end
    local made, err = vol:mkdir(path)
    if not made then return "create " .. path .. ": " .. tostring(err) end
    return nil
end
-- Creates the attempt home; an existing directory under the derived key
-- means another attempt already claimed it.
function M.create_attempt(home_key: string): (string?, string?)
    local vol, vol_error = volume()
    if not vol then return nil, vol_error end
    local parent_error = ensure(vol, "/" .. M.ATTEMPTS)
    if parent_error then return nil, parent_error end
    local path = "/" .. M.ATTEMPTS .. "/" .. home_key
    if vol:exists(path) then return nil, "attempt home collision" end
    local made, err = vol:mkdir(path)
    if not made then return nil, "create attempt home: " .. tostring(err) end
    local home_error = ensure(vol, path .. "/home")
    if home_error then return nil, home_error end
    return path, nil
end
-- Session directories are retained across attempts and created on demand.
function M.ensure_session(session_key: string): (string?, string?)
    local vol, vol_error = volume()
    if not vol then return nil, vol_error end
    local parent_error = ensure(vol, "/" .. M.SESSIONS)
    if parent_error then return nil, parent_error end
    local path = "/" .. M.SESSIONS .. "/" .. session_key
    local session_error = ensure(vol, path)
    if session_error then return nil, session_error end
    local home_error = ensure(vol, path .. "/home")
    if home_error then return nil, home_error end
    return path, nil
end
local function remove_tree(vol: fs.FS, path: string): string?
    for entry in vol:readdir(path) do
        local child = path .. "/" .. tostring(entry.name)
        if entry.type == "directory" then
            local nested = remove_tree(vol, child)
            if nested then return nested end
        else
            local removed, err = vol:remove(child)
            if not removed then return "remove " .. child .. ": " .. tostring(err) end
        end
    end
    local removed, err = vol:remove(path)
    if not removed then return "remove " .. path .. ": " .. tostring(err) end
    return nil
end
function M.remove_attempt(home_key: string): string?
    local vol, vol_error = volume()
    if not vol then return vol_error end
    local path = "/" .. M.ATTEMPTS .. "/" .. home_key
    if not vol:exists(path) then return nil end
    return remove_tree(vol, path)
end
function M.attempt_exists(home_key: string): boolean
    local vol = volume()
    if not vol then return false end
    return vol:exists("/" .. M.ATTEMPTS .. "/" .. home_key) == true
end
-- The OS path of a placement path, for the child's environment.
-- write_protected: one file under a selected attempt or session home,
-- created exclusively so a pre-existing file fails instead of being merged
-- or replaced. A retained home may replay only byte-identical host-approved
-- content, read to a fixed bound; it never overwrites an existing file.
-- created records the parents this runner made in this start, so a second
-- file in one of them is written into a directory the runner itself
-- created moments ago and never into one it found.
local function retained_content(vol: fs.FS, path: string, content: string): string?
    if #content > M.MAX_REPLAY_BYTES then return "retained configuration exceeds replay bound" end
    local file, open_error = vol:open(path, "r")
    if not file then return "read retained configuration: " .. tostring(open_error) end
    local found = ""
    while #found <= M.MAX_REPLAY_BYTES do
        local chunk: unknown = file:read(math.min(M.REPLAY_CHUNK_BYTES, M.MAX_REPLAY_BYTES + 1 - #found))
        if type(chunk) ~= "string" or chunk == "" then break end
        found = found .. (chunk :: string)
    end
    file:close()
    if #found > M.MAX_REPLAY_BYTES then return "retained configuration exceeds replay bound" end
    if found ~= content then return "retained configuration differs from host-approved content" end
    return nil
end
function M.write_protected(home_path: string, relative: string, content: string, created: {[string]: boolean}?, replay_retained: boolean?): (string?, string?, boolean?)
    local vol, vol_error = volume()
    if not vol then return nil, vol_error end
    if relative:find("^/") or relative:find("%.%.") then return nil, "configuration path escapes the home" end
    local root = home_path .. "/home"
    local target = root .. "/" .. relative
    if vol:exists(target) then
        if replay_retained ~= true then return nil, "configuration file already exists" end
        local replay_error = retained_content(vol, target, content)
        if replay_error then return nil, replay_error end
        return target, nil, true
    end
    local parent = target:match("^(.*)/[^/]+$")
    if parent and parent ~= root then
        -- The attempt home was created by this runner moments ago, so the
        -- parent is created here, never adopted: an existing entry, whether a
        -- directory, a link or anything else, refuses the write unless this
        -- runner created it in this start. Symlink resolution below the
        -- volume root is the runtime fs module's own containment, which this
        -- code assumes rather than proves.
        if vol:exists(parent) then
            if not created or not created[parent] then return nil, "configuration parent already exists" end
        else
            local made, mkdir_error = vol:mkdir(parent)
            if not made then return nil, "create configuration parent: " .. tostring(mkdir_error) end
            if created then created[parent] = true end
        end
    end
    local file, open_error = vol:open(target, "wx")
    if not file then return nil, "create configuration: " .. tostring(open_error) end
    local written, write_error = file:write(content)
    file:close()
    if not written then return nil, "write configuration: " .. tostring(write_error) end
    return target, nil, false
end
function M.os_path(path: string): (string?, string?)
    local root, root_error = resources.root()
    if not root then return nil, root_error end
    local directory, directory_error = resources.directory(root)
    if not directory then return nil, directory_error end
    return directory .. path, nil
end
return M
