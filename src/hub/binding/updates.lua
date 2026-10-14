-- MIT. Read live Bee pack selections and compare them with the Hub catalog.
local registry = require("registry")
local inventory = require("inventory")
local catalog = require("catalog")
local plan = require("plan")
local artifact_source = require("artifact_source")
local binary_identity = require("binary_identity")
local canonical = require("canonical")
local bounds = require("bounds")
local requirements = require("requirements")
local hash = require("hash")
local store = require("store")
local semver = require("semver")
local M = {}

type Pack = {component: string, installed_version: string, locked_version: string, available_version: string, update_available: boolean}
type BeeUpdate = {installed_version: string, available_version: string, update_available: boolean, needs_new_binary: boolean, reason: string}
type Result = {modules: {Pack}, bee_update: BeeUpdate, catalog_error: string}
-- latest_versions reads the newest Hub release of each selected pack; a pack
-- Hub cannot answer for keeps no version and names its problem.
local function latest_versions(selected: {[string]: boolean}): ({[string]: string}, string)
    local versions: {[string]: string} = {}
    local problems: {string} = {}
    local names: {string} = {}
    for name in pairs(selected) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        if name ~= "bee/bee" then
            local latest, problem = catalog.latest(name)
            if latest then versions[name] = latest
            else problems[#problems + 1] = name .. ": " .. tostring(problem) end
        end
    end
    return versions, table.concat(problems, "; ")
end

local function select_bee(state: unknown, installed: inventory.Result, installed_root: string,
    parameters: {requirements.Parameter}): (BeeUpdate?, string?)
    local versions: {string} = {}
    local seen: {[string]: boolean} = {}
    for page = 1, 64 do
        local items, more, problem = catalog.available("bee/bee", page)
        if not items or more == nil then return nil, problem or "cannot list Bee versions" end
        for _, version in ipairs(items) do
            if not semver.parse(version) then return nil, "Bee catalog contains an invalid version" end
            if seen[version] then return nil, "version history changed while paging; refresh" end
            seen[version] = true
            versions[#versions + 1] = version
        end
        if not more then break end
        if page == 64 then return nil, "Bee update selection exceeds version page bound" end
    end
    table.sort(versions, function(a: string, b: string): boolean return (semver.compare(a, b) or 0) > 0 end)
    local baked = binary_identity.read_baked()
    local encoded, encoding_error = canonical.encode({versions = versions, revision = installed.version,
        binary = baked, installed = installed_root, parameters = parameters})
    if not encoded then return nil, encoding_error end
    local cache, cache_error = store.get("bee.hub.service:classifications")
    if not cache then return nil, tostring(cache_error) end
    local function finish(value: BeeUpdate?, problem: string?): (BeeUpdate?, string?)
        cache:release()
        return value, problem
    end
    local key = "bee_update_v1:" .. hash.sha256(encoded)
    local raw, read_error = cache:get(key)
    if read_error and not errors.is(read_error, errors.NOT_FOUND) then return finish(nil, tostring(read_error)) end
    local cached = bounds.object(raw)
    if cached and type(cached.installed_version) == "string" and type(cached.available_version) == "string"
        and type(cached.update_available) == "boolean" and type(cached.needs_new_binary) == "boolean" and type(cached.reason) == "string" then
        return finish({installed_version = cached.installed_version, available_version = cached.available_version,
            update_available = cached.update_available, needs_new_binary = cached.needs_new_binary, reason = cached.reason}, nil)
    end
    local result: BeeUpdate = {installed_version = installed_root, available_version = "", update_available = false,
        needs_new_binary = false, reason = ""}
    local source = artifact_source.new(state, installed, "bee/bee")
    for _, version in ipairs(versions) do
        local order = semver.compare(version, installed_root)
        if order and order >= 0 then
            if order == 0 then
                if result.available_version == "" then result.available_version = version end
            else
                local prepared, problem = plan.prepare(state, installed.version, {action = "update", component = "bee/bee",
                    version = version, parameters = parameters, migration_policy = "none"}, source, baked)
                if prepared then
                    if result.available_version == "" then result.available_version, result.update_available = version, true end
                elseif problem and problem:find("needs a newer Bee binary", 1, true) then
                    if not result.needs_new_binary then
                        result.needs_new_binary, result.reason = true, version .. " " .. problem
                    end
                else return finish(nil, version .. ": " .. tostring(problem)) end
            end
        end
        if result.available_version ~= "" and result.needs_new_binary then break end
    end
    local saved, save_error = cache:set(key, result)
    if not saved then return finish(nil, tostring(save_error)) end
    return finish(result, nil)
end

function M.read(): (Result?, string?)
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    local installed, inventory_error = inventory.decode(state, snapshot:version():id())
    if not installed then return nil, tostring(inventory_error) end
    local selected: {[string]: boolean} = {}
    if installed.deployment then selected[installed.deployment] = true end
    for _, root in ipairs(installed.roots) do
        if inventory.host_component(root) then selected[root.component] = true end
    end
    local available, catalog_error = latest_versions(selected)
    local installed_root = ""
    if installed.deployment == "bee/bee" then
        for _, item in ipairs(installed.modules) do
            if item.component == installed.deployment then installed_root = item.version end
        end
    end
    local root_parameters: {requirements.Parameter} = {}
    for _, root in ipairs(installed.roots) do
        if root.component == "bee/bee" and root.owner == "" then
            installed_root = root.version
            for _, parameter in ipairs(root.parameters) do
                root_parameters[#root_parameters + 1] = {name = parameter.name, value = parameter.value}
            end
        end
    end
    local self_update: BeeUpdate = {installed_version = installed_root, available_version = "",
        update_available = false, needs_new_binary = false, reason = ""}
    if installed_root ~= "" then
        local choice, problem = select_bee(state, installed, installed_root, root_parameters)
        if choice then self_update = choice; available["bee/bee"] = choice.available_version
        else catalog_error = (catalog_error ~= "" and catalog_error .. "; " or "") .. "bee/bee: " .. tostring(problem) end
    end
    local packs: {Pack} = {}
    for _, item in ipairs(installed.modules) do
        if selected[item.component] then
            local latest = available[item.component] or ""
            local compared = latest ~= "" and item.version ~= "" and semver.compare(latest, item.version) or nil
            packs[#packs + 1] = {component = item.component, installed_version = item.version, locked_version = item.locked_version,
                available_version = latest, update_available = compared ~= nil and compared > 0}
        end
    end
    table.sort(packs, function(a: Pack, b: Pack): boolean return a.component < b.component end)
    return {modules = packs, bee_update = self_update, catalog_error = catalog_error}, nil
end

return M
