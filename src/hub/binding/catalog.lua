-- MIT. A small, caller-scoped view of the native Hub catalog.
local hub = require("hub")
local registry = require("registry")
local store = require("store")
local bounds = require("bounds")
local limits = require("limits")
local M = {}

M.MAX_QUERY_BYTES = 160
M.MAX_COMPONENT_BYTES = 160
M.MAX_VERSION_BYTES = 128
M.MAX_DESCRIPTION_BYTES = 4096
M.MAX_README_BYTES = 16384
M.MAX_PAGE = 10000
M.PAGE_SIZE = 50
M.MAX_ITEMS = 100
M.MAX_VERSIONS = 100
M.MAX_TOTAL = 1000000
M.TIMEOUT_SECONDS = 30

type Request = {query: string?, page: integer, keyword: string}
type DetailRequest = {component: string, page: integer}
type Item = {component: string, title: string, description: string, latest_version: string, application: boolean?}
type Browse = {items: {Item}, total: integer, page: integer, page_size: integer}
type Version = {version: string, yanked: boolean}
type VersionPage = {items: {Version}, total: integer, page: integer, page_size: integer}
type Detail = {component: string, latest_version: string, title: string, description: string, readme: string, readme_error: string, versions: {Version}, total_versions: integer, page: integer, page_size: integer}

local function component(value: unknown): string?
    local name = bounds.line(value, M.MAX_COMPONENT_BYTES)
    if not name or not name:match("^[%w_%-%.]+/[%w_%-%.]+$") then return nil end
    local organization, module = name:match("^([^/]+)/([^/]+)$")
    if organization == "." or organization == ".." or module == "." or module == ".." then return nil end
    return name
end

local function line_or_empty(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") then return nil end
    return value
end

local function title(value: unknown, fallback: string): string?
    if type(value) ~= "string" then return nil end
    if value == "" then return fallback end
    return bounds.line(value, M.MAX_COMPONENT_BYTES)
end

local function decode_item(raw: unknown): (Item?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "Hub module must be an object" end
    local name = component(value.full_name)
    if not name then return nil, "Hub module has no org/module name" end
    local display_name = title(value.display_name, name)
    if not display_name then return nil, "Hub module has an invalid title" end
    local description = bounds.text(value.description, M.MAX_DESCRIPTION_BYTES)
    if not description then return nil, "Hub module has an invalid description" end
    local latest_version = line_or_empty(value.latest_version, M.MAX_VERSION_BYTES)
    if not latest_version then return nil, "Hub module has an invalid latest version" end
    local application: boolean? = nil
    if value.type == "application" then application = true
    elseif value.type ~= nil and value.type ~= "unspecified" then application = false end
    return {component = name, title = display_name, description = description, latest_version = latest_version,
        application = application}, nil
end

function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "catalog request must be an object" end
    local extra = bounds.fields(value, {"query", "page", "keyword"})
    if extra then return nil, extra end
    local query: string? = nil
    if value.query ~= nil then
        query = bounds.line(value.query, M.MAX_QUERY_BYTES)
        if not query then return nil, "query must be a bounded line" end
    end
    local page: integer = 1
    if value.page ~= nil then
        local supplied = bounds.integer(value.page)
        if not supplied or supplied < 1 or supplied > M.MAX_PAGE then
            return nil, "page must be between 1 and " .. tostring(M.MAX_PAGE)
        end
        page = supplied
    end
    local keyword = "bee"
    if value.keyword ~= nil then
        local supplied = line_or_empty(value.keyword, M.MAX_QUERY_BYTES)
        if not supplied then return nil, "keyword must be a bounded line" end
        keyword = supplied
    end
    return {query = query, page = page, keyword = keyword}, nil
end

function M.decode_detail(raw: unknown): (DetailRequest?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "catalog detail request must be an object" end
    local extra = bounds.fields(value, {"component", "page"})
    if extra then return nil, extra end
    local name = component(value.component)
    if not name then return nil, "component must be an org/module name" end
    local page: integer = 1
    if value.page ~= nil then
        local supplied = bounds.integer(value.page)
        if not supplied or supplied < 1 or supplied > M.MAX_PAGE then return nil, "invalid version page" end
        page = supplied
    end
    return {component = name, page = page}, nil
end

function M.decode_browse(raw: unknown): (Browse?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "Hub catalog response must be an object" end
    local extra = bounds.fields(value, {"items", "total", "page", "page_size"})
    if extra then return nil, extra end
    local raw_items, items_error = bounds.dense_list(value.items, M.MAX_ITEMS, "Hub catalog items")
    if not raw_items then return nil, items_error end
    local total = bounds.count(value.total)
    if total == nil then return nil, "Hub catalog has an invalid total" end
    if total > M.MAX_TOTAL or total < #raw_items then return nil, "Hub catalog has an invalid total" end
    local page = bounds.integer(value.page)
    if page == nil or page < 1 or page > M.MAX_PAGE then return nil, "Hub catalog has an invalid page" end
    local page_size = bounds.integer(value.page_size)
    if page_size == nil or page_size < 1 or page_size > M.MAX_ITEMS then return nil, "Hub catalog has an invalid page size" end
    local items: {Item} = {}
    for index, raw_item in ipairs(raw_items) do
        local item, item_error = decode_item(raw_item)
        if not item then return nil, "Hub catalog item " .. tostring(index) .. ": " .. tostring(item_error) end
        items[index] = item
    end
    return {items = items, total = total, page = page, page_size = page_size}, nil
end

function M.decode_versions(raw: unknown): (VersionPage?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "Hub version response must be an object" end
    local extra = bounds.fields(value, {"items", "total", "page", "page_size"})
    if extra then return nil, extra end
    local raw_items, items_error = bounds.dense_list(value.items, M.MAX_VERSIONS, "Hub versions")
    if not raw_items then return nil, items_error end
    local total = bounds.count(value.total)
    if total == nil then return nil, "Hub versions has an invalid total" end
    if total > M.MAX_TOTAL or total < #raw_items then return nil, "Hub versions has an invalid total" end
    local page = bounds.integer(value.page)
    if not page or page < 1 or page > M.MAX_PAGE then return nil, "Hub versions has an invalid page" end
    local page_size = bounds.integer(value.page_size)
    if page_size ~= M.MAX_VERSIONS then return nil, "Hub versions has an invalid page size" end
    local versions: {Version} = {}
    for index, raw_item in ipairs(raw_items) do
        local item = bounds.object(raw_item)
        if not item then return nil, "Hub version " .. tostring(index) .. " must be an object" end
        local version = bounds.line(item.version, M.MAX_VERSION_BYTES)
        if not version then return nil, "Hub version " .. tostring(index) .. " has an invalid version" end
        if type(item.yanked) ~= "boolean" then return nil, "Hub version " .. tostring(index) .. " has an invalid yanked flag" end
        versions[index] = {version = version, yanked = item.yanked}
    end
    return {items = versions, total = total, page = page, page_size = M.MAX_VERSIONS}, nil
end

-- Package details retain versions and a diagnostic when the optional README fails.
function M.decode_detail_result(module: unknown, readme: unknown, version_response: unknown, requested_component: string,
    readme_error: string?): (Detail?, string?)
    local item, item_error = decode_item(module)
    if not item then return nil, item_error end
    if item.component ~= requested_component then return nil, "Hub returned another component" end
    local content = ""
    if readme_error == nil then
        local readme_value = bounds.object(readme)
        if not readme_value then return nil, "Hub README must be an object" end
        local text = bounds.text(readme_value.content, M.MAX_README_BYTES)
        if not text then return nil, "Hub README has invalid content" end
        content = text
    end
    local versions, versions_error = M.decode_versions(version_response)
    if not versions then return nil, versions_error end
    return {
        component = item.component, latest_version = item.latest_version,
        title = item.title,
        description = item.description,
        readme = content, readme_error = readme_error or "",
        versions = versions.items,
        total_versions = versions.total, page = versions.page, page_size = versions.page_size,
    }, nil
end

function M.application(metadata: unknown, entries: unknown): boolean
    local meta = bounds.object(metadata)
    if meta and meta.type == "application" then return true end
    for _, raw in ipairs(bounds.array(entries, limits.MAX_PACKAGE_ENTRIES) or {}) do
        local entry = bounds.object(raw)
        local declaration = entry and bounds.object(entry.meta)
        if declaration and declaration.type == "bee.app" then return true end
    end
    return false
end

local function application_package(item: Item): (boolean?, string?)
    if item.latest_version == "" then return false, nil end
    local package, problem = hub.versions.open(item.component, item.latest_version, {timeout = M.TIMEOUT_SECONDS})
    if not package then return nil, tostring(problem) end
    local digest = package.digest:gsub("^sha256:", "")
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then package:close(); return nil, "invalid artifact digest" end
    local cache, cache_error = store.get("bee.hub.service:classifications")
    if not cache then package:close(); return nil, tostring(cache_error) end
    local function finish(value: boolean?, problem: string?): (boolean?, string?)
        cache:release()
        local closed, close_error = package:close()
        if not closed then return nil, problem or tostring(close_error) end
        return value, problem
    end
    local key = "application_v1:" .. digest
    local cached, read_error = cache:get(key)
    if read_error and not errors.is(read_error, errors.NOT_FOUND) then return finish(nil, tostring(read_error)) end
    if type(cached) == "boolean" then return finish(cached, nil) end
    local metadata, metadata_error = package:metadata()
    if not metadata then return finish(nil, tostring(metadata_error)) end
    local application = M.application(metadata, {})
    if not application then
        local entries, entries_error = package:entries({kind = "process.lua", include_data = false})
        if not entries then return finish(nil, tostring(entries_error)) end
        application = M.application(metadata, entries)
    end
    local saved, save_error = cache:set(key, application)
    if not saved then return finish(nil, tostring(save_error)) end
    return finish(application, nil)
end

function M.browse(raw: unknown): (Browse?, string?)
    local request, request_error = M.decode(raw)
    if not request then return nil, request_error end
    -- Native Hub receives the existing caller grant; no registry or credential
    -- destination can be selected through this facade.
    local response, response_error
    local keywords: {string} = {}
    if request.keyword ~= "" then keywords[1] = request.keyword end
    if request.query then
        response, response_error = hub.modules.search(request.query, {page = request.page, page_size = M.PAGE_SIZE, keywords = keywords, timeout = M.TIMEOUT_SECONDS})
    else
        response, response_error = hub.modules.list({page = request.page, page_size = M.PAGE_SIZE, keywords = keywords, timeout = M.TIMEOUT_SECONDS})
    end
    if not response then return nil, tostring(response_error) end
    local result, result_error = M.decode_browse(response)
    if not result then return nil, result_error end
    if result.page ~= request.page or result.page_size ~= M.PAGE_SIZE then return nil, "Hub returned another catalog page" end
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    local application: {[string]: boolean} = {}
    local resolution = bounds.object(state.resolution)
    local modules = resolution and bounds.array(resolution.modules, 512)
    for _, raw_module in ipairs(modules or {}) do
        local module = bounds.object(raw_module)
        local name = module and component(module.name) or nil
        if name then application[name] = false end
    end
    local entries, find_error = snapshot:find({["meta.type"] = "bee.app"})
    if find_error then return nil, tostring(find_error) end
    local definitions: {[string]: boolean} = {}
    for _, entry in ipairs(entries) do definitions[entry.id] = true end
    for _, raw_entry in ipairs(state.entries) do
        local entry = bounds.object(raw_entry)
        local id = entry and bounds.id(entry.id)
        local ownership = entry and bounds.object(entry.registry)
        local owner = ownership and component(ownership.owner) or nil
        if id and definitions[id] and owner then application[owner] = true end
    end
    for _, item in ipairs(result.items) do
        if application[item.component] == true then item.application = true end
        if item.application == nil then
            local classified, problem = application_package(item)
            if classified == nil then return nil, "Classify " .. item.component .. ": " .. tostring(problem) end
            item.application = classified
        end
    end
    return result, nil
end

function M.detail(raw: unknown): (Detail?, string?)
    local request, request_error = M.decode_detail(raw)
    if not request then return nil, request_error end
    local module, module_error = hub.modules.get(request.component, {timeout = M.TIMEOUT_SECONDS})
    if not module then return nil, tostring(module_error) end
    local readme, readme_error = hub.modules.readme(request.component, {timeout = M.TIMEOUT_SECONDS})
    local versions, versions_error = hub.versions.list(request.component,
        {page = request.page, page_size = M.MAX_VERSIONS, include_yanked = true, timeout = M.TIMEOUT_SECONDS})
    if not versions then return nil, tostring(versions_error) end
    return M.decode_detail_result(module, readme, versions, request.component,
        not readme and tostring(readme_error or "Hub README is unavailable") or nil)
end

-- latest is the newest release Hub lists for component.
function M.latest(component: string): (string?, string?)
    local module, module_error = hub.modules.get(component, {timeout = M.TIMEOUT_SECONDS})
    if not module then return nil, tostring(module_error) end
    local item, invalid = decode_item(module)
    if not item then return nil, invalid end
    return item.latest_version, nil
end

-- One page per request. A package's release count is not an admission limit.
function M.available(component: string, page: integer): ({string}?, boolean?, string?)
    local raw, problem = hub.versions.list(component, {page = page, page_size = M.MAX_VERSIONS,
        include_yanked = true, timeout = M.TIMEOUT_SECONDS})
    if not raw then return nil, nil, tostring(problem) end
    local result, invalid = M.decode_versions(raw)
    if not result then return nil, nil, invalid end
    if result.page ~= page then return nil, nil, "Hub returned another version page" end
    local more = page * result.page_size < result.total
    if more and #result.items ~= result.page_size then
        return nil, nil, "version history changed while paging; refresh"
    end
    local selected: {string} = {}
    for _, item in ipairs(result.items) do
        if not item.yanked then selected[#selected + 1] = item.version end
    end
    return selected, more, nil
end

return M
