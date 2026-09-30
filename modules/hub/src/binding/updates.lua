-- MIT. Read live Bee pack selections and compare them with the Hub catalog.
local registry = require("registry")
local inventory = require("inventory")
local catalog = require("catalog")
local publication = require("publication")
local semver = require("semver")
local M = {}

type Pack = {component: string, installed_version: string, available_version: string, update_available: boolean}
type BeeUpdate = {installed_version: string, available_version: string, update_available: boolean, needs_new_binary: boolean, reason: string}
type Result = {modules: {Pack}, bee_update: BeeUpdate, catalog_error: string}

local function bee_component(name: string): boolean
    return name == "bee/bee" or name:match("^bee/") ~= nil
end

local function latest_versions(): ({[string]: string}, string)
    local versions: {[string]: string} = {}
    local page = 1
    while page <= 2 do
        local result, problem = catalog.browse({keyword = "bee", page = page})
        if not result then return versions, tostring(problem or "Bee package catalog is unavailable") end
        for _, item in ipairs(result.items) do
            if bee_component(item.component) then versions[item.component] = item.latest_version end
        end
        if result.page * result.page_size >= result.total then break end
        page = page + 1
    end
    if page > 2 then return versions, "Bee package catalog exceeds the status bound" end
    return versions, ""
end

function M.read(): (Result?, string?)
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    local installed, inventory_error = inventory.decode(state, snapshot:version():id())
    if not installed then return nil, tostring(inventory_error) end
    local available, catalog_error = latest_versions()
    local packs: {Pack} = {}
    for _, item in ipairs(installed.modules) do
        if bee_component(item.component) then
            local latest = available[item.component] or ""
            local compared = latest ~= "" and item.version ~= "" and semver.compare(latest, item.version) or nil
            packs[#packs + 1] = {component = item.component, installed_version = item.version,
                available_version = latest, update_available = compared ~= nil and compared > 0}
        end
    end

    local installed_root, root_id = "", nil
    local root_parameters: {unknown} = {}
    for _, root in ipairs(installed.roots) do
        if root.component == "bee/bee" and root.owner == "" then
            installed_root, root_id = root.version, root.id
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
    if root_id and order and order > 0 then
        local _, compatibility_error = publication.prepare({action = "update", component = "bee/bee",
            version = available_root, parameters = root_parameters, migration_policy = "none"})
        if compatibility_error and compatibility_error:find("needs a newer Bee binary", 1, true) then
            self_update.needs_new_binary = true
            self_update.reason = compatibility_error
        end
    end
    table.sort(packs, function(a: Pack, b: Pack): boolean return a.component < b.component end)
    return {modules = packs, bee_update = self_update, catalog_error = catalog_error}, nil
end

return M
