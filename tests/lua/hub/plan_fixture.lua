-- MIT. Plan tests use a pure artifact source; no Hub or registry writer runs.
local test = require("test")
local plan = require("plan")
local review = require("review")
local graph = require("graph")
local inspect = require("inspect")
local requirements = require("requirements")
local identity_decoder = require("identity_decoder")

local function root(component: string, version: string): {[string]: unknown}
    local id, problem = plan.root_id(component)
    if not id then error(problem or "cannot make root id") end
    return {id = id, kind = "ns.dependency", meta = {type = "bee.hub_dependency"}, registry = {owner = "", root = true},
        data = {component = component, version = version, parameters = {}}}
end

local function state(entries: {unknown}, modules: {unknown}?): {[string]: unknown}
    local result: {[string]: unknown} = {entries = entries}
    if modules then result.resolution = {modules = modules} end
    return result
end

local function binary_identity(package_name: string, version: string): inspect.Entry
    return {id = "bee.env.identity:binary_identity", kind = "registry.entry", registry = {owner = "bee/bee"},
        meta = {type = "bee.binary_identity"}, data = {version = "0.1.0", build = "revision",
            source = "https://example.test/bee", source_revision = "revision", runtime = "https://example.test/runtime",
            runtime_commit = "runtime-commit", native = "github.com/wippyai/bee/native", native_version = version,
            website = "https://example.test", native_components = {{package = package_name, version = version}}}}
end

local function baked_identity(version: string, runtime_commit: string?): {native_module: string, native_version: string,
    native_modules: {[string]: string}, runtime_commit: string}
    local module = "github.com/wippyai/bee/native"
    return {native_module = module, native_version = version, native_modules = {[module] = version},
        runtime_commit = runtime_commit or "runtime-commit"}
end

local function package(name: string, version: string, digest: string, entries: {inspect.Entry}?,
    holes: requirements.Result?): inspect.Inspection
    local selected: requirements.Result = assert(requirements.read(entries or {}, {}))
    if holes then selected = holes end
    return {component = name, version = version, digest = string.rep(digest, 64),
        entries = entries or {}, requirements = selected, next_offset = nil, eof = true}
end

local function source(items: {[string]: inspect.Inspection}): graph.Source
    return {
        versions = function(component: string, _: integer): ({string}?, boolean?, string?)
            local result: {string} = {}
            for _, item in pairs(items) do
                if item.component == component then result[#result + 1] = item.version end
            end
            return result, false, nil
        end,
        artifact = function(component: string, version: string): (inspect.Inspection?, string?)
            local found = items[component .. "@" .. version]
            if not found then return nil, "missing artifact" end
            return found, nil
        end,
    }
end

local function request(raw: unknown): plan.Request
    local decoded, problem = plan.decode(raw)
    if not decoded then error(problem or "cannot decode request") end
    return decoded
end

local function module_for(items: {plan.Module}, component: string): plan.Module?
    for _, item in ipairs(items) do
        if type(item) == "table" and item.component == component then return item end
    end
    return nil
end


return {root = root, state = state, binary_identity = binary_identity, baked_identity = baked_identity, package = package, source = source, request = request, module_for = module_for}
