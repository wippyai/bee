-- MIT.
local hub = require("hub")
local store = require("store")
local M = {}
type Options = {include_data: boolean?, kind: string?}
type Package = {digest: string, metadata: (Package) -> (unknown, string?), entries: (Package, Options?) -> (unknown, string?), close: (Package) -> (boolean, string?)}
local function record(key: string, value: unknown?): unknown
    local cache = assert(store.get("bee.tests.hub:catalog_decodes"))
    if value ~= nil then assert(cache:set(key, value)) end
    local result = cache:get(key)
    cache:release()
    return result
end
function M.select(digest: string, mode: string?)
    record("digest", digest)
    record("mode", mode or "entries")
end
function M.count(): integer
    local value = record("decodes")
    return type(value) == "number" and math.floor(value) or 0
end
local function open(component: string, version: string, options: unknown): (Package?, string?)
    if component == "fixture/classification" then
        local digest = record("digest")
        return {digest = type(digest) == "string" and digest or string.rep("a", 64),
            metadata = function(_self: Package): (unknown, string?)
                return record("mode") == "metadata" and {type = "application"} or {}, nil
            end,
            entries = function(_self: Package, opts: Options?): (unknown, string?)
                assert(opts and opts.include_data == false and opts.kind == "process.lua")
                record("decodes", M.count() + 1)
                if record("mode") == "library" then return {}, nil end
                return {{id = "fixture:app", kind = "process.lua", meta = {type = "bee.app"}}}, nil
            end,
            close = function(_self: Package): (boolean, string?) return true, nil end}, nil
    end
    local package, problem = hub.versions.open(component, version, options)
    if not package then return nil, tostring(problem) end
    return {digest = package.digest,
        metadata = function(_self: Package): (unknown, string?)
            local value, problem = package:metadata()
            return value, problem and tostring(problem) or nil
        end,
        entries = function(_self: Package, opts: Options?): (unknown, string?)
            local selected = opts or {}
            local value, problem = package:entries({include_data = selected.include_data == true, kind = selected.kind or "process.lua"})
            return value, problem and tostring(problem) or nil
        end,
        close = function(_self: Package): (boolean, string?)
            local value, problem = package:close()
            return value, problem and tostring(problem) or nil
        end}, nil
end
M.versions = {open = open, list = hub.versions.list}
M.modules = {get = hub.modules.get, readme = hub.modules.readme, list = hub.modules.list,
    search = function(query: string, options: unknown): (unknown, string?)
        if query == "fixture-classification" then
            return {items = {{full_name = "fixture/classification", display_name = "Fixture", description = "", latest_version = "1.0.0"}},
                total = 1, page = 1, page_size = 50}, nil
        end
        local value, problem = hub.modules.search(query, options)
        return value, problem and tostring(problem) or nil
    end}
return M
