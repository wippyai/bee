-- MIT. Attempt homes and retained session directories under the placement
-- root. Directory keys are derived digests, never caller identifiers; a
-- key that already exists is a collision, not a reuse.
local fs = require("fs")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local resources = require("resources")
local formats = require("formats")
local M = {}
M.ATTEMPTS = "attempts"
M.SESSIONS = "sessions"
M.MAX_REPLAY_BYTES = 16384
M.MAX_CONFIGURATION_BASE_BYTES = 131072
M.REPLAY_CHUNK_BYTES = 4096
-- Login bytes are opaque provider state. They have a separate, larger bound
-- from declarative configuration and are never compared on retained reuse:
-- the harness may refresh them while it owns the private home.
M.MAX_LOGIN_BYTES = 65536
M.MAX_LOGIN_IDENTITY_BYTES = 2048
type LoginSource = {provider: string, definition_id: string, definition_revision: integer, optional: boolean?}
type LoginDestination = {path: string, identity_path: string, source: LoginSource, format: formats.Format}
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
-- FileInfo mode comes from the selected fs.directory's actual OS root. The
-- declared registry mode is only a creation request, not proof that an
-- existing root excludes group and other users.
local function private_root(vol: fs.FS): string?
    local info, stat_error = vol:stat("/")
    if not info then return "stat placement root: " .. tostring(stat_error) end
    if info.type ~= "directory" then return "placement root is not a directory" end
    local mode = info.mode
    if type(mode) ~= "number" or mode < 0 then return "placement root has no numeric mode" end
    if math.floor(mode) % 64 ~= 0 then return "placement root permits group or other access" end
    return nil
end
function M.check_private_root(): string?
    local vol, vol_error = volume()
    if not vol then return vol_error or "placement root unavailable" end
    return private_root(vol)
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
    local closed, close_error = file:close()
    if closed == false then return "close retained configuration: " .. tostring(close_error) end
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
    local directories = relative:match("^(.*)/[^/]+$") or ""
    local parent = root
    for segment in directories:gmatch("[^/]+") do
        parent = parent .. "/" .. segment
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
-- Only materialization's persisted delivery files use this operation. Login
-- and provider conversation files retain their separate ownership. The runtime
-- verifies/pins existing parents; missing parents can only be created through
-- directories this materialization itself created.
function M.publish_configuration(home_path: string, relative: string, content: string, created: {[string]: boolean}?): (string?, string?, boolean?)
    if relative == "" or relative:find("^/") or relative:find("%.%.") then return nil, "configuration path escapes the home", false end
    if #content > M.MAX_REPLAY_BYTES then return nil, "configuration exceeds publication bound", false end
    local vol, vol_error = volume()
    if not vol then return nil, vol_error, false end
    local privacy_error = private_root(vol)
    if privacy_error then return nil, privacy_error, false end
    local root = home_path .. "/home"
    local target = root .. "/" .. relative
    local directories = relative:match("^(.*)/[^/]+$") or ""
    local final_parent = directories == "" and root or root .. "/" .. directories
    if not vol:exists(final_parent) then
        local parent = root
        for segment in directories:gmatch("[^/]+") do
            parent = parent .. "/" .. segment
            if vol:exists(parent) then
                if not created or not created[parent] then return nil, "configuration parent already exists", false end
            else
                local made, mkdir_error = vol:mkdir(parent)
                if not made then return nil, "create configuration parent: " .. tostring(mkdir_error), false end
                if created then created[parent] = true end
            end
        end
    end
    local written, write_error = vol:writefile(target, content, {atomic = true})
    if not written then
        local details = bounds.object(write_error and write_error:details() or nil)
        local published = details ~= nil and details.published == true
        return nil, published and "configuration published; durability requires inspection" or "configuration publication refused", published
    end
    return target, nil, false
end
-- The authorized broker supplies the frozen layout. Definition identity binds
-- that layout while preserving the existing retained-home identity encoding.
function M.decode_login_source(value: unknown): (LoginDestination?, string?)
    local object = bounds.object(value)
    if not object then return nil, "login source must be an object" end
    local unknown_field = bounds.fields(object, {"provider", "definition_id", "definition_revision", "optional", "format"})
    if unknown_field then return nil, unknown_field end
    local provider = bounds.id(object.provider)
    if not provider then return nil, "login provider is unsupported" end
    local definition_id = bounds.id(object.definition_id)
    if not definition_id then return nil, "login definition_id is not an identifier" end
    local definition_revision = bounds.integer(object.definition_revision)
    if not definition_revision or definition_revision < 1 then return nil, "login definition_revision is not positive" end
    if object.optional ~= nil and type(object.optional) ~= "boolean" then return nil, "login optional must be boolean" end
    local source: LoginSource = {provider = provider, definition_id = definition_id, definition_revision = definition_revision}
    -- Required sources retain their existing identity encoding.
    if object.optional == true then source.optional = true end
    local format, format_error = formats.decode(object.format)
    if not format or not format.file then return nil, format_error or "login format has no file" end
    local marker = ".bee-retained-login-ready.json"
    local paths: {string} = {format.file.path}
    for _, item in ipairs(format.file.initialize) do paths[#paths + 1] = item.path end
    for _, path in ipairs(paths) do
        if path == marker or path:sub(1, #marker + 1) == marker .. "/" then return nil, "login format overlaps retained identity" end
    end
    return {path = format.file.path, identity_path = marker, source = source, format = format}, nil
end
local function read_bounded(vol: fs.FS, path: string, bound: integer, label: string?): (string?, string?)
    local what = label or "retained file"
    local file, open_error = vol:open(path, "r")
    if not file then return nil, "read " .. what .. ": " .. tostring(open_error) end
    local found = ""
    while #found <= bound do
        local chunk, read_error = file:read(math.min(M.REPLAY_CHUNK_BYTES, bound + 1 - #found))
        if chunk == nil then
            -- fs reports EOF as its ordinary final read result.
            if read_error and tostring(read_error) ~= "EOF" then
                file:close()
                return nil, "read " .. what .. ": " .. tostring(read_error)
            end
            break
        end
        if type(chunk) ~= "string" then
            file:close()
            return nil, "read " .. what .. " returned invalid data"
        end
        if chunk == "" then break end
        found = found .. (chunk :: string)
    end
    local closed, close_error = file:close()
    if closed == false then return nil, "close " .. what .. ": " .. tostring(close_error) end
    if #found > bound then return nil, what .. " exceeds bound" end
    return found, nil
end
-- Read a composition base from this retained private home and compare the bytes
-- read in this call with the durable initializer digest. Provider state is
-- writable, so path admission alone is never composition authority. An empty
-- file is a valid empty base; a missing or changed file refuses the launch.
function M.read_configuration(home_path: string, relative: string, expected_digest: string): (string?, string?)
    if not formats.path(relative) then return nil, "configuration base path escapes the home" end
    if #expected_digest ~= 64 or not expected_digest:match("^[0-9a-f]+$") then return nil, "configuration base digest is invalid" end
    local vol, vol_error = volume()
    if not vol then return nil, vol_error end
    local privacy_error = private_root(vol)
    if privacy_error then return nil, privacy_error end
    local target = home_path .. "/home/" .. relative
    if not vol:exists(target) then return nil, "configuration base is missing" end
    local content, read_error = read_bounded(vol, target, M.MAX_CONFIGURATION_BASE_BYTES, "configuration base")
    if content == nil then return nil, read_error end
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, "digest configuration base: " .. tostring(digest_error) end
    if digest ~= expected_digest then return nil, "configuration base differs from admitted content" end
    return content, nil
end
local function write_exclusive(vol: fs.FS, path: string, content: string): string?
    local file, open_error = vol:open(path, "wx")
    if not file then return "create retained login: " .. tostring(open_error) end
    -- Exclusive creation is the complete write for an admitted empty setup
    -- file. The runtime file API rejects write("") as missing data.
    local written: boolean = true
    local write_error: unknown = nil
    if content ~= "" then written, write_error = file:write(content) end
    local closed, close_error = file:close()
    -- The pinned Lua fs API returns a success boolean, rather than a byte
    -- count. A false result is its only exposed short-write/error signal.
    if written ~= true then return "write retained login: " .. tostring(write_error) end
    if closed == false then return "close retained login: " .. tostring(close_error) end
    return nil
end
local function create_login_parents(vol: fs.FS, root: string, relative: string, created: {[string]: boolean}): string?
    local directory = relative:match("^(.*)/[^/]+$")
    if not directory then return nil end
    local parent = root
    for segment in directory:gmatch("[^/]+") do
        parent = parent .. "/" .. segment
        if vol:exists(parent) then
            if not created[parent] then return "retained login parent already exists" end
        else
            local made, mkdir_error = vol:mkdir(parent)
            if not made then return "create retained login parent: " .. tostring(mkdir_error) end
            created[parent] = true
        end
    end
    return nil
end
-- Inspect the retained login commit marker without changing the home. Placement
-- uses this before binding setup-file digests, so a new marker can never become
-- visible before the external binding that makes its configuration reusable.
function M.login_replayed(home_path: string, value: unknown): (boolean?, string?)
    local destination, decode_error = M.decode_login_source(value)
    if not destination then return nil, decode_error end
    local identity, identity_error = canonical.encode(destination.source)
    if not identity then return nil, "encode retained login identity: " .. tostring(identity_error) end
    if #identity > M.MAX_LOGIN_IDENTITY_BYTES then return nil, "retained login identity exceeds bound" end
    local vol, vol_error = volume()
    if not vol then return nil, vol_error end
    local privacy_error = private_root(vol)
    if privacy_error then return nil, privacy_error end
    local root = home_path .. "/home"
    local target = root .. "/" .. destination.path
    local identity_target = root .. "/" .. destination.identity_path
    if not vol:exists(identity_target) then
        if vol:exists(target) then return nil, "retained login is incomplete" end
        return false, nil
    end
    local found, read_error = read_bounded(vol, identity_target, M.MAX_LOGIN_IDENTITY_BYTES, "retained login identity")
    if not found then return nil, read_error end
    if found ~= identity then return nil, "retained login source changed" end
    if not vol:exists(target) and destination.source.optional ~= true then return nil, "retained login is incomplete" end
    return true, nil
end
-- Seeds one admitted login destination. On later resumes it verifies
-- the non-secret source identity and leaves the destination untouched: the
-- harness's opaque refresh is therefore retained without applying immutable
-- configuration replay rules to authentication bytes.
function M.retain_login(home_path: string, value: unknown, opaque: string?, created: {[string]: boolean}?): (string?, string?, boolean?)
    local destination, decode_error = M.decode_login_source(value)
    if not destination then return nil, decode_error end
    if opaque == nil then
        if destination.source.optional ~= true then return nil, "required login bytes missing" end
    elseif #opaque == 0 or #opaque > M.MAX_LOGIN_BYTES then return nil, "login bytes exceed bound" end
    local identity, identity_error = canonical.encode(destination.source)
    if not identity then return nil, "encode retained login identity: " .. tostring(identity_error) end
    if #identity > M.MAX_LOGIN_IDENTITY_BYTES then return nil, "retained login identity exceeds bound" end
    local vol, vol_error = volume()
    if not vol then return nil, vol_error end
    local privacy_error = private_root(vol)
    if privacy_error then return nil, privacy_error end
    local root = home_path .. "/home"
    local target = root .. "/" .. destination.path
    local identity_target = root .. "/" .. destination.identity_path
    local target_exists = vol:exists(target)
    local identity_exists = vol:exists(identity_target)
    if identity_exists then
        local found, read_error = read_bounded(vol, identity_target, M.MAX_LOGIN_IDENTITY_BYTES, "retained login identity")
        if not found then return nil, read_error end
        if found ~= identity then return nil, "retained login source changed" end
        if not target_exists and destination.source.optional ~= true then return nil, "retained login is incomplete" end
        return target, nil, true
    end
    if target_exists then return nil, "retained login is incomplete" end
    local parents: {[string]: boolean} = created or {}
    local parent_error = create_login_parents(vol, root, destination.path, parents)
    if parent_error then return nil, parent_error end
    -- The ready marker is written only after the opaque bytes. A failed or
    -- interrupted seed leaves no accepted marker and is refused on resume.
    if opaque ~= nil then
        local write_error = write_exclusive(vol, target, opaque)
        if write_error then return nil, write_error end
    end
    -- Host setup may be admitted independently from optional login bytes. The
    -- component's ordinary initializers still run only with a present login.
    local file = destination.format.file
    if not file then return nil, "login format has no file" end
    for _, item in ipairs(file.initialize) do
        if opaque ~= nil or item.on_missing_login == true then
            local setup_parent_error = create_login_parents(vol, root, item.path, parents)
            if setup_parent_error then return nil, setup_parent_error end
            local setup_error = write_exclusive(vol, root .. "/" .. item.path, item.content)
            if setup_error then return nil, setup_error end
        end
    end
    -- Optional absence commits the source binding too. Later CLI sign-in or
    -- sign-out belongs to this private home and must not trigger reseeding.
    local identity_write_error = write_exclusive(vol, identity_target, identity)
    if identity_write_error then return nil, identity_write_error end
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
