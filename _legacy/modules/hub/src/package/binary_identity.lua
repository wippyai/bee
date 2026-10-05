-- MIT. Decode Bee root-pack metadata and the native host's executable identity.
local bounds = require("bounds")
local json = require("json")
local semver = require("semver")
local M = {}

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
    if entry.kind ~= "registry.entry" or not meta or meta.type ~= "bee.binary_identity" or not data then
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

function M.read_host(): (Baked?, string?)
    if env == nil then return nil, "host binary identity is unavailable" end
    local native_module_raw, module_error = env.get("bee.env:binary_native_module")
    local native_version_raw, version_error = env.get("bee.env:binary_native_version")
    local modules_raw, modules_error = env.get("bee.env:binary_native_modules")
    local runtime_commit_raw, runtime_error = env.get("bee.env:binary_runtime_commit")
    if module_error or version_error or modules_error or runtime_error then
        return nil, "host binary identity is unavailable"
    end
    local native_module = package_name(native_module_raw)
    local native_version = bounds.line(native_version_raw, 128)
    local runtime_commit = bounds.line(runtime_commit_raw, 64)
    if not native_module or not native_version or not semver.parse(native_version)
        or not runtime_commit or #runtime_commit ~= 40 or not runtime_commit:match("^[0-9a-f]+$") then
        return nil, "host binary identity is invalid"
    end
    local modules_text = bounds.text(modules_raw, 65536)
    if not modules_text then return nil, "host native module manifest is unavailable" end
    local decoded: unknown = json.decode(modules_text)
    local raw_modules = bounds.object(decoded)
    if not raw_modules then return nil, "host native module manifest is invalid" end
    local native_modules: {[string]: string} = {}
    local count = 0
    for raw_name, raw_version in pairs(raw_modules) do
        count = count + 1
        local name = package_name(raw_name)
        local version = bounds.line(raw_version, 128)
        if count > 1024 then return nil, "host native module manifest exceeds its bound" end
        if name and version and semver.parse(version) then native_modules[name] = version end
    end
    if native_modules[native_module] ~= native_version then
        return nil, "host binary native version differs from its module manifest"
    end
    return {native_module = native_module, native_version = native_version,
        native_modules = native_modules, runtime_commit = runtime_commit}, nil
end

function M.read_packages(raw_packages: unknown): (Identity?, string?)
    local packages, packages_error = bounds.dense_list(raw_packages, 512, "resolved Bee packages")
    if not packages then return nil, packages_error end
    for _, raw_package in ipairs(packages) do
        local package = bounds.object(raw_package)
        if package and package.component == "bee/bee" then
            local entries, entries_error = bounds.dense_list(package.entries, 10000, "resolved Bee root entries")
            if not entries then return nil, entries_error end
            for _, raw_entry in ipairs(entries) do
                local entry = bounds.object(raw_entry)
                if entry and entry.id == "bee.env:binary_identity" then return decode_pack_entry(raw_entry) end
            end
        end
    end
    return nil, nil
end

return M
