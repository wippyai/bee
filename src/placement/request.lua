-- MIT. Launch request decoding: exact shapes, bounded sizes, every reference
-- an identifier, every resource named once, the launch's directory
-- references resolved against the grants. The digest covers the canonical
-- request so a retry with different content is a conflict, not a replay.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local driver_types = require("driver_types")
local preferences = require("preferences")
local M = {}
M.MAX_RESOURCES = 16
M.MAX_PROJECTIONS = 8
M.MAX_ENVIRONMENT = 64
M.MAX_ARGV = 128
M.MAX_ARGUMENT_BYTES = 16384
M.MAX_STDIN_BYTES = 65536
-- How a launch declares its session ends once the turn is settled.
M.SESSION_ENDS = {"stdin_close"}
M.MAX_START_MS = 120000
M.MAX_STOP_GRACE_MS = 60000
M.DEFAULT_START_MS = 15000
M.DEFAULT_STOP_GRACE_MS = 5000
M.DEFAULT_RETAIN_MS = 30000
M.MAX_RETAIN_MS = 600000
M.DEFAULT_DRAIN_MS = 5000
M.MAX_DRAIN_MS = 600000
local ENVIRONMENT_NAME = "^[A-Z_][A-Z0-9_]*$"
local function digest_hex(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end
function M.subpath(value: unknown): (string?, string?)
    return bounds.subpath(value)
end
local function decode_grant(value: unknown, index: integer): (types.ResourceGrant?, string?)
    local object = bounds.object(value)
    if not object then return nil, "resources[" .. tostring(index) .. "] must be an object" end
    local unknown_field = bounds.fields(object, {"name", "grant_ref", "root_ref", "subpath", "access", "purpose"})
    if unknown_field then return nil, "resources[" .. tostring(index) .. "]: " .. unknown_field end
    local name = bounds.id(object.name)
    if not name then return nil, "resources[" .. tostring(index) .. "].name is not an identifier" end
    local grant_ref = bounds.id(object.grant_ref)
    if not grant_ref then return nil, "resources[" .. tostring(index) .. "].grant_ref is not an identifier" end
    local root_ref = bounds.id(object.root_ref)
    if not root_ref then return nil, "resources[" .. tostring(index) .. "].root_ref is not an identifier" end
    local subpath, subpath_error = M.subpath(object.subpath == nil and "" or object.subpath)
    if not subpath then return nil, "resources[" .. tostring(index) .. "]: " .. tostring(subpath_error) end
    local access = bounds.member(object.access, types.ACCESS)
    if not access then return nil, "resources[" .. tostring(index) .. "].access must be read or write" end
    local purpose = bounds.member(object.purpose, types.PURPOSES)
    if not purpose then return nil, "resources[" .. tostring(index) .. "].purpose is not one placement knows" end
    return {name = name, grant_ref = grant_ref, root_ref = root_ref, subpath = subpath, access = access :: types.Access, purpose = purpose :: types.Purpose}, nil
end
function M.launch(value: unknown): (driver_types.Launch?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch must be an object" end
    local unknown_field = bounds.fields(object, {"executable", "argv", "stdin", "stdin_eof", "session_end", "environment", "working_directory_ref", "home_ref", "readiness"})
    if unknown_field then return nil, "launch: " .. unknown_field end
    local executable = bounds.text(object.executable, M.MAX_ARGUMENT_BYTES)
    if not executable or executable == "" or executable:find("\0", 1, true) then return nil, "launch.executable must be nonempty text" end
    if type(object.argv) ~= "table" then return nil, "launch.argv must be a list" end
    local argv: {string} = {}
    local raw_argv = object.argv :: {unknown}
    if #raw_argv > M.MAX_ARGV then return nil, "launch.argv exceeds " .. tostring(M.MAX_ARGV) .. " items" end
    for index, item in ipairs(raw_argv) do
        local argument = bounds.text(item, M.MAX_ARGUMENT_BYTES)
        if not argument or argument:find("\0", 1, true) then return nil, "launch.argv[" .. tostring(index) .. "] must be bounded text" end
        argv[index] = argument
    end
    local stdin: string? = nil
    if object.stdin ~= nil then
        stdin = bounds.text(object.stdin, M.MAX_STDIN_BYTES)
        if not stdin then return nil, "launch.stdin must be bounded text" end
    end
    local names, names_error = bounds.ids(object.environment == nil and {} or object.environment, true)
    if not names then return nil, "launch.environment: " .. tostring(names_error) end
    for _, name in ipairs(names) do
        if not name:match(ENVIRONMENT_NAME) then return nil, "launch.environment names " .. name .. ", not a variable name" end
    end
    local working: string? = nil
    if object.working_directory_ref ~= nil then
        working = bounds.id(object.working_directory_ref)
        if not working then return nil, "launch.working_directory_ref is not an identifier" end
    end
    local home: string? = nil
    if object.home_ref ~= nil then
        home = bounds.id(object.home_ref)
        if not home then return nil, "launch.home_ref is not an identifier" end
    end
    local readiness = bounds.text(object.readiness, 256)
    if not readiness or readiness == "" then return nil, "launch.readiness must be nonempty text" end
    local stdin_eof: boolean? = nil
    if object.stdin_eof ~= nil then
        if type(object.stdin_eof) ~= "boolean" then return nil, "launch.stdin_eof must be a boolean" end
        if object.stdin_eof == true and not stdin then return nil, "launch.stdin_eof needs launch.stdin" end
        stdin_eof = object.stdin_eof :: boolean
    end
    local session_end: string? = nil
    if object.session_end ~= nil then
        session_end = bounds.member(object.session_end, M.SESSION_ENDS)
        if not session_end then return nil, "launch.session_end must be stdin_close" end
        if stdin_eof == true then return nil, "launch.session_end names a closed stdin" end
    end
    return {executable = executable, argv = argv, stdin = stdin, stdin_eof = stdin_eof, session_end = session_end, environment = names, working_directory_ref = working, home_ref = home, readiness = readiness}, nil
end
local function decode_environment(value: unknown, field: string, values: boolean): ({[string]: string}?, string?)
    local result: {[string]: string} = {}
    if value == nil then return result, nil end
    local object = bounds.object(value)
    if not object then return nil, field .. " must be an object" end
    local count = 0
    for name, item in pairs(object) do
        count = count + 1
        if count > M.MAX_ENVIRONMENT then return nil, field .. " exceeds " .. tostring(M.MAX_ENVIRONMENT) .. " variables" end
        if not name:match(ENVIRONMENT_NAME) then return nil, field .. " names " .. name .. ", not a variable name" end
        if values then
            local text = bounds.text(item, M.MAX_ARGUMENT_BYTES)
            if not text or text:find("\0", 1, true) then return nil, field .. "." .. name .. " must be bounded text" end
            result[name] = text
        else
            local ref = bounds.id(item)
            if not ref then return nil, field .. "." .. name .. " is not an identifier" end
            result[name] = ref
        end
    end
    return result, nil
end
local function decode_timeouts(value: unknown): (types.Timeouts?, string?)
    local result: types.Timeouts = {start_ms = M.DEFAULT_START_MS, stop_grace_ms = M.DEFAULT_STOP_GRACE_MS, drain_ms = M.DEFAULT_DRAIN_MS, retain_ms = M.DEFAULT_RETAIN_MS}
    if value == nil then return result, nil end
    local object = bounds.object(value)
    if not object then return nil, "timeouts must be an object" end
    local unknown_field = bounds.fields(object, {"start_ms", "stop_grace_ms", "drain_ms", "retain_ms"})
    if unknown_field then return nil, "timeouts: " .. unknown_field end
    if object.drain_ms ~= nil then
        local drain = bounds.integer(object.drain_ms)
        if not drain or drain < 100 or drain > M.MAX_DRAIN_MS then return nil, "timeouts.drain_ms must be between 100 and " .. tostring(M.MAX_DRAIN_MS) end
        result.drain_ms = drain
    end
    if object.retain_ms ~= nil then
        local retain = bounds.integer(object.retain_ms)
        if not retain or retain < 100 or retain > M.MAX_RETAIN_MS then return nil, "timeouts.retain_ms must be between 100 and " .. tostring(M.MAX_RETAIN_MS) end
        result.retain_ms = retain
    end
    if object.start_ms ~= nil then
        local start = bounds.integer(object.start_ms)
        if not start or start < 1 or start > M.MAX_START_MS then return nil, "timeouts.start_ms must be between 1 and " .. tostring(M.MAX_START_MS) end
        result.start_ms = start
    end
    if object.stop_grace_ms ~= nil then
        local grace = bounds.integer(object.stop_grace_ms)
        if not grace or grace < 0 or grace > M.MAX_STOP_GRACE_MS then return nil, "timeouts.stop_grace_ms must be between 0 and " .. tostring(M.MAX_STOP_GRACE_MS) end
        result.stop_grace_ms = grace
    end
    return result, nil
end
function M.decode(value: unknown): (types.LaunchRequest?, string?)
    local object = bounds.object(value)
    if not object then return nil, "launch request must be an object" end
    local unknown_field = bounds.fields(object, {"idempotency_key", "owner_id", "owner_incarnation", "action_id", "attempt_id", "binding_ref", "policy_ref", "profile_id",
        "binding_digest", "profile_digest", "launch", "configuration_digest", "preferences", "executable", "gateway", "resources", "environment", "environment_refs", "projections", "session_ref", "required_cleanup", "required_exit_observation", "timeouts"})
    if unknown_field then return nil, unknown_field end
    local key = bounds.id(object.idempotency_key)
    if not key then return nil, "idempotency_key is not an identifier" end
    local owner_id = bounds.id(object.owner_id)
    if not owner_id then return nil, "owner_id is not an identifier" end
    local incarnation = bounds.integer(object.owner_incarnation)
    if not incarnation or incarnation < 1 then return nil, "owner_incarnation must be a positive integer" end
    local action_id = bounds.id(object.action_id)
    if not action_id then return nil, "action_id is not an identifier" end
    local attempt_id = bounds.id(object.attempt_id)
    if not attempt_id then return nil, "attempt_id is not an identifier" end
    local binding_ref = bounds.id(object.binding_ref)
    if not binding_ref then return nil, "binding_ref is not an identifier" end
    local policy_ref = bounds.id(object.policy_ref)
    if not policy_ref then return nil, "policy_ref is not an identifier" end
    local profile_id = bounds.id(object.profile_id)
    if not profile_id then return nil, "profile_id is not an identifier" end
    local binding_digest = digest_hex(object.binding_digest)
    if not binding_digest then return nil, "binding_digest must be a sha256 hex digest" end
    local profile_digest = digest_hex(object.profile_digest)
    if not profile_digest then return nil, "profile_digest must be a sha256 hex digest" end
    local launch, launch_error = M.launch(object.launch)
    if not launch then return nil, launch_error end
    if type(object.resources) ~= "table" then return nil, "resources must be a list" end
    local raw_resources = object.resources :: {unknown}
    if #raw_resources > M.MAX_RESOURCES then return nil, "resources exceeds " .. tostring(M.MAX_RESOURCES) .. " items" end
    local resources: {types.ResourceGrant} = {}
    local by_name: {[string]: types.ResourceGrant} = {}
    for index, item in ipairs(raw_resources) do
        local grant, grant_error = decode_grant(item, index)
        if not grant then return nil, grant_error end
        if by_name[grant.name] then return nil, "resources name " .. grant.name .. " twice" end
        by_name[grant.name] = grant
        resources[index] = grant
    end
    if launch.working_directory_ref then
        local grant = by_name[launch.working_directory_ref]
        if not grant then return nil, "launch.working_directory_ref names no resource" end
    end
    if launch.home_ref then
        local grant = by_name[launch.home_ref]
        if not grant then return nil, "launch.home_ref names no resource" end
        if grant.purpose ~= "session" or grant.access ~= "write" then return nil, "launch.home_ref must name a writable session resource" end
    end
    local environment, environment_error = decode_environment(object.environment, "environment", true)
    if not environment then return nil, environment_error end
    local refs, refs_error = decode_environment(object.environment_refs, "environment_refs", false)
    if not refs then return nil, refs_error end
    for name in pairs(refs) do
        if environment[name] ~= nil then return nil, "environment and environment_refs both set " .. name end
    end
    for _, name in ipairs(launch.environment) do
        if environment[name] == nil and refs[name] == nil then return nil, "launch.environment requires " .. name .. " and nothing supplies it" end
    end
    local configuration_digest: string? = nil
    local selected: types.Preferences? = nil
    if object.preferences ~= nil then
        local decoded_preferences, preference_error = preferences.decode(object.preferences)
        if not decoded_preferences then return nil, preference_error end
        selected = decoded_preferences
    end
    if object.configuration_digest ~= nil then
        configuration_digest = digest_hex(object.configuration_digest)
        if not configuration_digest then return nil, "configuration_digest must be a sha256 hex digest" end
    end
    local gateway: types.Gateway? = nil
    if object.gateway ~= nil then
        local declared = bounds.object(object.gateway)
        if not declared then return nil, "gateway must be an object" end
        local unknown_gateway = bounds.fields(declared, {"endpoint", "tools", "destination", "hooks", "hook_destination"})
        if unknown_gateway then return nil, "gateway: " .. unknown_gateway end
        local endpoint = bounds.text(declared.endpoint, 2048)
        if not endpoint or endpoint == "" or endpoint:find("%c") then return nil, "gateway.endpoint must be bounded text" end
        local tools, tools_error = bounds.ids(declared.tools, true)
        if not tools then return nil, "gateway.tools: " .. tostring(tools_error) end
        if #tools > M.MAX_PROJECTIONS then return nil, "gateway.tools exceeds " .. tostring(M.MAX_PROJECTIONS) .. " tools" end
        local destination = bounds.id(declared.destination)
        if not destination or not destination:match("^[A-Z][A-Z0-9_]*$") then return nil, "gateway.destination must be an environment name" end
        local hook_events, hook_events_error = bounds.ids(declared.hooks == nil and {} or declared.hooks, true)
        if not hook_events then return nil, "gateway.hooks: " .. tostring(hook_events_error) end
        if #hook_events > M.MAX_PROJECTIONS then return nil, "gateway.hooks exceeds " .. tostring(M.MAX_PROJECTIONS) .. " items" end
        if #tools == 0 and #hook_events == 0 then return nil, "gateway needs tools or hooks" end
        local hook_destination: string? = nil
        if declared.hook_destination ~= nil then
            hook_destination = bounds.id(declared.hook_destination)
            if not hook_destination or not hook_destination:match("^[A-Z][A-Z0-9_]*$") then return nil, "gateway.hook_destination must be an environment name" end
        end
        if #hook_events > 0 and not hook_destination then return nil, "gateway.hooks needs gateway.hook_destination" end
        if #hook_events == 0 and hook_destination then return nil, "gateway.hook_destination needs admitted hook events" end
        gateway = {endpoint = endpoint, tools = tools, destination = destination, hooks = hook_events, hook_destination = hook_destination}
    end
    local executable: types.ExecutableMeasurement? = nil
    if object.executable ~= nil then
        local declared = bounds.object(object.executable)
        if not declared then return nil, "executable must be an object" end
        local unknown_measurement = bounds.fields(declared, {"revision", "kind", "digest"})
        if unknown_measurement then return nil, "executable: " .. unknown_measurement end
        local revision = bounds.id(declared.revision)
        if not revision then return nil, "executable.revision is not an identifier" end
        local kind = bounds.member(declared.kind, types.EXECUTABLE_KINDS)
        if not kind then return nil, "executable.kind must be elf, script or other" end
        local measured_digest = digest_hex(declared.digest)
        if not measured_digest then return nil, "executable.digest must be a sha256 hex digest" end
        executable = {revision = revision, kind = kind, digest = measured_digest}
    end
    local projections, projections_error = bounds.ids(object.projections == nil and {} or object.projections, true)
    if not projections then return nil, "projections: " .. tostring(projections_error) end
    if #projections > M.MAX_PROJECTIONS then return nil, "projections exceeds " .. tostring(M.MAX_PROJECTIONS) .. " items" end
    local session_ref: string? = nil
    if object.session_ref ~= nil then
        session_ref = bounds.id(object.session_ref)
        if not session_ref then return nil, "session_ref is not an identifier" end
    end
    local required = bounds.member(object.required_cleanup, types.CAPABILITIES)
    if not required then return nil, "required_cleanup must name a cleanup capability" end
    local observation = bounds.member(object.required_exit_observation == nil and "independent" or object.required_exit_observation, types.EXIT_OBSERVATIONS)
    if not observation then return nil, "required_exit_observation must be independent or eof_gated" end
    local timeouts, timeouts_error = decode_timeouts(object.timeouts)
    if not timeouts then return nil, timeouts_error end
    local decoded: types.LaunchRequest = {idempotency_key = key, owner_id = owner_id, owner_incarnation = incarnation, action_id = action_id, attempt_id = attempt_id,
        preferences = selected,
        binding_ref = binding_ref, policy_ref = policy_ref, profile_id = profile_id, binding_digest = binding_digest, profile_digest = profile_digest, launch = launch, configuration_digest = configuration_digest, executable = executable, gateway = gateway,
        resources = resources, environment = environment, environment_refs = refs, projections = projections, session_ref = session_ref,
        required_cleanup = required :: types.Capability, required_exit_observation = observation :: types.ExitObservation, timeouts = timeouts}
    return decoded, nil
end
-- The canonical digest of a decoded request: two requests with one
-- idempotency key and different digests conflict.
function M.digest(request: types.LaunchRequest): (string?, string?)
    local encoded, encode_error = canonical.encode(request)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest the launch request" end
    return sum, nil
end
return M
