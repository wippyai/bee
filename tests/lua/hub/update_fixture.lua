-- MIT.
local hub = require("hub")
local registry = require("registry")
local ctx = require("ctx")
local store = require("store")
local identity = require("identity")
local M = {}
type Options = {page: integer?, page_size: integer?, include_data: boolean?, kind: string?}
type Package = {version: string, digest: string, entries: (Package, Options?) -> (unknown, string?),
    metadata: (Package) -> (unknown, string?), close: (Package) -> (boolean, string?)}
type Revision = {id: (Revision) -> integer}
type Snapshot = {state: (Snapshot) -> (unknown, string?), version: (Snapshot) -> Revision}
local function scenario(): string?
    local selected = ctx.get("bee.test.hub.updates")
    return type(selected) == "string" and selected or nil
end
local function record(key: string): integer
    local cache = assert(store.get("bee.tests.hub:catalog_decodes"))
    local value = cache:get("updates:" .. key)
    local count = type(value) == "number" and math.floor(value) or 0
    assert(cache:set("updates:" .. key, count + 1))
    cache:release()
    return count + 1
end
function M.count(key: string): integer
    local cache = assert(store.get("bee.tests.hub:catalog_decodes"))
    local value = cache:get("updates:" .. key)
    cache:release()
    return type(value) == "number" and math.floor(value) or 0
end
function M.snapshot(): (Snapshot?, string?)
    if not scenario() then
        local value, problem = registry.snapshot()
        if not value then return nil, tostring(problem) end
        return {state = function(_: Snapshot): (unknown, string?)
            local state, err = value:state(); return state, err and tostring(err) or nil
        end, version = function(_: Snapshot): Revision
            return {id = function(_: Revision): integer return math.floor(value:version():id()) end}
        end}, nil
    end
    return {state = function(_: Snapshot): (unknown, string?)
        return {entries = {{id = "bee:deployment", kind = "ns.dependency", meta = {}, registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.2.0-alpha.5", parameters = {}}}},
            resolution = {modules = {{name = "bee/bee", version = "0.2.0-alpha.5", digest = string.rep("a", 64)}},
                lock = {root_module = "bee/bee", modules = {{name = "bee/bee", version = "0.2.0-alpha.5"}}}}}, nil
    end, version = function(_: Snapshot): Revision return {id = function(_: Revision): integer
        if scenario() == "native" then return 701 end
        if scenario() == "packset" then return 702 end
        return 700
    end} end}, nil
end
local function listed(): {{version: string, yanked: boolean}}
    local mode = scenario()
    if mode == "equal" then return {{version = "0.2.0-alpha.5", yanked = false}} end
    local items = {{version = "0.2.0-selfupdate.1", yanked = false}}
    if mode ~= "blocked" then items[#items + 1] = {version = "0.2.0-alpha.7", yanked = false} end
    items[#items + 1] = {version = "0.2.0-alpha.5", yanked = false}
    if mode == "pages" then
        for index = 1, 99 do table.insert(items, 2, {version = "0.1.0-alpha." .. tostring(index), yanked = false}) end
    end
    if mode == "yanked" then items[2].yanked = true end
    return items
end
M.versions = {
    list = function(component: string, options: Options): (unknown, string?)
        local mode = scenario()
        if not mode then
            local value, problem = hub.versions.list(component, options)
            return value, problem and tostring(problem) or nil
        end
        assert(component == "bee/bee" and options.page_size == 100)
        record(mode .. ":lists")
        local all = listed()
        local items: {unknown} = {}
        local page = options.page or 1
        for index = (page - 1) * 100 + 1, math.min(page * 100, #all) do items[#items + 1] = all[index] end
        return {items = items, total = #all, page = page, page_size = 100}, nil
    end,
    open = function(component: string, version: string, options: unknown): (Package?, string?)
        local mode = scenario()
        if not mode then
            local value, problem = hub.versions.open(component, version, options)
            if not value then return nil, tostring(problem) end
            return {version = value.version, digest = value.digest,
                entries = function(_: Package, opts: Options?): (unknown, string?)
                    local result, err = value:entries({include_data = opts and opts.include_data == true, kind = opts and opts.kind})
                    return result, err and tostring(err) or nil
                end,
                metadata = function(_: Package): (unknown, string?)
                    local result, err = value:metadata(); return result, err and tostring(err) or nil
                end,
                close = function(_: Package): (boolean, string?)
                    local result, err = value:close(); return result, err and tostring(err) or nil
                end}, nil
        end
        assert(component == "bee/bee" or component == "fixture/native")
        record(mode .. ":opens")
        local baked = assert(identity.read_baked())
        local incompatible = version == "0.2.0-selfupdate.1"
        return {version = version, digest = string.rep(incompatible and "b" or "c", 64),
            entries = function(_: Package, _opts: Options?): (unknown, string?)
                if component == "fixture/native" then
                    return {{id = "fixture.native:namespace", kind = "ns.definition", meta = {
                        native_requirements = {{package = baked.native_module, version = "9.0.0"}}}, data = {}}}, nil
                end
                local entries: {unknown} = {{id = "bee.env.identity:binary_identity", kind = "registry.entry", meta = {type = identity.TYPE},
                    data = {version = version, build = "fixture", source = "fixture", source_revision = "fixture",
                        runtime = "fixture", runtime_commit = incompatible and mode ~= "native" and mode ~= "packset" and "v0.1.0" or baked.runtime_commit,
                        native = baked.native_module, native_version = baked.native_version, website = "https://example.test",
                        native_components = {{package = baked.native_module,
                            version = incompatible and mode == "native" and "9.0.0" or baked.native_version}}}}}
                if incompatible and mode == "packset" then entries[#entries + 1] = {id = "bee:fixture_native", kind = "ns.dependency",
                    meta = {}, data = {component = "fixture/native", version = "1.0.0", parameters = {}}} end
                return entries, nil
            end,
            metadata = function(_: Package): (unknown, string?) return {}, nil end,
            close = function(_: Package): (boolean, string?) record(mode .. ":closes"); return true, nil end}, nil
    end,
}
M.modules = {get = function(component: string, options: unknown): (unknown, string?)
    if scenario() then
        return {full_name = component, display_name = "Bee", description = "",
            latest_version = scenario() == "equal" and "0.2.0-alpha.5" or "0.2.0-selfupdate.1"}, nil
    end
    local value, problem = hub.modules.get(component, options)
    return value, problem and tostring(problem) or nil
end, list = hub.modules.list, search = hub.modules.search, readme = hub.modules.readme}
return M
