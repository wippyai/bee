-- MIT. Probe one activated external driver from its validated descriptor.
-- Login checks use metadata and silent exit codes; credential bytes are never read.
local bounds = require("bounds")
local descriptor_codec = require("descriptor")
local driver_resolver = require("driver_resolver")
local env = require("env")
local json = require("json")
local exec = require("exec")
local fs = require("fs")
local locate = require("locate")
local quote = require("quote")
local registry = require("registry")
local resources = require("resources")
local driver_types = require("driver_types")
local probe_capture = require("probe_capture")
local probe_version = require("probe_version")
local login_evidence = require("login_evidence")
local funcs = require("funcs")
local placement_profiles = require("placement_profiles")
local placement_resolver = require("placement_resolver")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
local LOGIN_SOURCE = "bee.env:machine_login_source"

type Platform = {os: string?, arch: string?, compatible: boolean?}
type Descriptor = descriptor_codec.Descriptor
type Cache = {drivers: {[string]: driver_types.LocateResult}, platform: Platform?, platform_checked: boolean}

function M.new_cache(): Cache
    return {drivers = {}, platform = nil, platform_checked = false}
end

local function capture(argv: {string}, timeout_ms: integer?, silent: boolean?): (string?, integer?, string?, boolean?)
    local executor_ref, reference_error = resources.executor()
    if not executor_ref then return nil, nil, reference_error or "host executor is unavailable", false end
    local executor, executor_error = exec.get(executor_ref)
    if not executor then return nil, nil, tostring(executor_error or "host executor is unavailable"), false end
    local command = quote.line(argv)
    if silent then command = quote.line({"sh", "-c", "exec " .. command .. " </dev/null >/dev/null 2>&1"}) end
    local home, home_error = env.get("bee.env:machine_home")
    local environment: {[string]: string} = {}
    if not home_error and type(home) == "string" then environment.HOME = home end
    local proc, command_error = executor:exec(command, {env = environment})
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
        read = function(_self: probe_capture.Stream, size: integer): (unknown, unknown) local value, err = stdout:read(size); return value, err end,
        close = function(_self: probe_capture.Stream): unknown stdout:close(); return nil end,
    }
    local capture_stderr: probe_capture.Stream = {
        read = function(_self: probe_capture.Stream, size: integer): (unknown, unknown) local value, err = stderr:read(size); return value, err end,
        close = function(_self: probe_capture.Stream): unknown stderr:close(); return nil end,
    }
    local output, code, probe_error = probe_capture.capture(capture_process, capture_stdout, capture_stderr,
        function() executor:release() end, timeout_ms, 65536)
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
    return probe_version.read(path, probe, function(argv) return capture(argv, nil, false) end)
end

local function login_exists(path: string, variable: string?, directory: string?): (boolean?, string?)
    local volume = fs.get(LOGIN_SOURCE)
    if not volume then return nil end
    local info, stat_error = volume:stat(path)
    if info then return true end
    if stat_error and stat_error:kind() == errors.NOT_FOUND then return false end
    local reason = tostring(stat_error or "login source could not be inspected"):gsub("[%c]", " "):sub(1, 512)
    if stat_error and stat_error:kind() == errors.PERMISSION_DENIED then return false, reason end
    return nil, reason
end

local function environment_names(): {[string]: boolean}?
    local raw, read_error = env.get("bee.harness.launch:host_environment_names")
    if read_error or type(raw) ~= "string" then return nil end
    local decoded, decode_error = json.decode(raw)
    if decode_error or type(decoded) ~= "table" then return nil end
    local names: {[string]: boolean} = {}
    for _, name in ipairs(decoded) do
        if type(name) ~= "string" then return nil end
        names[name] = true
    end
    return names
end

local function has_locate_facet(pinned: registry.Snapshot, binding: {[string]: unknown}): boolean
    local data = bounds.object(binding.data) or {}
    if type(data.contracts) ~= "table" then return false end
    for _, raw in ipairs(data.contracts) do
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
    return descriptor_codec.find_provider(pinned, provider)
end

local function unsupported(selected: Descriptor, reason: string, platform: Platform?): driver_types.LocateResult
    local result: driver_types.LocateResult = {provider = selected.provider, status = "incompatible",
        executable = {name = selected.executable},
        login = {evidence = "any_of"},
        platform = platform or {}, reason = reason}
    return result
end

local function unknown(provider: string, reason: string): driver_types.LocateResult
    local result: driver_types.LocateResult = {provider = provider, status = "unknown", executable = {name = provider},
        login = {evidence = "not_required"}, platform = {}, reason = reason}
    return result
end

function M.locate(pinned: registry.Snapshot, binding_ref: string, profile_id: string, cache: Cache, placement_profile_ref: string?): driver_types.LocateResult?
    local cache_key = binding_ref .. "\n" .. profile_id .. "\n" .. (placement_profile_ref or "")
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
    cache_key = cache_key .. "\n" .. assert(hash.sha256(assert(canonical.encode(selected))))
    if not placement_profile_ref and cache.drivers[cache_key] then return cache.drivers[cache_key] end
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
    local os_values = type(supported.os) == "table" and supported.os or {}
    local arch_values = type(supported.arch) == "table" and supported.arch or {}
    local compatible: boolean? = nil
    if platform.os and platform.arch then
        compatible = bounds.member(platform.os, os_values) ~= nil and bounds.member(platform.arch, arch_values) ~= nil
    end
    local executable_name = selected.executable
    local executable_ref = "bee.driver." .. provider .. ":executable"
    local configured_path, executable_error = env.get(executable_ref)
    local configured = type(configured_path) == "string" and configured_path ~= ""
    local executable_path = executable_name
    if configured then executable_path = configured_path end
    local executable_present: boolean? = nil
    local version: string? = nil
    local docker = false
    local docker_target: string? = nil
    local function runtime_capture(argv: {string}): (string?, integer?, string?, boolean?)
        if not docker_target then return capture(argv, 3000, false) end
        local args: {string} = {}
        for index, argument in ipairs(argv) do if index > 1 then args[#args + 1] = argument end end
        local raw, err = funcs.call(docker_target, {placement_profile_ref = placement_profile_ref, runtime_name = executable_name, probe_argv = args})
        local reply = not err and bounds.object(raw)
        local value = reply and reply.ok == true and bounds.object(reply.value)
        local output = value and bounds.text(value.probe_output, 131072)
        if not output then return nil, nil, "Docker runtime probe is unavailable", false end
        return output, 0, nil, false
    end
    if placement_profile_ref then
        local placement_profile = placement_profiles.resolve(pinned, placement_profile_ref)
        local placement = placement_profile and placement_resolver.resolve(pinned, placement_profile.profile.placement_binding) or nil
        if placement and placement.placement_kind == "docker" then
            docker = true
            local target = placement.methods.capabilities
            if not target then return unknown(provider, "Docker capabilities route is unavailable") end
            local raw, capability_error = funcs.call(target, {placement_profile_ref = placement_profile_ref, runtime_name = executable_name})
            local reply = not capability_error and bounds.object(raw) or nil
            local value = reply and reply.ok == true and bounds.object(reply.value) or nil
            local image = value and bounds.object(value.image_readiness) or nil
            local network = value and bounds.object(value.network_readiness) or nil
            if network and network.present ~= true and network.provisionable ~= true then
                local result = unknown(provider, bounds.line(network.reason, 1024) or "Docker network readiness is unavailable")
                return result
            end
            if not image or type(image.present) ~= "boolean" or type(image.runtime_present) ~= "boolean" then
                local result = unknown(provider, capability_error and tostring(capability_error) or "Docker runtime readiness is unavailable")
                cache.drivers[cache_key] = result; return result
            end
            if image.present ~= true or image.runtime_present ~= true then
                local result = unknown(provider, bounds.line(image.reason, 1024) or (image.present == true and "Docker image does not declare this runtime artifact" or "Docker runtime image is missing; a registry digest is fetched on first launch"))
                cache.drivers[cache_key] = result; return result
            end
            executable_present = true
            docker_target = target
            local image_digest = bounds.line(image.image_digest, 128)
            if not image_digest then return unknown(provider, "Docker image has no immutable cache identity") end
            cache_key = cache_key .. "\n" .. image_digest
            if cache.drivers[cache_key] then return cache.drivers[cache_key] end
            version = probe_version.read(executable_name, bounds.object(selected.version_probe) or {}, runtime_capture)
            platform = {os = bounds.line(image.os, 32), arch = bounds.line(image.arch, 32)}
            compatible = platform.os ~= nil and platform.arch ~= nil and bounds.member(platform.os, os_values) ~= nil and bounds.member(platform.arch, arch_values) ~= nil
        end
    end
    if not docker and (not executable_error or executable_error:kind() == errors.NOT_FOUND) then
        version, executable_present = executable_version(executable_path, bounds.object(selected.version_probe) or {})
    end
    local names = environment_names()
    local checks = login_evidence.probe(selected.login_evidence, {
        file = login_exists,
        environment = function(name)
            if not names then return nil end
            return names[name] == true
        end,
        status = function(args: {string}, timeout: integer): integer?
            if docker or executable_present ~= true then return nil end
            local argv: {string} = {executable_path}
            for _, arg in ipairs(args) do argv[#argv + 1] = arg end
            local _, code = capture(argv, timeout, true)
            return code
        end,
    })
    local probe = {profile_id = profile_id, configured = true,
        executable = {present = executable_present, version = version}, login_checks = checks,
        platform = {os = platform.os, arch = platform.arch, compatible = compatible}}
    local result, result_error = locate.evaluate({provider = provider, executable = executable_name,
        login_evidence = selected.login_evidence}, probe)
    if not result then
        local fallback = unknown(provider, result_error or "driver locate could not evaluate host facts")
        cache.drivers[cache_key] = fallback
        return fallback
    end
    local option_fields = bounds.object((bounds.object(selected.options) or {}).fields) or {}
    local capabilities: {[string]: locate.Capability} = {}
    local help_cache: {[string]: string} = {}
    for _, raw in pairs(option_fields) do
        local field = bounds.object(raw)
        local path = field and bounds.line(field.path, 128)
        if field and path then
            local support = bounds.object(field.support)
            local help = support and bounds.object(support.help_probe)
            local supported = result.status == "ready"
            local reason: string? = supported and nil or "Installed version and login are not established"
            if supported and help then
                local args = bounds.array(help.argv, 8)
                local flag = bounds.line(help.flag, 128)
                local argv: {string} = {executable_path}
                if args then
                    for _, argument in ipairs(args) do
                        if type(argument) == "string" then argv[#argv + 1] = argument end
                    end
                end
                local key = table.concat(argv, "\n")
                local output = help_cache[key]
                if not output then
                    output = runtime_capture(argv) or ""
                    help_cache[key] = output
                end
                supported = args ~= nil and flag ~= nil and output:find(flag, 1, true) ~= nil
                if not supported then reason = "Installed CLI help does not advertise " .. (flag or path) end
            elseif supported and not (support and support.config_schema_ref) then
                supported = false; reason = "Option has no declared capability evidence"
            end
            local range = support and bounds.line(support.version_range, 32)
            if supported and range then
                local a, b, c = range:match("^>=(%d+)%.(%d+)%.(%d+)$")
                local x, y, z = (version or ""):match("(%d+)%.(%d+)%.(%d+)")
                local wanted = a and tonumber(a) and (assert(tonumber(a)) * 1000000 + assert(tonumber(b)) * 1000 + assert(tonumber(c)))
                local installed = x and tonumber(x) and (assert(tonumber(x)) * 1000000 + assert(tonumber(y)) * 1000 + assert(tonumber(z)))
                if not installed or not wanted or installed < wanted then supported = false; reason = "Installed CLI version does not satisfy " .. range end
            end
            capabilities[path] = {supported = supported, reason = reason}
        end
    end
    result.capabilities = capabilities
    cache.drivers[cache_key] = result
    return result
end

return M
