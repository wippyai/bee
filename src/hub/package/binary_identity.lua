-- MIT. Decode the binary identity a Bee root pack declares and the shape of
-- the running executable's identity.
local bounds = require("bounds")
local limits = require("limits")
local semver = require("semver")
local json = require("json")
local env = require("env")
local M = {}
-- TYPE is the registry type of the entry a Bee pack carries to name the
-- native binary it was built with.
M.TYPE = "bee.binary_identity"

type NativeComponent = {package: string, version: string}
type Identity = {version: string, build: string, source: string, source_revision: string, runtime: string,
    runtime_commit: string, native: string, native_version: string, website: string, native_components: {NativeComponent}}
type Baked = {native_module: string, native_version: string, native_modules: {[string]: string}, runtime_commit: string}

local function package_name(raw: unknown): string?
    local value = bounds.line(raw, 256)
    if not value or not value:match("^[%w_./-]+$") then return nil end
    return value
end

local function decode_pack_entry(raw_entry: unknown): (Identity?, string?)
    local entry = bounds.object(raw_entry)
    if not entry then return nil, "Bee pack binary identity entry is invalid" end
    local meta, data = bounds.object(entry.meta), bounds.object(entry.data)
    if entry.kind ~= "registry.entry" or not meta or meta.type ~= M.TYPE or not data then
        return nil, "host binary identity is invalid"
    end
    local extra = bounds.fields(data, {"version", "build", "source", "source_revision", "runtime", "runtime_commit",
        "native", "native_version", "website", "native_components"})
    if extra then return nil, "host binary identity has unsupported fields" end
    local version = bounds.text(data.version, 512)
    local build = bounds.text(data.build, 512)
    local source = bounds.text(data.source, 512)
    local source_revision = bounds.text(data.source_revision, 512)
    local runtime = bounds.text(data.runtime, 512)
    local runtime_commit = bounds.text(data.runtime_commit, 512)
    local native = bounds.text(data.native, 512)
    local native_version = bounds.text(data.native_version, 512)
    local website = bounds.text(data.website, 512)
    if not version or not build or not source or not source_revision or not runtime or not runtime_commit or not native or not native_version or not website then
        return nil, "host binary identity is incomplete"
    end
    local rows, rows_error = bounds.dense_list(data.native_components, 128, "host native components")
    if not rows then return nil, rows_error end
    local components: {NativeComponent} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_component in ipairs(rows) do
        local component = bounds.object(raw_component)
        local name = component and package_name(component.package)
        local version = component and bounds.line(component.version, 128)
        if not name or not version or not semver.parse(version) or seen[name] then
            return nil, "host binary identity contains an invalid native component"
        end
        if bounds.fields(component, {"package", "version"}) then
            return nil, "host binary identity contains unsupported native component fields"
        end
        components[#components + 1] = {package = name, version = version}
        seen[name] = true
    end
    return {version = version, build = build, source = source,
        source_revision = source_revision, runtime = runtime, runtime_commit = runtime_commit,
        native = native, native_version = native_version, website = website,
        native_components = components}, nil
end

function M.decode_baked(raw: unknown): (Baked?, string?)
    if type(raw) ~= "string" or #raw > 262144 then return nil, "running binary identity is invalid" end
    local decoded, problem = json.decode(raw)
    if problem then return nil, "running binary identity is invalid JSON" end
    local value = bounds.object(decoded)
    if not value or bounds.fields(value, {"native_module", "native_version", "native_modules", "runtime_commit"}) then
        return nil, "running binary identity is invalid"
    end
    local native_module = package_name(value.native_module)
    local native_version = bounds.line(value.native_version, 128)
    local runtime_commit = bounds.line(value.runtime_commit, 128)
    local modules = bounds.object(value.native_modules)
    if not native_module or not native_version or not semver.parse(native_version) or not runtime_commit
        or not semver.parse(runtime_commit) or not modules then return nil, "running binary identity is incomplete" end
    local native_modules: {[string]: string} = {}
    local count = 0
    for name, raw_version in pairs(modules) do
        local version = bounds.line(raw_version, 128)
        count = count + 1
        if count > 1024 or not package_name(name) or not version or not semver.parse(version) then
            return nil, "running binary identity has invalid modules"
        end
        native_modules[name] = version
    end
    if native_modules[native_module] ~= native_version then return nil, "running binary identity is inconsistent" end
    return {native_module = native_module, native_version = native_version, native_modules = native_modules,
        runtime_commit = runtime_commit}, nil
end

function M.read_baked(): (Baked?, string?)
    local raw, problem = env.get("bee.env:running_binary_identity")
    if not raw then return nil, tostring(problem) end
    return M.decode_baked(raw)
end

function M.read_packages(raw_packages: unknown): (Identity?, string?)
    local packages, packages_error = bounds.dense_list(raw_packages, 512, "resolved Bee packages")
    if not packages then return nil, packages_error end
    for _, raw_package in ipairs(packages) do
        local package = bounds.object(raw_package)
        if package and package.component == "bee/bee" then
            local entries, entries_error = bounds.dense_list(package.entries, limits.MAX_PACKAGE_ENTRIES, "resolved Bee root entries")
            if not entries then return nil, entries_error end
            for _, raw_entry in ipairs(entries) do
                local entry = bounds.object(raw_entry)
                local meta = entry and bounds.object(entry.meta)
                if meta and meta.type == M.TYPE then return decode_pack_entry(raw_entry) end
            end
        end
    end
    return nil, nil
end

return M
