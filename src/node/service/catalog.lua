-- MIT. Installed node applications, menus and appearance settings.
local registry = require("registry")
local logger = require("logger")
local settings = require("settings")
local appearance = require("appearance")
local descriptor = require("descriptor")
local M = {}
-- A menu an app names and an installed app, as the catalog lists them.
type Menu = {id: string, title: string, location: string, order: integer}
type CatalogApp = {id: string, title: string, menus: {Menu}, singleton: boolean}
type Theme = appearance.Theme

local MENU_TYPE = "bee.menu"
-- role_app is the installed app declaring role, the first by id.
local function role_app(role: string): (string?, string?)
    local entries, find_error = registry.find({[".kind"] = "process.lua", ["meta.type"] = descriptor.TYPE})
    if not entries then return nil, "installed apps cannot be read: " .. tostring(find_error) end
    local found: string? = nil
    for _, entry in ipairs(entries) do
        local declared = descriptor.decode(entry.id, entry.meta.application)
        if declared and declared.role == role and (found == nil or entry.id < found) then found = entry.id end
    end
    return found, nil
end

-- menus returns the installed menus, registry entries of type MENU_TYPE whose
-- data names a title, the place the menu shows (the Start panel or the
-- desktop's context menu) and its order there, by id.
local function menus(): ({[string]: Menu}?, string?)
    local entries, find_error = registry.find({["meta.type"] = MENU_TYPE})
    if not entries then return nil, "installed menus cannot be read: " .. tostring(find_error) end
    local found: {[string]: Menu} = {}
    for _, entry in ipairs(entries) do
        local data: unknown = entry.data
        local order = type(data) == "table" and type(data.order) == "number" and math.tointeger(data.order) or nil
        if type(data) == "table" and type(data.title) == "string" and (data.location == "start" or data.location == "desktop") and order then
            found[entry.id] = {id = entry.id, title = data.title, location = data.location, order = order}
        else
            logger:warn("Menu entry names no title, location and order", {id = entry.id})
        end
    end
    return found, nil
end

-- catalog lists the installed apps: process entries of type bee.app whose
-- meta.application declares them, each with the installed menus it names.
local function catalog(): ({CatalogApp}?, string?)
    local installed, menus_error = menus()
    if not installed then return nil, menus_error end
    local entries, find_error = registry.find({[".kind"] = "process.lua", ["meta.type"] = descriptor.TYPE})
    if not entries then return nil, "installed apps cannot be read: " .. tostring(find_error) end
    local apps: {CatalogApp} = {}
    for _, entry in ipairs(entries) do
        local declared = descriptor.decode(entry.id, entry.meta.application)
        if declared then
            local placed: {Menu} = {}
            for _, id in ipairs(declared.menus) do
                local menu = installed[id]
                if menu then placed[#placed + 1] = menu
                else logger:warn("App names a menu that is not installed", {id = entry.id, menu = id}) end
            end
            apps[#apps + 1] = {id = entry.id, title = declared.title, menus = placed, singleton = declared.singleton}
        else
            logger:warn("App entry declares no valid application", {id = entry.id})
        end
    end
    table.sort(apps, function(a: CatalogApp, b: CatalogApp): boolean return a.title < b.title end)
    return apps, nil
end

-- themes returns the installed themes, registry entries of type
-- appearance.TYPE whose data is a palette, ordered by title, and the id of
-- the one marked meta.default.
local function themes(): ({Theme}?, string?, string?)
    local entries, find_error = registry.find({["meta.type"] = appearance.TYPE})
    if not entries then return nil, nil, "installed themes cannot be read: " .. tostring(find_error) end
    local found: {Theme} = {}
    local default_id: string? = nil
    for _, entry in ipairs(entries) do
        local palette: {[string]: unknown} = {}
        local data: unknown = entry.data
        if type(data) == "table" then
            for key, value in pairs(data) do palette[key] = value end
        end
        palette.id = entry.id
        local decoded = appearance.decode_theme(palette)
        if decoded then
            found[#found + 1] = decoded
            if entry.meta.default == true then default_id = entry.id end
        else
            logger:warn("Theme entry is not a palette", {id = entry.id})
        end
    end
    table.sort(found, function(a: Theme, b: Theme): boolean return a.title < b.title end)
    return found, default_id, nil
end

-- stored_appearance returns the node's appearance settings: the installed
-- theme its setting names (else the default theme entry, else the built-in
-- palette), its background and its taskbar style.
local function stored_appearance(installed: {Theme}, default_id: string?): appearance.Preferences
    local defaults = appearance.defaults()
    local chosen: appearance.Theme? = nil
    local id = settings.get("theme")
    for _, item in ipairs(installed) do
        if item.id == id then chosen = item end
    end
    if not chosen then
        for _, item in ipairs(installed) do
            if item.id == default_id then chosen = item end
        end
    end
    local background = settings.get("background") or defaults.background
    if not appearance.background_known(background) then background = defaults.background end
    local taskbar = settings.get("taskbar") or defaults.taskbar
    if taskbar ~= "labels" and taskbar ~= "icons" then taskbar = defaults.taskbar end
    return {theme = chosen or defaults.theme, background = background, taskbar = taskbar}
end

-- signature identifies an app catalog, so the owner announces real changes only.
local function signature(apps: {CatalogApp}): string
    local parts: {string} = {}
    for _, app in ipairs(apps) do
        local placed: {string} = {}
        for _, menu in ipairs(app.menus) do
            placed[#placed + 1] = menu.id .. ":" .. menu.title .. ":" .. menu.location .. ":" .. tostring(menu.order)
        end
        parts[#parts + 1] = app.id .. "=" .. app.title .. "/" .. table.concat(placed, ",")
    end
    return table.concat(parts, "\n")
end

local function same_palette(a: Theme, b: Theme): boolean
    local left: {[string]: unknown} = a
    local right: {[string]: unknown} = b
    for _, role in ipairs(appearance.ROLES) do
        if left[role] ~= right[role] then return false end
    end
    for _, role in ipairs(appearance.OPTIONAL_ROLES) do
        if left[role] ~= right[role] then return false end
    end
    return a.id == b.id and a.title == b.title
end

M.MENU_TYPE = MENU_TYPE
M.role_app = role_app
M.menus = menus
M.catalog = catalog
M.themes = themes
M.stored_appearance = stored_appearance
M.signature = signature
M.same_palette = same_palette
return M
