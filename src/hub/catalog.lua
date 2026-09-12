-- MIT. A small, caller-scoped view of the native Hub catalog.
local hub = require("hub")
local bounds = require("bounds")
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
type Item = {component: string, title: string, description: string, latest_version: string}
type Browse = {items: {Item}, total: integer, page: integer, page_size: integer}
type Version = {version: string, yanked: boolean}
type VersionPage = {items: {Version}, total: integer, page: integer, page_size: integer}
type Detail = {component: string, title: string, description: string, readme: string, versions: {Version}, total_versions: integer, page: integer, page_size: integer}

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

local function dense(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count > maximum then return nil, label .. " exceeds " .. tostring(maximum) .. " items" end
    local items: {unknown} = {}
    for index = 1, count do
        if value[index] == nil then return nil, label .. " must be a dense list" end
        items[index] = value[index]
    end
    return items, nil
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
    return {component = name, title = display_name, description = description, latest_version = latest_version}, nil
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
    local raw_items, items_error = dense(value.items, "Hub catalog items", M.MAX_ITEMS)
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
    local raw_items, items_error = dense(value.items, "Hub versions", M.MAX_VERSIONS)
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

function M.decode_detail_result(module: unknown, readme: unknown, version_response: unknown, requested_component: string): (Detail?, string?)
    local item, item_error = decode_item(module)
    if not item then return nil, item_error end
    if item.component ~= requested_component then return nil, "Hub returned another component" end
    local readme_value = bounds.object(readme)
    if not readme_value then return nil, "Hub README must be an object" end
    local content = bounds.text(readme_value.content, M.MAX_README_BYTES)
    if not content then return nil, "Hub README has invalid content" end
    local versions, versions_error = M.decode_versions(version_response)
    if not versions then return nil, versions_error end
    return {
        component = item.component,
        title = item.title,
        description = item.description,
        readme = content,
        versions = versions.items,
        total_versions = versions.total, page = versions.page, page_size = versions.page_size,
    }, nil
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
    return result, nil
end

function M.detail(raw: unknown): (Detail?, string?)
    local request, request_error = M.decode_detail(raw)
    if not request then return nil, request_error end
    local module, module_error = hub.modules.get(request.component, {timeout = M.TIMEOUT_SECONDS})
    if not module then return nil, tostring(module_error) end
    local readme, readme_error = hub.modules.readme(request.component, {timeout = M.TIMEOUT_SECONDS})
    if not readme then return nil, tostring(readme_error) end
    local versions, versions_error = hub.versions.list(request.component,
        {page = request.page, page_size = M.MAX_VERSIONS, include_yanked = true, timeout = M.TIMEOUT_SECONDS})
    if not versions then return nil, tostring(versions_error) end
    return M.decode_detail_result(module, readme, versions, request.component)
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
