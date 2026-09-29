-- MIT. Normalize host-probed driver availability without touching credentials.
local bounds = require("bounds")
local M = {}
local STATUSES = {"ready", "missing", "unconfigured", "incompatible", "unknown"}

type Spec = {provider: string, executable: string, login_path: string?}
type Request = {profile_id: string, configured: boolean, executable: {[string]: unknown}?, login_file_exists: boolean?,
    platform: {[string]: unknown}?, checked_at: string?}
type LocateStatus = "ready" | "missing" | "unconfigured" | "incompatible" | "unknown"
type Result = {provider: string, status: LocateStatus,
    executable: {name: string, present: boolean?, version: string?},
    login: {evidence: "file_exists" | "not_required", path: string?, exists: boolean?},
    platform: {os: string?, arch: string?, compatible: boolean?}, checked_at: string?, reason: string?}

local function safe_relative(path: string?): boolean
    if path == nil then return true end
    if path == "" or path:sub(1, 1) == "/" or path:find("[%z\\\\]") then return false end
    for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
    return true
end

function M.evaluate(spec: Spec, raw: unknown): (Result?, string?)
    if not bounds.id(spec.provider) or not bounds.id(spec.executable) or not safe_relative(spec.login_path) then
        return nil, "driver locate specification is malformed"
    end
    local object = bounds.object(raw)
    if not object then return nil, "locate probe must be an object" end
    local extra = bounds.fields(object, {"profile_id", "configured", "executable", "login_file_exists", "platform", "checked_at"})
    if extra then return nil, "locate probe: " .. extra end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "locate probe profile_id is invalid" end
    if type(object.configured) ~= "boolean" then return nil, "locate probe configured must be boolean" end

    local executable: {[string]: unknown} = {}
    if object.executable ~= nil then
        local raw_executable = bounds.object(object.executable)
        if not raw_executable then return nil, "locate probe executable must be an object" end
        local executable_extra = bounds.fields(raw_executable, {"present", "version"})
        if executable_extra then return nil, "locate probe executable: " .. executable_extra end
        if raw_executable.present ~= nil and type(raw_executable.present) ~= "boolean" then
            return nil, "locate probe executable.present must be boolean"
        end
        if raw_executable.version ~= nil then
            local version = bounds.text(raw_executable.version, 128)
            if not version or version == "" or version:find("[%c]") then return nil, "locate probe executable.version is invalid" end
            executable.version = version
        end
        executable.present = raw_executable.present
    end

    local platform: {[string]: unknown} = {}
    if object.platform ~= nil then
        local raw_platform = bounds.object(object.platform)
        if not raw_platform then return nil, "locate probe platform must be an object" end
        local platform_extra = bounds.fields(raw_platform, {"os", "arch", "compatible"})
        if platform_extra then return nil, "locate probe platform: " .. platform_extra end
        for _, field in ipairs({"os", "arch"}) do
            if raw_platform[field] ~= nil then
                local value = bounds.id(raw_platform[field])
                if not value then return nil, "locate probe platform." .. field .. " is invalid" end
                platform[field] = value
            end
        end
        if raw_platform.compatible ~= nil and type(raw_platform.compatible) ~= "boolean" then
            return nil, "locate probe platform.compatible must be boolean"
        end
        platform.compatible = raw_platform.compatible
    end

    if spec.login_path and object.login_file_exists ~= nil and type(object.login_file_exists) ~= "boolean" then
        return nil, "locate probe login_file_exists must be boolean"
    end
    if not spec.login_path and object.login_file_exists ~= nil then return nil, "this driver does not use login-file evidence" end
    local checked_at: string? = nil
    if object.checked_at ~= nil then
        checked_at = bounds.text(object.checked_at, 64)
        if not checked_at or checked_at:find("[%c]") then return nil, "locate probe checked_at is invalid" end
    end

    local status: LocateStatus = "unknown"
    local reason: string? = nil
    if object.configured == false then
        status, reason = "unconfigured", "no executable is configured for this driver"
    elseif platform.compatible == false then
        status, reason = "incompatible", "the target platform is not supported by this driver"
    elseif executable.present == false then
        status, reason = "missing", "the configured executable is absent"
    elseif executable.present == nil or executable.version == nil or platform.os == nil or platform.arch == nil or platform.compatible == nil then
        status, reason = "unknown", "the host probe did not establish executable version and platform compatibility"
    elseif spec.login_path and object.login_file_exists == nil then
        status, reason = "unknown", "login-file existence was not checked"
    elseif spec.login_path and object.login_file_exists == false then
        status, reason = "unconfigured", "the provider login file is absent"
    else
        status = "ready"
        if spec.login_path then reason = "the provider login file exists; its contents and validity were not checked" end
    end

    local login: Result["login"]
    if spec.login_path then
        login = {evidence = "file_exists", path = spec.login_path, exists = object.login_file_exists}
    else
        login = {evidence = "not_required", exists = true}
    end
    local result_platform: Result["platform"] = {os = platform.os :: string?, arch = platform.arch :: string?, compatible = platform.compatible :: boolean?}
    local result: Result = {provider = spec.provider, status = status,
        executable = {name = spec.executable, present = executable.present, version = executable.version},
        login = login, platform = result_platform, checked_at = checked_at, reason = reason}
    return result, nil
end

function M.status(value: unknown): string?
    return bounds.member(value, STATUSES)
end

function M.decode(raw: unknown): (Result?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "locate result must be an object" end
    local extra = bounds.fields(object, {"provider", "status", "executable", "login", "platform", "checked_at", "reason"})
    if extra then return nil, "locate result: " .. extra end
    local provider = bounds.id(object.provider)
    local status = M.status(object.status)
    if not provider or not status then return nil, "locate result identity is invalid" end
    local raw_executable = bounds.object(object.executable)
    if not raw_executable then return nil, "locate result executable must be an object" end
    if bounds.fields(raw_executable, {"name", "present", "version"}) then return nil, "locate result executable has unknown fields" end
    local executable_name = bounds.id(raw_executable.name)
    if not executable_name then return nil, "locate result executable.name is invalid" end
    if raw_executable.present ~= nil and type(raw_executable.present) ~= "boolean" then return nil, "locate result executable.present must be boolean" end
    local executable_version: string? = nil
    if raw_executable.version ~= nil then
        executable_version = bounds.text(raw_executable.version, 128)
        if not executable_version or executable_version == "" or executable_version:find("[%c]") then return nil, "locate result executable.version is invalid" end
    end
    local raw_login = bounds.object(object.login)
    if not raw_login then return nil, "locate result login must be an object" end
    if bounds.fields(raw_login, {"evidence", "path", "exists"}) then return nil, "locate result login has unknown fields" end
    local login_evidence = bounds.member(raw_login.evidence, {"file_exists", "not_required"})
    if not login_evidence then return nil, "locate result login.evidence is invalid" end
    local login_path: string? = nil
    if raw_login.path ~= nil then
        login_path = bounds.text(raw_login.path, 512)
        if not login_path or not safe_relative(login_path) then return nil, "locate result login.path is invalid" end
    end
    if raw_login.exists ~= nil and type(raw_login.exists) ~= "boolean" then return nil, "locate result login.exists must be boolean" end
    if login_evidence == "file_exists" and not login_path then return nil, "locate result login.path is required for file evidence" end
    if login_evidence == "not_required" and login_path ~= nil then return nil, "locate result login.path is unexpected" end
    local raw_platform = bounds.object(object.platform)
    if not raw_platform then return nil, "locate result platform must be an object" end
    if bounds.fields(raw_platform, {"os", "arch", "compatible"}) then return nil, "locate result platform has unknown fields" end
    local platform_os = raw_platform.os ~= nil and bounds.id(raw_platform.os) or nil
    local platform_arch = raw_platform.arch ~= nil and bounds.id(raw_platform.arch) or nil
    if raw_platform.os ~= nil and not platform_os then return nil, "locate result platform.os is invalid" end
    if raw_platform.arch ~= nil and not platform_arch then return nil, "locate result platform.arch is invalid" end
    if raw_platform.compatible ~= nil and type(raw_platform.compatible) ~= "boolean" then return nil, "locate result platform.compatible must be boolean" end
    local checked_at: string? = nil
    if object.checked_at ~= nil then
        checked_at = bounds.text(object.checked_at, 64)
        if not checked_at or checked_at:find("[%c]") then return nil, "locate result checked_at is invalid" end
    end
    local reason: string? = nil
    if object.reason ~= nil then
        reason = bounds.text(object.reason, 512)
        if not reason or reason:find("[%c]") then return nil, "locate result reason is invalid" end
    end
    local evidence_kind: "file_exists" | "not_required"
    if login_evidence == "file_exists" then evidence_kind = "file_exists" else evidence_kind = "not_required" end
    local decoded: Result = {provider = provider, status = status :: LocateStatus,
        executable = {name = executable_name, present = raw_executable.present :: boolean?, version = executable_version},
        login = {evidence = evidence_kind, path = login_path, exists = raw_login.exists :: boolean?},
        platform = {os = platform_os, arch = platform_arch, compatible = raw_platform.compatible :: boolean?},
        checked_at = checked_at, reason = reason}
    return decoded, nil
end

return M
