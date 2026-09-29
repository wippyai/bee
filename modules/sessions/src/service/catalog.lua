-- MIT. Stage-one discovery pins launch admission and probes only declared
-- driver and placement contracts. Credential files are checked by existence.
local registry = require("registry")
local funcs = require("funcs")
local fs = require("fs")
local M = {}
local admission = require("admission")
local bounds = require("bounds")
local driver_route = require("driver_route")
local locate = require("locate")
local placement_resources = require("placement_resources")
local executors = require("executors")

type Object = {[string]: unknown}
type Candidate = {ref: string, kind: string, title: string, status: string,
    checked_at: string, reasons: {string}, features: {string}, actions: {Object}}
type Cache = locate.Cache
type Plan = {title: string, binding_ref: string, binding_digest: string, profile_id: string,
    profile_digest: string, policy_ref: string, policy_digest: string,
    placement_methods: {[string]: string}, executables: {[string]: string},
    catalog_generation: integer, plan_digest: string}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local cache, cache_error = locate.new(10000)
if not cache then error(tostring(cache_error)) end

local function diagnostic(message: string): Object
    return {code = "UNAVAILABLE", message = message, retry = "refresh"}
end

local function refusal(value: unknown): (string, string)
    local reply = object(value)
    local failure = reply and object(reply.error)
    local code = failure and tostring(failure.code or "UNAVAILABLE") or "UNAVAILABLE"
    local message = failure and tostring(failure.message or "launch admission refused the route")
        or "launch admission refused the route"
    local lowered = message:lower()
    if lowered:find("executable", 1, true) or lowered:find("cli", 1, true) then return "missing", message end
    if code == "UNSUPPORTED_CAPABILITY" or code == "INVALID" then return "incompatible", message end
    return "unknown", message
end

local function call(target: string, request: Object): (Object?, string?)
    local value, call_error = funcs.call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = object(value)
    if not reply then return nil, target .. " returned a malformed reply" end
    return reply, nil
end

local function route_data(plan: Plan): (Object?, string?)
    local entry, entry_error = registry.get(plan.policy_ref)
    local data = entry and object(entry.data)
    if entry_error or not data then return nil, "admitted launch policy is unavailable" end
    return data, nil
end

local function observation(status: string, reasons: {string}?, features: {string}?): locate.LocateObservation
    return {status = status, reasons = reasons, features = features, actions = {}} :: locate.LocateObservation
end

local function probe(plan: Plan, policy: Object): (locate.LocateObservation?, string?)
    local methods, methods_error = driver_route.resolve(plan.binding_ref)
    if not methods then return observation("incompatible", {methods_error or "driver methods are unavailable"}, nil), nil end

    local arguments: Object = {}
    local options = object(policy.prepare_options) or {}
    for name, value in pairs(options) do arguments[name] = value end
    arguments.profile_id = plan.profile_id
    arguments.brief = "Readiness check"
    arguments.gateway_tools = policy.gateway_tools or {}
    arguments.gateway_hooks = policy.gateway_hooks or {}
    local prepared, prepare_error = call(methods.prepare, arguments)
    if prepare_error then return observation("unknown", {prepare_error}, nil), nil end
    if prepared and prepared.ok ~= true then
        return observation("incompatible", {tostring(prepared.error or "driver rejected its session profile")}, nil), nil
    end
    local launch = prepared and object(prepared.launch)
    if not launch or type(launch.executable) ~= "string" then
        return observation("incompatible", {"driver returned no executable launch"}, nil), nil
    end
    local executable = plan.executables[launch.executable]
    if type(executable) ~= "string" or executable == "" or executable:sub(1, 1) ~= "/" then
        return observation("missing", {"the host has no absolute executable for " .. launch.executable}, nil), nil
    end
    local measure_target = plan.placement_methods.measure_executable
    if type(measure_target) ~= "string" then return observation("incompatible", {"placement cannot measure executables"}, nil), nil end
    local measurement, measure_error = call(measure_target, {path = executable})
    if measure_error then return observation("unknown", {measure_error}, nil), nil end
    if not measurement or measurement.ok ~= true then
        local failure = measurement and object(measurement.error)
        return observation("missing", {failure and tostring(failure.message or "CLI is missing") or "CLI is missing"}, nil), nil
    end

    local provider_home = object(launch.provider_home)
    local files = provider_home and provider_home.files
    if type(files) == "table" then
        local host_files, files_error = placement_resources.host_files()
        if not host_files then return observation("unknown", {files_error or "host login files are unavailable"}, nil), nil end
        local volume = fs.get(host_files)
        if not volume then return observation("unknown", {"host login files are unavailable"}, nil), nil end
        for _, raw in ipairs(files :: {unknown}) do
            local file = object(raw)
            if file and file.kind == "login" and type(file.source_path) == "string" then
                local exists, exists_error = volume:exists(file.source_path :: string)
                if exists == false and exists_error == nil then
                    return observation("unconfigured", {"provider login file is missing"}, nil), nil
                end
                if exists ~= true then
                    return observation("unknown", {"provider login file could not be checked"}, nil), nil
                end
            end
        end
    end
    return observation("ready", nil, {"external", "provider_resume"}), nil
end

local function executor_items(): {Candidate}
    local selected, selected_error = registry.get(executors.SELECTION_REF)
    local data = selected and object(selected.data)
    local refs = data and data.refs
    if selected_error or type(refs) ~= "table" then return {} end
    local snapshot, snapshot_error = registry.snapshot()
    if snapshot_error or not snapshot then return {} end
    local entries: {[string]: unknown} = {}
    for _, raw_ref in ipairs(refs :: {unknown}) do
        if type(raw_ref) == "string" then
            local entry = (snapshot :: registry.Snapshot):get(raw_ref)
            if entry then entries[raw_ref] = entry :: unknown end
        end
    end
    local built = executors.build(entries :: {[string]: unknown}, refs :: {string})
    if not built then return {} end
    local items: {Candidate} = {}
    for executor_id in pairs((built :: executors.Registry).by_id) do
        items[#items + 1] = {ref = "external:" .. executor_id, kind = "executor", title = executor_id,
            status = "ready", checked_at = "1970-01-01T00:00:00.000Z", reasons = {}, features = {"run_turn"}, actions = {}}
    end
    table.sort(items, function(left: Candidate, right: Candidate): boolean return left.ref < right.ref end)
    return items
end

local function saved_profiles(workspace: string, cursor: string?): ({{[string]: unknown}}?, string?, boolean?, string?)
    local after_key: string? = nil
    local expected_cursor: integer? = nil
    if cursor then
        local revision, key_value = cursor:match("^(%d+):(.*)$")
        expected_cursor = revision and bounds.integer(tonumber(revision)) or nil
        after_key = key_value ~= "" and key_value or nil
        if not expected_cursor or not after_key then return nil, nil, nil, "profile catalog cursor is invalid" end
    end
    local result, call_error = funcs.call("bee.harness.profiles:call", {
        operation = "list", workspace_id = workspace, after_key = after_key,
        expected_cursor = expected_cursor, limit = 64})
    if call_error then return nil, nil, nil, tostring(call_error) end
    local reply = object(result)
    local failure = reply and object(reply.error)
    if not reply or reply.ok ~= true then
        return nil, nil, nil, failure and tostring(failure.message or "saved profiles are unavailable") or "saved profiles are unavailable"
    end
    local page = object(reply.value)
    local rows = page and page.items
    local revision = page and bounds.integer(page.cursor)
    if not page or type(rows) ~= "table" or not revision or type(page.complete) ~= "boolean" then
        return nil, nil, nil, "saved profile list is malformed"
    end
    local items: {{[string]: unknown}} = {}
    for _, raw in ipairs(rows :: {unknown}) do
        local row = object(raw)
        if not row or type(row.profile_id) ~= "string" or type(row.revision) ~= "number" or type(row.tombstone) ~= "boolean" then
            return nil, nil, nil, "saved profile entry is malformed"
        end
        if not row.tombstone and object(row.profile) then items[#items + 1] = row end
    end
    local next_cursor: string? = nil
    if page.complete == false then
        if type(page.next_key) ~= "string" or page.next_key == "" then return nil, nil, nil, "saved profile continuation is malformed" end
        next_cursor = tostring(revision) .. ":" .. page.next_key
    end
    return items, next_cursor, page.complete :: boolean, nil
end

local function candidate_for(definition: string, kind: string, ref: string, title: string, workspace: string,
    profile_id: string?, profile_revision: integer?): Candidate
    local plan, refused = admission.resolve(definition, nil, workspace, profile_id, profile_revision)
    if not plan then
        local status, reason = refusal(refused)
        return {ref = ref, kind = kind, title = title, status = status,
            checked_at = "1970-01-01T00:00:00.000Z", reasons = {reason}, features = {}, actions = {}}
    end
    local selected = plan :: Plan
    local policy, policy_error = route_data(selected)
    if not policy then
        return {ref = ref, kind = kind, title = title, status = "unknown",
            checked_at = "1970-01-01T00:00:00.000Z", reasons = {policy_error or "launch policy is unavailable"}, features = {}, actions = {}}
    end
    local candidate: locate.CandidateInput = {
        ref = ref, kind = kind :: locate.Kind, title = title, target = selected.binding_ref,
        binding_ref = selected.binding_ref, binding_digest = selected.plan_digest,
        profile_digest = selected.profile_digest, runtime_identity = tostring(selected.catalog_generation),
        availability_revision = selected.policy_digest,
    }
    local located, locate_error = locate.locate(cache :: Cache, candidate,
        function(_: locate.CandidateInput): (locate.LocateObservation?, string?) return probe(selected, policy :: Object) end)
    if located then return located :: Candidate end
    return {ref = ref, kind = kind, title = title, status = "unknown",
        checked_at = "1970-01-01T00:00:00.000Z", reasons = {locate_error or "route readiness could not be checked"}, features = {}, actions = {}}
end

function M.list(request: unknown, workspace: string): (Object?, string?)
    local input = object(request)
    if not input or bounds.fields(input, {kind = true, include_unavailable = true, cursor = true}) then
        return nil, "catalog request is malformed"
    end
    local kind = input.kind == nil and "definition" or input.kind
    if kind ~= "definition" and kind ~= "profile" and kind ~= "executor" then return nil, "catalog kind is invalid" end
    if input.include_unavailable ~= nil and type(input.include_unavailable) ~= "boolean" then return nil, "include_unavailable must be boolean" end
    local cursor = input.cursor == nil and nil or bounds.text(input.cursor, 2048)
    if input.cursor ~= nil and not cursor then return nil, "catalog cursor is invalid" end

    local items: {Candidate} = {}
    local diagnostics: {Object} = {}
    local complete = true
    if kind == "executor" then
        items = executor_items()
    elseif kind == "definition" then
        local snapshot, snapshot_error = registry.snapshot()
        if snapshot_error or not snapshot then return nil, "launch registry snapshot is unavailable" end
        local found, find_error = (snapshot :: registry.Snapshot):find({["meta.type"] = "bee.launch_definition"})
        if find_error or not found then return nil, "launch definitions are unavailable" end
        local definitions: {Object} = {}
        for _, raw in ipairs(found) do
            local entry = object(raw)
            local data = entry and object(entry.data)
            if entry and data and type(entry.id) == "string"
                and ((cursor == nil) or (entry.id :: string) > (cursor :: string)) then
                definitions[#definitions + 1] = entry
            end
        end
        table.sort(definitions, function(left: Object, right: Object): boolean
            return tostring(left.id) < tostring(right.id)
        end)
        local count = math.min(#definitions, 64)
        local next_ref = count > 0 and tostring(definitions[count].id) or nil
        for index = 1, count do
            local entry = definitions[index]
            local definition = entry.id :: string
            local data = object(entry.data) or {}
            local candidate = candidate_for(definition, "definition", definition,
                tostring(data.title or definition), workspace, nil, nil)
            if input.include_unavailable == true or candidate.status == "ready" then items[#items + 1] = candidate end
        end
        complete = count == #definitions
        if not complete then cursor = next_ref end
    elseif kind == "profile" then
        local profiles, next_profile, profile_complete, profile_error = saved_profiles(workspace, cursor)
        if not profiles then
            diagnostics[#diagnostics + 1] = diagnostic(profile_error or "saved profiles are unavailable")
        else
            for _, row in ipairs(profiles) do
                local profile = object(row.profile) or {}
                local definition = bounds.id(profile.definition_ref)
                local profile_id = bounds.id(row.profile_id)
                local revision = bounds.integer(row.revision)
                if definition and profile_id and revision then
                    local candidate = candidate_for(definition, "profile", profile_id,
                        tostring(profile.title or profile_id), workspace, profile_id, revision)
                    if input.include_unavailable == true or candidate.status == "ready" then items[#items + 1] = candidate end
                end
            end
            complete = profile_complete == true
            if not complete then cursor = next_profile end
        end
    end
    local unavailable = 0
    for _, item in ipairs(items) do if item.status ~= "ready" then unavailable = unavailable + 1 end end
    local page: Object = {items = items, complete = complete, unavailable_count = unavailable, diagnostics = diagnostics}
    if not complete then page.next = cursor end
    return page, nil
end

return M
