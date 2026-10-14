-- MIT. Bounded declarations and observations of alternative login sources.
local bounds = require("bounds")
local M = {}

type File = {kind: "file_exists", paths: {string}, variable: string?, directory: string?}
type Environment = {kind: "env_present", names: {string}}
type Status = {kind: "auth_status", argv: {string}, success_exit_code: integer, timeout_ms: integer}
type Evidence = File | Environment | Status
type Declaration = {command: string, any_of: {Evidence}}
type Check = {present: boolean?, exit_code: integer?, reason: string?}
type Probe = {file: (string, string?, string?) -> (boolean?, string?), environment: (string) -> boolean?,
    status: ({string}, integer) -> integer?}

local function array(raw: unknown, limit: integer): {unknown}?
    if type(raw) ~= "table" then return nil end
    local source = raw
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil end
        count = count + 1
    end
    if count < 1 or count > limit then return nil end
    local items: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil end
        items[index] = source[index]
    end
    return items
end

function M.relative(path: string): boolean
    if path == "" or path:sub(1, 1) == "/" or path:find("[%c\\]") then return false end
    for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
    return true
end

local function environment_name(raw: unknown): string?
    local name = bounds.text(raw, 128)
    return name and name:match("^[A-Z_][A-Z0-9_]*$") and name or nil
end

function M.decode(raw: unknown): (Declaration?, string?)
    local item = bounds.object(raw)
    if not item or bounds.fields(item, {"command", "any_of"}) then return nil, "login evidence must declare command and any_of" end
    local command = bounds.line(item.command, 128)
    local alternatives = array(item.any_of, 8)
    if not command or command == "" or not alternatives then return nil, "login evidence requires a command and 1 to 8 alternatives" end
    local decoded: {Evidence} = {}
    local file_count = 0
    for _, raw_alternative in ipairs(alternatives) do
        local alternative = bounds.object(raw_alternative)
        if not alternative then return nil, "login evidence alternative must be an object" end
        if alternative.kind == "file_exists" then
            if bounds.fields(alternative, {"kind", "paths", "variable", "directory"}) then return nil, "file evidence has unknown fields" end
            local paths = array(alternative.paths, 8)
            if not paths then return nil, "file evidence requires 1 to 8 paths" end
            file_count = file_count + #paths
            if file_count > 8 then return nil, "login evidence exceeds 8 file paths" end
            local checked: {string} = {}
            for _, raw_path in ipairs(paths) do
                local path = bounds.text(raw_path, 512)
                if not path or not M.relative(path) then return nil, "file evidence path must be safe and relative" end
                checked[#checked + 1] = path
            end
            local variable = alternative.variable ~= nil and environment_name(alternative.variable) or nil
            local directory = alternative.directory ~= nil and bounds.text(alternative.directory, 128) or nil
            if alternative.variable ~= nil and not variable then return nil, "file evidence variable is invalid" end
            if alternative.directory ~= nil and (not directory or not M.relative(directory)) then return nil, "file evidence directory is invalid" end
            if directory and (not variable or variable == "HOME") then return nil, "file evidence directory requires a provider variable" end
            for _, path in ipairs(checked) do
                if directory and path:sub(1, #directory + 1) ~= directory .. "/" then return nil, "file evidence path is outside its provider directory" end
            end
            decoded[#decoded + 1] = {kind = "file_exists", paths = checked, variable = variable, directory = directory}
        elseif alternative.kind == "env_present" then
            if bounds.fields(alternative, {"kind", "names"}) then return nil, "environment evidence has unknown fields" end
            local names = array(alternative.names, 16)
            if not names then return nil, "environment evidence requires 1 to 16 names" end
            local checked: {string} = {}
            for _, raw_name in ipairs(names) do
                local name = environment_name(raw_name)
                if not name then return nil, "environment evidence must contain names only" end
                checked[#checked + 1] = name
            end
            decoded[#decoded + 1] = {kind = "env_present", names = checked}
        elseif alternative.kind == "auth_status" then
            if bounds.fields(alternative, {"kind", "argv", "success_exit_code", "timeout_ms"}) then return nil, "status evidence has unknown fields" end
            local argv = array(alternative.argv, 8)
            local code, timeout = bounds.count(alternative.success_exit_code), bounds.count(alternative.timeout_ms)
            if not argv or not code or code > 255 or not timeout or timeout < 1 or timeout > 30000 then return nil, "status evidence argv, exit code or timeout is invalid" end
            local checked: {string} = {}
            for _, raw_arg in ipairs(argv) do
                local arg = bounds.line(raw_arg, 128)
                if not arg or arg == "" or arg:find("[%c]") then return nil, "status evidence argv contains invalid text" end
                checked[#checked + 1] = arg
            end
            decoded[#decoded + 1] = {kind = "auth_status", argv = checked, success_exit_code = code, timeout_ms = timeout}
        else return nil, "login evidence kind is unsupported" end
    end
    return {command = command, any_of = decoded}, nil
end

-- probe observes the alternatives in order until one proves the login; the
-- alternatives after it are left unobserved, so a signed-in CLI starts no
-- status command.
function M.probe(declaration: Declaration, probe: Probe): {Check}
    local checks: {Check} = {}
    local proven = false
    for index, evidence in ipairs(declaration.any_of) do
        if proven then
            checks[index] = {present = nil, exit_code = nil, reason = nil}
        else
            checks[index] = M.observe(evidence, probe)
            proven = checks[index].present == true
        end
    end
    return checks
end

-- observe checks one alternative.
function M.observe(evidence: Evidence, probe: Probe): Check
    local present: boolean? = false
    local code: integer? = nil
    local reason: string? = nil
    if evidence.kind == "auth_status" then
        code = probe.status(evidence.argv, evidence.timeout_ms)
        if code ~= nil then present = code == evidence.success_exit_code else present = nil end
    else
        local uncertain = false
        local values = evidence.kind == "file_exists" and evidence.paths or evidence.names
        for _, value in ipairs(values) do
            local found: boolean? = nil
            if evidence.kind == "file_exists" then
                local refusal: string? = nil
                found, refusal = probe.file(value, evidence.variable, evidence.directory)
                if refusal and not reason then reason = refusal end
            else found = probe.environment(value) end
            if found == true then present = true; reason = nil; break end
            if found == nil then uncertain = true end
        end
        if present ~= true and uncertain then present = nil end
    end
    return {present = present, exit_code = code, reason = reason}
end

function M.decode_checks(raw: unknown, declaration: Declaration): ({Check}?, string?)
    if raw == nil then return {}, nil end
    local values = array(raw, 8)
    if not values or #values ~= #declaration.any_of then return nil, "login checks must match the declared alternatives" end
    local checks: {Check} = {}
    for index, value in ipairs(values) do
        local item = bounds.object(value)
        if not item or bounds.fields(item, {"present", "exit_code", "reason"}) then return nil, "login check has unknown fields" end
        if item.present ~= nil and type(item.present) ~= "boolean" then return nil, "login check present must be boolean" end
        local code = item.exit_code ~= nil and bounds.count(item.exit_code) or nil
        local evidence = declaration.any_of[index]
        if item.exit_code ~= nil and (not code or code > 255 or evidence.kind ~= "auth_status") then return nil, "login check exit code is invalid" end
        if evidence.kind == "auth_status" and item.present ~= nil and (code == nil or item.present ~= (code == evidence.success_exit_code)) then return nil, "login status check disagrees with its exit code" end
        local reason: string? = nil
        if item.reason ~= nil then
            reason = bounds.line(item.reason, 512)
            if not reason or reason == "" or item.present == true or evidence.kind ~= "file_exists" then return nil, "login check reason is invalid" end
        end
        local present = item.present
        if evidence.kind == "auth_status" and code ~= nil then present = code == evidence.success_exit_code end
        checks[index] = {present = present, exit_code = code, reason = reason}
    end
    return checks, nil
end

function M.present(declaration: Declaration, checks: {Check}): boolean?
    local uncertain = false
    for index in ipairs(declaration.any_of) do
        local check = checks[index]
        if check and check.present == true then return true end
        if not check or check.present == nil then uncertain = true end
    end
    if uncertain then return nil end
    return false
end

return M
