-- MIT. Probe one activated external driver from its validated descriptor.
-- Login evidence is a metadata existence check; credential bytes are never read.
local bounds = require("bounds")
local descriptor_codec = require("descriptor")
local driver_resolver = require("driver_resolver")
local env = require("env")
local exec = require("exec")
local fs = require("fs")
local locate = require("locate")
local quote = require("quote")
local registry = require("registry")
local resources = require("resources")
local driver_types = require("driver_types")
local probe_capture = require("probe_capture")
local probe_version = require("probe_version")
local M = {}
local LOGIN_SOURCE = "bee.env:machine_login_source"

type Platform = {os: string?, arch: string?, compatible: boolean?}
type Descriptor = {[string]: unknown}
type Cache = {drivers: {[string]: driver_types.LocateResult}, platform: Platform?, platform_checked: boolean}

function M.new_cache(): Cache
    return {drivers = {}, platform = nil, platform_checked = false}
end

local function capture(argv: {string}): (string?, integer?, string?, boolean?)
    local executor_ref, reference_error = resources.executor()
    if not executor_ref then return nil, nil, reference_error or "host executor is unavailable", false end
    local executor, executor_error = exec.get(executor_ref)
    if not executor then return nil, nil, tostring(executor_error or "host executor is unavailable"), false end
    local proc, command_error = executor:exec(quote.line(argv))
    if not proc then
        executor:release()
        local missing = command_error ~= nil and command_error:kind() == errors.NOT_FOUND
        return nil, nil, tostring(command_error or "host probe could not start"), missing
    end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    local started, start_error = proc:start()
    if not started then
        proc:close(true); stdout:close(); stderr:close(); executor:release()
        local missing = start_error ~= nil and start_error:kind() == errors.NOT_FOUND
        return nil, nil, tostring(start_error or "host probe could not start"), missing
    end
    local capture_process: probe_capture.Process = {
        wait = function(_self) return proc:wait() end,
        close = function(_self, force) proc:close(force) end,
    }
    local capture_stdout: probe_capture.Stream = {
        read = function(_self, size) return stdout:read(size) end,
        close = function(_self) stdout:close() end,
    }
    local capture_stderr: probe_capture.Stream = {
        read = function(_self, size) return stderr:read(size) end,
        close = function(_self) stderr:close() end,
    }
    local output, code, probe_error = probe_capture.capture(capture_process, capture_stdout, capture_stderr,
        function() executor:release() end)
    if probe_error then return nil, nil, probe_error, false end
    return output, code, nil, false
end

local function platform_probe(cache: Cache): Platform
    if cache.platform_checked then return cache.platform or {} end
    cache.platform_checked = true
    local output, code = capture({"uname", "-s", "-m"})
    if not output or code ~= 0 then return {} end
    local os_name, arch = output:match("^%s*([^%s]+)%s+([^%s]+)")
    if not os_name or not arch then return {} end
    local platform: Platform = {os = os_name:lower(), arch = arch:lower()}
    cache.platform = platform
    return platform
end

local function executable_version(path: string, probe: {[string]: unknown}): (string?, boolean?)
    return probe_version.read(path, probe, capture)
end

local function login_exists(path: string): boolean?
    local volume, volume_error = fs.get(LOGIN_SOURCE)
    if not volume then return nil end
    local info, stat_error = volume:stat(path)
    if info then return true end
    if stat_error and stat_error:kind() == errors.NOT_FOUND then return false end
    return nil
end

local function has_locate_facet(pinned: registry.Snapshot, binding: {[string]: unknown}): boolean
    local data = bounds.object(binding.data) or {}
    if type(data.contracts) ~= "table" then return false end
    for _, raw in ipairs(data.contracts :: {unknown}) do
        local contract = bounds.object(raw)
        if contract and contract.contract == "bee.driver:locate_facet" then
            local methods = bounds.object(contract.methods) or {}
            local method = bounds.id(methods.locate)
            local entry = nil
            local entry_error = nil
            if method then entry, entry_error = pinned:get(method) end
            local target = bounds.object(entry)
            return not entry_error and target ~= nil and target.kind == "function.lua"
        end
    end
    return false
end

local function selected_descriptor(pinned: registry.Snapshot, provider: string): (Descriptor?, string?)
    local found, find_error = pinned:find({["meta.type"] = descriptor_codec.TYPE})
    if find_error or not found then return nil, "CLI descriptors are unavailable" end
    local match: Descriptor? = nil
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local meta = entry and bounds.object(entry.meta) or nil
        if entry and entry.kind == "registry.entry" and meta and meta.type == descriptor_codec.TYPE then
            local decoded, decode_error = descriptor_codec.decode(entry.data)
            if not decoded then return nil, tostring(decode_error or "CLI descriptor is invalid") end
            if decoded.provider == provider then
                if match then return nil, "multiple CLI descriptors name driver " .. provider end
                match = decoded :: Descriptor
            end
        end
    end
    return match, nil
end

local function unsupported(selected: Descriptor, reason: string, platform: Platform?): driver_types.LocateResult
    local login = bounds.object(selected.login_evidence) or {}
    local login_path = bounds.text(login.path, 512)
    local result: driver_types.LocateResult = {provider = selected.provider :: string, status = "incompatible",
        executable = {name = selected.executable :: string},
        login = {evidence = "file_exists", path = login_path},
        platform = platform or {}, reason = reason}
    return result
end

local function unknown(provider: string, reason: string): driver_types.LocateResult
    local result: driver_types.LocateResult = {provider = provider, status = "unknown", executable = {name = provider},
        login = {evidence = "not_required"}, platform = {}, reason = reason}
    return result
end

function M.locate(pinned: registry.Snapshot, binding_ref: string, profile_id: string, cache: Cache): driver_types.LocateResult?
    local cache_key = binding_ref .. "\n" .. profile_id
    if cache.drivers[cache_key] then return cache.drivers[cache_key] end
    local binding_raw, binding_error = pinned:get(binding_ref)
    local binding = not binding_error and bounds.object(binding_raw) or nil
    local meta = binding and bounds.object(binding.meta) or nil
    local provider = meta and bounds.id(meta.driver_id) or nil
    if not binding or not provider then return nil end
    local active, active_error = driver_resolver.active(pinned)
    if not active then
        local result = unknown(provider, active_error or "driver activation could not be read")
        cache.drivers[cache_key] = result
        return result
    end
    if active[binding_ref] ~= true then return nil end
    local selected, descriptor_error = selected_descriptor(pinned, provider)
    if not selected then
        if descriptor_error then
            local result = unknown(provider, descriptor_error)
            cache.drivers[cache_key] = result
            return result
        end
        return nil
    end
    if not has_locate_facet(pinned, binding) then
        local result = unsupported(selected, "the active driver does not bind bee.driver:locate_facet", nil)
        cache.drivers[cache_key] = result
        return result
    end
    local options = bounds.object(selected.options) or {}
    if not bounds.member(profile_id, options.profiles) then
        local result = unsupported(selected, "the CLI descriptor does not admit profile " .. profile_id, nil)
        cache.drivers[cache_key] = result
        return result
    end

    local platform = platform_probe(cache)
    local supported = bounds.object(selected.platform) or {}
    local os_values = type(supported.os) == "table" and supported.os :: {string} or {}
    local arch_values = type(supported.arch) == "table" and supported.arch :: {string} or {}
    local compatible: boolean? = nil
    if platform.os and platform.arch then
        compatible = bounds.member(platform.os, os_values) ~= nil and bounds.member(platform.arch, arch_values) ~= nil
    end
    local executable_name = selected.executable :: string
    local executable_ref = "bee.driver." .. provider .. ":executable"
    local configured_path, executable_error = env.get(executable_ref)
    local configured = type(configured_path) == "string" and configured_path ~= ""
    local executable_path = configured and configured_path or executable_name
    local executable_present: boolean? = nil
    local version: string? = nil
    if not executable_error or executable_error:kind() == errors.NOT_FOUND then
        version, executable_present = executable_version(executable_path, bounds.object(selected.version_probe) or {})
    end
    local evidence = bounds.object(selected.login_evidence) or {}
    local login_path = bounds.text(evidence.path, 512) or ""
    local login_file_exists: boolean? = nil
    if login_path ~= "" then login_file_exists = login_exists(login_path) end
    local probe = {profile_id = profile_id, configured = true,
        executable = {present = executable_present, version = version},
        login_file_exists = login_file_exists,
        platform = {os = platform.os, arch = platform.arch, compatible = compatible}}
    local result, result_error = locate.evaluate({provider = provider, executable = executable_name, login_path = login_path}, probe)
    if not result then
        local fallback = unknown(provider, result_error or "driver locate could not evaluate host facts")
        cache.drivers[cache_key] = fallback
        return fallback
    end
    cache.drivers[cache_key] = result :: driver_types.LocateResult
    return result :: driver_types.LocateResult
end

return M
