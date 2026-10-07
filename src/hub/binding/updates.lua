-- MIT. Read live Bee pack selections and compare them with the Hub catalog.
local registry = require("registry")
local inventory = require("inventory")
local catalog = require("catalog")
local publication = require("publication")
local binary_identity = require("binary_identity")
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
        local latest, problem = catalog.latest(name)
        if latest then versions[name] = latest
        else problems[#problems + 1] = name .. ": " .. tostring(problem) end
    end
    return versions, table.concat(problems, "; ")
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
    local packs: {Pack} = {}
    for _, item in ipairs(installed.modules) do
        if selected[item.component] then
            local latest = available[item.component] or ""
            local compared = latest ~= "" and item.version ~= "" and semver.compare(latest, item.version) or nil
            packs[#packs + 1] = {component = item.component, installed_version = item.version, locked_version = item.locked_version,
                available_version = latest, update_available = compared ~= nil and compared > 0}
        end
    end

    local installed_root = ""
    if installed.deployment == "bee/bee" then
        for _, item in ipairs(installed.modules) do
            if item.component == installed.deployment then installed_root = item.version end
        end
    end
    local root_parameters: {unknown} = {}
    for _, root in ipairs(installed.roots) do
        if root.component == "bee/bee" and root.owner == "" then
            installed_root = root.version
            for _, parameter in ipairs(root.parameters) do
                root_parameters[#root_parameters + 1] = {name = parameter.name, value = parameter.value}
            end
        end
    end
    local available_root = available["bee/bee"] or ""
    local self_update: BeeUpdate = {installed_version = installed_root, available_version = available_root,
        update_available = false, needs_new_binary = false, reason = ""}
    local order = available_root ~= "" and semver.compare(available_root, installed_root) or nil
    self_update.update_available = order ~= nil and order > 0
    if installed_root ~= "" and order and order > 0 then
        local _, compatibility_error = publication.prepare({action = "update", component = "bee/bee",
            version = available_root, parameters = root_parameters, migration_policy = "none"}, (binary_identity.read_baked()))
        if compatibility_error and compatibility_error:find("needs a newer Bee binary", 1, true) then
            self_update.needs_new_binary = true
            self_update.reason = compatibility_error
        end
    end
    table.sort(packs, function(a: Pack, b: Pack): boolean return a.component < b.component end)
    return {modules = packs, bee_update = self_update, catalog_error = catalog_error}, nil
end

return M
