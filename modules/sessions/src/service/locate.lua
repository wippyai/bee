-- MIT. Candidate readiness is a bounded observation, never an authority grant.
-- Cache identity includes every measured input that can change launchability.
local time = require("time")
local M = {}

M.STATUSES = {"ready", "missing", "unconfigured", "incompatible", "unknown"}
M.INVALIDATION_CAUSES = {"install", "config", "login", "launch_failure"}

type Status = "ready" | "missing" | "unconfigured" | "incompatible" | "unknown"
type Kind = "definition" | "profile" | "executor"
type Clock = {now_ms: () -> integer, format: (integer) -> string}
type Action = {operation: string, label: string}
type Fault = {code: string, message: string, retry: "never" | "same_key" | "refresh" | "reconcile"}
type CandidateInput = {ref: string, kind: Kind, title: string, revision: integer?, target: string, binding_ref: string,
    binding_digest: string, profile_digest: string?, runtime_identity: string, availability_revision: string}
type LocateObservation = {status: Status, reasons: {string}?, features: {string}?, actions: {Action}?, revision: integer?}
type Candidate = {ref: string, kind: Kind, revision: integer?, title: string, status: Status, checked_at: string,
    expires_at: string, reasons: {string}, features: {string}, actions: {Action}}
type Cached = {value: Candidate, expires_at_ms: integer, target: string, key: string}
type Cache = {ttl_ms: integer, clock: Clock, by_key: {[string]: Cached}, by_ref: {[string]: string}}
type Probe = (CandidateInput) -> (LocateObservation?, string?)
type Diagnostic = Fault
type Page = {items: {Candidate}, next: string?, complete: boolean, unavailable_count: integer, diagnostics: {Diagnostic}}

local function system_clock(): Clock
    return {
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        format = function(ms: integer): string
            return time.unix(math.floor(ms / 1000), (ms % 1000) * 1000000):utc():format("2006-01-02T15:04:05.000Z07:00")
        end,
    }
end

local function bounded_id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 256 then return nil end
    if not value:match("^[A-Za-z0-9][A-Za-z0-9_.:-]*$") then return nil end
    return value
end

local function bounded_text(value: unknown, max: integer): string?
    if type(value) ~= "string" or #value > max or value:find("%z") then return nil end
    return value
end

local function is_integer(value: unknown, minimum: integer): boolean
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value < math.huge
end

local function member(value: unknown, allowed: {string}): boolean
    if type(value) ~= "string" then return false end
    for _, item in ipairs(allowed) do if item == value then return true end end
    return false
end

local function array(value: unknown, max: integer, validate: (unknown) -> boolean): (boolean, string?)
    if type(value) ~= "table" then return false, "must be a list" end
    local list = value :: {unknown}
    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false, "must be a list" end
        count = count + 1
        if count > max then return false, "exceeds " .. tostring(max) .. " items" end
    end
    for index = 1, count do
        if list[index] == nil or not validate(list[index]) then return false, "contains an invalid item" end
    end
    return true, nil
end

local function validate_candidate(candidate: CandidateInput): string?
    if type(candidate) ~= "table" then return "candidate must be an object" end
    if not bounded_id(candidate.ref) then return "candidate ref is malformed" end
    if not member(candidate.kind, {"definition", "profile", "executor"}) then return "candidate kind is invalid" end
    if not bounded_text(candidate.title, 512) or candidate.title == "" then return "candidate title is invalid" end
    if candidate.revision ~= nil and not is_integer(candidate.revision, 1) then return "candidate revision is invalid" end
    for _, field in ipairs({"target", "binding_ref", "binding_digest", "runtime_identity", "availability_revision"}) do
        if not bounded_id(candidate[field]) then return "candidate " .. field .. " is malformed" end
    end
    if candidate.profile_digest ~= nil and not bounded_id(candidate.profile_digest) then return "candidate profile_digest is malformed" end
    return nil
end

local function key(candidate: CandidateInput): string
    local fields = {candidate.target, candidate.ref, candidate.binding_ref, candidate.binding_digest,
        candidate.profile_digest or "", candidate.runtime_identity, candidate.availability_revision}
    local parts: {string} = {}
    for _, field in ipairs(fields) do parts[#parts + 1] = tostring(#field) .. ":" .. field end
    return table.concat(parts)
end

local function decode_reasons(value: unknown): ({string}?, string?)
    if value == nil then return {}, nil end
    local ok, err = array(value, 64, function(item): boolean return bounded_text(item, 16384) ~= nil end)
    if not ok then return nil, "reasons " .. tostring(err) end
    return value :: {string}, nil
end

local function decode_features(value: unknown): ({string}?, string?)
    if value == nil then return {}, nil end
    local ok, err = array(value, 64, function(item): boolean return bounded_id(item) ~= nil end)
    if not ok then return nil, "features " .. tostring(err) end
    return value :: {string}, nil
end

local function decode_actions(value: unknown): ({Action}?, string?)
    if value == nil then return {}, nil end
    if type(value) ~= "table" then return nil, "actions must be a list" end
    local actions: {Action} = {}
    local list = value :: {unknown}
    local seen: {[string]: boolean} = {}
    for key_index in pairs(list) do
        if type(key_index) ~= "number" or key_index < 1 or math.floor(key_index) ~= key_index then return nil, "actions must be a list" end
    end
    for index, raw in ipairs(list) do
        if index > 64 then return nil, "actions exceeds 64 items" end
        if type(raw) ~= "table" then return nil, "actions contains an invalid item" end
        local action = raw :: {[string]: unknown}
        local operation = bounded_id(action.operation)
        local label = bounded_text(action.label, 16384)
        if not operation or not label or label == "" then return nil, "actions contains an invalid item" end
        if seen[operation] then return nil, "actions contains a duplicate operation" end
        seen[operation] = true
        actions[#actions + 1] = {operation = operation, label = label}
    end
    return actions, nil
end

local function public_candidate(input: CandidateInput, observation: LocateObservation?, probe_error: string?, checked: integer, expires: integer, clock: Clock): (Candidate?, string?)
    local status: Status = "unknown"
    local reasons: {string} = {}
    local features: {string} = {}
    local actions: {Action} = {}
    local revision = input.revision
    if probe_error then
        reasons = {"Readiness probe unavailable."}
    elseif type(observation) ~= "table" or not member(observation.status, M.STATUSES) then
        reasons = {"Readiness probe returned invalid evidence."}
    else
        status = observation.status
        local reason_values, reasons_error = decode_reasons(observation.reasons)
        if not reason_values then return nil, reasons_error end
        local feature_values, features_error = decode_features(observation.features)
        if not feature_values then return nil, features_error end
        local action_values, actions_error = decode_actions(observation.actions)
        if not action_values then return nil, actions_error end
        reasons, features, actions = reason_values, feature_values, action_values
        if observation.revision ~= nil then
            if not is_integer(observation.revision, 1) then return nil, "probe revision is invalid" end
            revision = observation.revision
        end
    end
    if status ~= "ready" and #reasons == 0 then
        reasons[1] = status == "unknown" and "Readiness could not be established." or "Executor is " .. status .. "."
    end
    return {ref = input.ref, kind = input.kind, revision = revision, title = input.title, status = status,
        checked_at = clock.format(checked), expires_at = clock.format(expires), reasons = reasons,
        features = features, actions = actions}, nil
end

function M.new(ttl_ms: integer, clock: Clock?): (Cache?, string?)
    if not is_integer(ttl_ms, 1) then return nil, "ttl_ms must be a positive integer" end
    local selected_clock = clock or system_clock()
    if type(selected_clock) ~= "table" or type(selected_clock.now_ms) ~= "function" or type(selected_clock.format) ~= "function" then
        return nil, "clock is malformed"
    end
    return {ttl_ms = ttl_ms, clock = selected_clock, by_key = {}, by_ref = {}}, nil
end

function M.locate(cache: Cache, candidate: CandidateInput, probe: Probe): (Candidate?, string?)
    local candidate_error = validate_candidate(candidate)
    if candidate_error then return nil, "INVALID: " .. candidate_error end
    if type(probe) ~= "function" then return nil, "INVALID: locate probe is required" end
    local cache_key = key(candidate)
    local now = cache.clock.now_ms()
    local previous = cache.by_ref[candidate.ref]
    if previous and previous ~= cache_key then cache.by_key[previous] = nil end
    cache.by_ref[candidate.ref] = cache_key
    local stored = cache.by_key[cache_key]
    if stored and now < stored.expires_at_ms then return stored.value, nil end
    local observation, probe_error = probe(candidate)
    local expires = now + cache.ttl_ms
    local result, result_error = public_candidate(candidate, observation, probe_error, now, expires, cache.clock)
    if not result then return nil, "INVALID: " .. tostring(result_error) end
    cache.by_key[cache_key] = {value = result, expires_at_ms = expires, target = candidate.target, key = cache_key}
    return result, nil
end

function M.reprobe(cache: Cache, candidate: CandidateInput, probe: Probe): (Candidate?, string?)
    local previous = cache.by_ref[candidate.ref]
    if previous then cache.by_key[previous] = nil end
    cache.by_ref[candidate.ref] = nil
    return M.locate(cache, candidate, probe)
end

function M.invalidate(cache: Cache, target: string, cause: string): boolean
    if not bounded_id(target) or not member(cause, M.INVALIDATION_CAUSES) then return false end
    local removed = false
    for ref, cache_key in pairs(cache.by_ref) do
        local stored = cache.by_key[cache_key]
        if stored and stored.target == target then
            cache.by_key[cache_key] = nil
            cache.by_ref[ref] = nil
            removed = true
        end
    end
    return removed
end

local function valid_candidate_value(raw: unknown): boolean
    if type(raw) ~= "table" then return false end
    local item = raw :: {[string]: unknown}
    if not bounded_id(item.ref) or not member(item.kind, {"definition", "profile", "executor"}) then return false end
    if item.revision ~= nil and not is_integer(item.revision, 1) then return false end
    if not bounded_text(item.title, 512) or item.title == "" or not member(item.status, M.STATUSES) then return false end
    if not bounded_text(item.checked_at, 64) or not bounded_text(item.expires_at, 64) then return false end
    if not array(item.reasons, 64, function(value): boolean return bounded_text(value, 16384) ~= nil end) then return false end
    if not array(item.features, 64, function(value): boolean return bounded_id(value) ~= nil end) then return false end
    return decode_actions(item.actions) ~= nil
end

local function valid_fault(raw: unknown): boolean
    if type(raw) ~= "table" then return false end
    local fault = raw :: {[string]: unknown}
    return bounded_id(fault.code) ~= nil and bounded_text(fault.message, 16384) ~= nil
        and member(fault.retry, {"never", "same_key", "refresh", "reconcile"})
end

function M.page(items: {Candidate}, complete: boolean, diagnostics: {Diagnostic}, next_cursor: string?): (Page?, string?)
    if type(complete) ~= "boolean" then return nil, "complete must be boolean" end
    local items_ok, items_error = array(items, 64, valid_candidate_value)
    if not items_ok then return nil, "items " .. tostring(items_error) end
    local diagnostics_ok, diagnostics_error = array(diagnostics, 64, valid_fault)
    if not diagnostics_ok then return nil, "diagnostics " .. tostring(diagnostics_error) end
    if next_cursor ~= nil and (not bounded_text(next_cursor, 2048) or next_cursor == "") then return nil, "next cursor is invalid" end
    local unavailable = 0
    for _, item in ipairs(items) do if item.status ~= "ready" then unavailable = unavailable + 1 end end
    return {items = items, next = next_cursor, complete = complete, unavailable_count = unavailable,
        diagnostics = diagnostics}, nil
end

return M
