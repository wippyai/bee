-- SPDX-License-Identifier: MIT
local hash = require("hash")
local fs = require("fs")
local sql = require("sql")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local grants = require("grants")
local profile_grants = require("profile_grants")
local resources = require("resources")
local daemon = require("daemon")
local quote = require("quote")
local types = require("types")
local M = {}
function M.name(node: string, workspace: string, profile: string): string
    return "bee-home-" .. assert(hash.sha256(assert(canonical.encode({node = node, workspace = workspace, profile = profile}))))
end
function M.selected(db: sql.DB, request: types.LaunchRequest): (string?, string?)
    local id = request.preferences and request.preferences.authority_grant_id
    if not id then return nil, nil end
    local grant, err = grants.read(db, id)
    if not grant then return nil, err or "Saved profile grant is unavailable" end
    local profile = bounds.id(grant.metadata.profile_id)
    if grant.domain ~= "profile_choices" or grant.workspace_id ~= request.workspace_id or not profile then return nil, "Saved profile home has another scope" end
    local invalid = profile_grants.live(db, grant)
    if invalid then return nil, invalid end
    return M.name(grant.owner_node, grant.workspace_id, profile), nil
end
local function root(): (fs.FS?, string?)
    local ref, err = resources.root()
    if not ref then return nil, err end
    local volume, open_error = fs.get(ref)
    return volume, open_error and tostring(open_error) or nil
end
local function marker(name: string): string return "/profile-homes/" .. name end
local function inspect(name: string): (boolean?, string?)
    local value, err, absent = daemon.request("GET", "/volumes/" .. name)
    if absent then return false, nil end
    if err then return nil, err end
    local data = bounds.object(value)
    local labels = data and bounds.object(data.Labels)
    if not data or data.Name ~= name or not labels or labels["bee.profile-home"] ~= name then return nil, "Docker volume is not owned by this profile" end
    return true, nil
end
function M.ensure(name: string): string?
    local volume, err = root()
    if not volume then return err or "Profile home receipts unavailable" end
    if not volume:exists("/profile-homes") then
        local made, failure = volume:mkdir("/profile-homes")
        if not made then return tostring(failure) end
    end
    local written, write_error = volume:writefile(marker(name), name, {atomic = true})
    if not written then return tostring(write_error) end
    local exists, inspect_error = inspect(name)
    if exists == nil then return inspect_error end
    if exists then return nil end
    local _, create_error = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "volume", "create", "--label", "bee.profile-home=" .. name, name})
    if create_error then return create_error end
    local owned, verify_error = inspect(name)
    if not owned then return verify_error or "Docker did not create the profile home volume" end
    return nil
end
function M.destroy(tx: sql.Transaction, node: string, workspace: string, profile: string, reset: boolean): string?
    local name = M.name(node, workspace, profile)
    local volume, err = root()
    if not volume then return err or "Profile home receipts unavailable" end
    local rows, query_error = tx:query([[SELECT attempt_id FROM bee_placement_attempts
        WHERE placement_kind = 'docker' AND json_extract(placement_spec_json, '$.home_volume') = ?
        AND NOT (execution_state IN ('exited', 'start_failed') AND cleanup_state = 'complete') LIMIT 1]], {name})
    if not rows then return tostring(query_error) end
    if #rows > 0 then return "Stop and close this profile's agents before resetting or removing its home" end
    if not volume:exists(marker(name)) then
        if reset then return M.ensure(name) end
        return nil
    end
    local exists, inspect_error = inspect(name)
    if exists == nil then return inspect_error end
    if exists then
        local _, remove_error = daemon.request("DELETE", "/volumes/" .. name)
        if remove_error then return remove_error end
    end
    if reset then return M.ensure(name) end
    local overlay, overlay_error = registry.overlay("bee.placement.docker:homes")
    if not overlay then return tostring(overlay_error) end
    local entries, entries_error = overlay:entries()
    if not entries then return tostring(entries_error) end
    local changes = overlay:changes()
    local count = 0
    for _, entry in ipairs(entries) do
        local data = bounds.object(entry.data)
        local volumes = data and bounds.array(data.volumes, 1)
        if entry.kind == "exec.docker" and volumes and #volumes == 1 and volumes[1] == name .. ":/home/bee:rw" then
            changes:delete(entry.id)
            count = count + 1
        end
    end
    if count > 0 then
        local _, apply_error = changes:apply()
        if apply_error then return tostring(apply_error) end
    end
    local removed, remove_error = volume:remove(marker(name))
    if not removed then return tostring(remove_error) end
    return nil
end
function M.executor(base: string, name: string): (string?, string?)
    local entry, err = registry.get(base)
    local data = entry and bounds.object(entry.data)
    if not data or not entry or entry.kind ~= "exec.docker" then return nil, tostring(err or "Docker executor unavailable") end
    local identity = assert(hash.sha256(assert(canonical.encode({base = data, home = name}))))
    local ref = "bee.placement.docker:home-" .. identity
    local overlay, overlay_error = registry.overlay("bee.placement.docker:homes")
    if not overlay then return nil, tostring(overlay_error) end
    if not overlay:get(ref) then
        local config: {[string]: unknown} = {}
        for key, value in pairs(data) do config[key] = value end
        config.volumes = {name .. ":/home/bee:rw"}
        local changes = overlay:changes()
        changes:create({id = ref, kind = "exec.docker", data = config})
        local _, apply_error = changes:apply()
        if apply_error then return nil, tostring(apply_error) end
    end
    return ref, nil
end
-- Launch files remain on the broker's attempt filesystem. Empty mount points
-- contain no provider or gateway bytes, including when the container is gone.
function M.files(home_path: string, login_paths: {string}, state_paths: {string}): ({string}?, string?, {[string]: string}?)
    local volume, err = root()
    if not volume then return nil, err end
    local base = home_path .. "/home"
    local paths: {string} = {}
    local function walk(relative: string): string?
        local iterator, state, first = volume:readdir(base .. relative)
        if not iterator then return tostring(state) end
        for entry in iterator, state, first do
            local path = relative .. "/" .. entry.name
            if entry.type == "directory" then
                local failure = walk(path)
                if failure then return failure end
            elseif entry.type == "file" then paths[#paths + 1] = path:sub(2)
            else return "Launch home contains an unsupported file type" end
        end
        return nil
    end
    local failure = walk("")
    if failure then return nil, failure end
    for _, path in ipairs(login_paths) do
        if not volume:exists(base .. "/" .. path) then
            local parent = base
            for part in (path:match("^(.*)/[^/]+$") or ""):gmatch("[^/]+") do
                parent = parent .. "/" .. part
                if not volume:exists(parent) then
                    local made, mkdir_error = volume:mkdir(parent)
                    if not made then return nil, tostring(mkdir_error) end
                end
            end
            local file, open_error = volume:open(base .. "/" .. path, "wx")
            if not file then return nil, tostring(open_error) end
            file:close()
            paths[#paths + 1] = path
        end
    end
    local seeds: {[string]: string} = {}
    local overlays: {string} = {}
    for _, path in ipairs(paths) do
        if bounds.member(path, state_paths) then
            local content, read_error = volume:readfile(base .. "/" .. path)
            if not content or #content > 65536 then return nil, tostring(read_error or "Provider state initializer exceeds its bound") end
            seeds[path] = content
        else overlays[#overlays + 1] = path end
    end
    table.sort(overlays)
    return overlays, nil, seeds
end
function M.initialize(name: string, image: string, user: string, files: {string}, seeds: {[string]: string}): string?
    local script: {string} = {"set -eu", "chown " .. quote.posix(user) .. " /home/bee", "chmod 700 /home/bee"}
    local made: {[string]: boolean} = {}
    local targets: {string} = {}
    for _, path in ipairs(files) do targets[#targets + 1] = path end
    for path in pairs(seeds) do targets[#targets + 1] = path end
    table.sort(targets)
    for _, path in ipairs(targets) do
        local parent = "/home/bee"
        for part in (path:match("^(.*)/[^/]+$") or ""):gmatch("[^/]+") do
            parent = parent .. "/" .. part
            if not made[parent] then
                local quoted = quote.posix(parent)
                script[#script + 1] = "test ! -L " .. quoted .. "; if test ! -e " .. quoted .. "; then mkdir " .. quoted .. "; chown " .. quote.posix(user) .. " " .. quoted .. "; fi"
                made[parent] = true
            end
        end
        local target = quote.posix("/home/bee/" .. path)
        local write = seeds[path] and "printf %s " .. quote.posix(seeds[path]) .. " > " .. target or "touch " .. target
        script[#script + 1] = "test ! -L " .. target .. "; if test ! -e " .. target .. "; then " .. write .. "; chown " .. quote.posix(user) .. " " .. target .. "; fi"
    end
    local _, err = daemon.command({"docker", "--host", "unix:///var/run/docker.sock", "run", "--rm", "--network", "none", "--read-only", "--user", "0:0",
        "--cap-drop", "ALL", "--cap-add", "CHOWN", "--cap-add", "FOWNER", "--cap-add", "DAC_OVERRIDE", "--security-opt", "no-new-privileges", "--entrypoint", "/bin/sh",
        "--mount", "type=volume,source=" .. name .. ",target=/home/bee", image, "-c", table.concat(script, "\n")})
    return err
end
return M
