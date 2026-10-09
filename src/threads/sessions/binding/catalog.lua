-- MIT. Build the public sessions catalog from launch definitions and saved
-- profiles, measuring each route with the host-selected driver locator.
local bounds = require("bounds")
local funcs = require("funcs")
local harness_catalog = require("harness_catalog")
local definition = require("definition")
local admission = require("admission")
local profile_protocol = require("profile_protocol")
local locate = require("locate")
local readiness = require("readiness")
local locate_driver = require("locate_driver")
local configuration_setup = require("configuration_setup")
local M = {}

M.PAGE_SIZE = 64
M.MAX_DEFINITIONS = 64
M.MAX_PROFILE_PAGES = 16
M.PROFILE_CALL = "bee.harness.binding:call"

type Object = {[string]: unknown}
type Kind = "definition" | "profile"
type Status = "ready" | "missing" | "unconfigured" | "incompatible" | "unknown"
type Fault = {code: string, message: string, retry: "never" | "same_key" | "refresh" | "reconcile"}
type ProfileRow = {workspace_id: string, profile_id: string, revision: integer, tombstone: boolean, profile: profile_protocol.Profile?, migration_diagnostic: Object?}
type ProfilePage = {workspace_id: string, items: {ProfileRow}, cursor: integer, next_key: string?, complete: boolean}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function fault(code: string, message: string, retry: "never" | "same_key" | "refresh" | "reconcile"): Fault
    return {code = code, message = message, retry = retry}
end

local function failure_status(raw: unknown): (Status, string)
    local reply = object(raw)
    local details = reply and object(reply.error) or nil
    local code = details and bounds.id(details.code) or nil
    local message = details and bounds.text(details.message, 16384) or nil
    if code == "NOT_FOUND" then return "missing", message or "The admitted definition is missing." end
    if code == "UNAVAILABLE" then return "unconfigured", message or "The route is not configured on this host." end
    if code == "UNSUPPORTED_CAPABILITY" or code == "INVALID" then
        return "incompatible", message or "The route is not compatible with this host."
    end
    return "unknown", message or "The route could not be admitted on this host."
end

local function dense_rows(value: unknown): {unknown}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    local rows: {unknown} = {}
    for index = 1, count do
        if value[index] == nil then return nil end
        rows[index] = value[index]
    end
    return rows
end

local function decode_profile_row(workspace: string, raw: unknown): (ProfileRow?, string?)
    local row = object(raw)
    if not row then return nil, "profile snapshot row is not an object" end
    local extra = bounds.fields(row, {"workspace_id", "profile_id", "revision", "tombstone", "profile", "migration_diagnostic", "grant_id", "grant_state"})
    if extra then return nil, "profile snapshot row: " .. extra end
    if row.grant_id ~= nil and not bounds.id(row.grant_id) then return nil,"profile grant identity is invalid" end
    if row.grant_state ~= nil and not bounds.member(row.grant_state,{"active","revoked","expired","exhausted","missing"}) then return nil,"profile grant state is invalid" end
    local row_workspace = bounds.id(row.workspace_id)
    local profile_id = bounds.id(row.profile_id)
    local revision = bounds.count(row.revision)
    if row_workspace ~= workspace or not profile_id or not revision or revision < 1 then
        return nil, "profile snapshot row identity is invalid"
    end
    if type(row.tombstone) ~= "boolean" then return nil, "profile snapshot row tombstone is invalid" end
    if row.tombstone then
        if row.profile ~= nil then return nil, "profile tombstone contains a value" end
        return {workspace_id = workspace, profile_id = profile_id, revision = revision, tombstone = true, profile = nil}, nil
    end
    if row.migration_diagnostic ~= nil then
        local diagnostic = bounds.object(row.migration_diagnostic)
        if not diagnostic then return nil, "migration diagnostic is invalid" end
        return {workspace_id = workspace, profile_id = profile_id, revision = revision, tombstone = false,
            profile = nil, migration_diagnostic = diagnostic}, nil
    end
    if row.profile == nil then return nil, "profile snapshot row has no value" end
    local profile, profile_error = profile_protocol.profile(row.profile)
    if not profile then return nil, profile_error or "profile snapshot value is invalid" end
    return {workspace_id = workspace, profile_id = profile_id, revision = revision, tombstone = false, profile = profile}, nil
end

local function decode_profile_page(workspace: string, raw: unknown, expected_cursor: integer?, after_key: string?): (ProfilePage?, string?)
    local page = object(raw)
    if not page then return nil, "profile snapshot is not an object" end
    local extra = bounds.fields(page, {"workspace_id", "items", "cursor", "next_key", "complete"})
    if extra then return nil, "profile snapshot: " .. extra end
    local page_workspace = bounds.id(page.workspace_id)
    local cursor = bounds.count(page.cursor)
    if page_workspace ~= workspace or not cursor or type(page.complete) ~= "boolean" then
        return nil, "profile snapshot envelope is invalid"
    end
    if expected_cursor ~= nil and cursor ~= expected_cursor then return nil, "profile snapshot cursor changed" end
    local raw_rows = dense_rows(page.items)
    if not raw_rows or #raw_rows > 64 then return nil, "profile snapshot rows exceed their bound" end
    local rows: {ProfileRow} = {}
    local previous = after_key
    for _, raw_row in ipairs(raw_rows) do
        local row, row_error = decode_profile_row(workspace, raw_row)
        if not row then return nil, row_error end
        rows[#rows + 1] = row
        previous = row.profile_id
    end
    local next_key: string? = nil
    if page.complete then
        if page.next_key ~= nil then return nil, "complete profile snapshot has a continuation" end
    else
        next_key = bounds.id(page.next_key)
        if not next_key or #rows == 0 or next_key ~= rows[#rows].profile_id then
            return nil, "profile snapshot continuation is invalid"
        end
    end
    return {workspace_id = workspace, items = rows, cursor = cursor, next_key = next_key, complete = page.complete}, nil
end

local function profile_rows(workspace: string, definition_ref: string?, query: string?, sort: string?): ({ProfileRow}?, integer?, Fault?)
    local rows: {ProfileRow} = {}
    local after_key = ""
    local expected_cursor: integer? = nil
    local seen: {[string]: boolean} = {}
    while true do
        local request: Object = {operation = "list", workspace_id = workspace, after_key = after_key, limit = 64, definition_ref = definition_ref, query = query, sort = sort}
        if expected_cursor ~= nil then request.expected_cursor = expected_cursor end
        local raw, call_error = funcs.call(M.PROFILE_CALL, request)
        if call_error then return nil, nil, fault("UNAVAILABLE", tostring(call_error), "refresh") end
        local reply = object(raw)
        if not reply or reply.ok ~= true then
            local code = reply and bounds.id(reply.code) or nil
            local message = reply and bounds.text(reply.message, 512) or nil
            return nil, nil, fault(code or "UNAVAILABLE", message or "Saved profiles could not be read.", "refresh")
        end
        local page, page_error = decode_profile_page(workspace, reply.value, expected_cursor, after_key ~= "" and after_key or nil)
        if not page then return nil, nil, fault("UNAVAILABLE", page_error or "Saved profile snapshot is invalid.", "refresh") end
        expected_cursor = expected_cursor or page.cursor
        for _, row in ipairs(page.items) do
            if seen[row.profile_id] then return nil, nil, fault("UNAVAILABLE", "Saved profile snapshot repeats an id.", "refresh") end
            seen[row.profile_id] = true
            rows[#rows + 1] = row
        end
        if page.complete then return rows, expected_cursor, nil end
        after_key = page.next_key
    end
    return rows, expected_cursor, nil
end

local function diagnostic_from(failure: Fault): Fault
    return {code = failure.code, message = failure.message, retry = failure.retry}
end

local function measured_candidate(cache: locate.Cache, readiness_cache: readiness.Cache, kind: Kind, ref: string,
    title: string, revision: integer?, selected: definition.Definition, plan: unknown, refused: unknown,
    generation: integer): (locate.Candidate?, string?)
    local plan_object = object(plan)
    local base_status: Status = "ready"
    local base_reason = ""
    if not plan then base_status, base_reason = failure_status(refused) end
    local plan_digest = plan_object and bounds.id(plan_object.plan_digest) or nil
    local binding_digest = plan_object and bounds.id(plan_object.binding_digest) or nil
    local profile_digest = plan_object and bounds.id(plan_object.profile_digest) or nil
    local route_generation = plan_object and bounds.count(plan_object.catalog_generation) or nil
    local input: locate.CandidateInput = {ref = ref, kind = kind, title = title, revision = revision,
        target = "bee.executor.external", binding_ref = selected.binding_ref,
        binding_digest = binding_digest or "unresolved", profile_digest = profile_digest or plan_digest,
        runtime_identity = "local", availability_revision = tostring(route_generation or generation)}
    local value, locate_error = locate.locate(cache, input, function(_: locate.CandidateInput): (locate.LocateObservation?, string?)
        local placement_profile_ref = plan_object and bounds.id(plan_object.placement_profile_ref) or nil
        local probe = readiness.probe(selected.binding_ref, selected.profile_id, readiness_cache, placement_profile_ref)
        if probe.error then return nil, probe.error end
        if not probe.located or not probe.result then return nil, "The active driver does not provide readiness evidence." end
        local reasons: {string} = {}
        if probe.result.reason then reasons[1] = probe.result.reason end
        local features: {string} = {"driver:" .. probe.result.provider}
        for path, capability in pairs(probe.result.capabilities or {}) do
            features[#features + 1] = (capability.supported and "supported:" or "unsupported:") .. path
        end
        table.sort(features)
        local interactive = locate_driver.installed(probe.result)
        return {status = interactive and "ready" or probe.result.status, reasons = reasons, features = features, actions = {}}, nil
    end)
    if not value then return nil, locate_error end
    local status: Status = base_status
    local reason = base_reason
    if value.status == "ready" then
        if plan then reason = value.reasons[1] or "" end
    elseif value.status == "unknown" and not plan then
        -- Keep the admission reason when both layers are inconclusive.
    else
        status, reason = value.status, value.reasons[1] or "Driver readiness is unknown."
    end
    if status ~= "ready" and reason == "" then reason = "The route is not ready on this host." end
    local actions: {locate.Action} = {}
    if status == "ready" then actions[1] = {operation = "session_open", label = "Open session"} end
    local reasons: {string} = {}
    if status == "ready" then reasons = value.reasons else reasons[1] = reason end
    local candidate: locate.Candidate = {ref = value.ref, kind = value.kind, revision = value.revision, title = value.title,
        status = status, checked_at = value.checked_at, reasons = reasons, features = value.features, actions = actions}
    return candidate, nil
end

local function unavailable_candidate(cache: locate.Cache, kind: Kind, ref: string, title: string,
    revision: integer?, status: Status, reason: string, generation: integer): (locate.Candidate?, string?)
    return locate.locate(cache, {ref = ref, kind = kind, title = title, revision = revision,
        target = "bee.executor.external", binding_ref = "bee.driver.unavailable:binding", binding_digest = "unresolved",
        runtime_identity = "local", availability_revision = tostring(generation)}, function(_: locate.CandidateInput): (locate.LocateObservation?, string?)
        return {status = status, reasons = {reason}, features = {}, actions = {}}, nil
    end)
end

local function candidate_for_definition(pinned: harness_catalog.Pinned, ref: string, entry: Object,
    kind: Kind, title: string, revision: integer?, profile_id: string?, workspace: string,
    cache: locate.Cache, readiness_cache: readiness.Cache, generation: integer): (locate.Candidate?, string?)
    local candidate_ref = ref
    if kind == "profile" then
        if not profile_id then return nil, "saved profile identity is missing" end
        candidate_ref = profile_id
    end
    local decoded, decode_error = definition.decode(ref, entry)
    if not decoded then
        return unavailable_candidate(cache, kind, candidate_ref, title, revision, "incompatible",
            decode_error or "The launch definition is invalid.", generation)
    end
    local plan: unknown = nil
    local refused: unknown = nil
    if kind == "profile" and profile_id and revision then
        plan, refused = admission.resolve(ref, "window", workspace, profile_id, revision)
    else
        plan, refused = admission.read(pinned, ref, "window")
    end
    local candidate, candidate_error = measured_candidate(cache, readiness_cache, kind, candidate_ref, title, revision, decoded, plan, refused, generation)
    if not candidate then return nil, candidate_error end
    local result: locate.Candidate = {ref = candidate.ref, kind = candidate.kind, revision = candidate.revision,
        title = candidate.title, status = candidate.status, checked_at = candidate.checked_at,
        features = candidate.features, actions = candidate.actions, reasons = candidate.reasons}
    if result.status == "ready" and plan then
        local setup, setup_error = configuration_setup.run(plan, workspace, "status")
        if setup and setup.needs_setup then
            result.features[#result.features + 1] = "configuration:needs_setup"
            local reasons: {string} = {"Needs setup: allow Bee to use " .. table.concat(setup.paths, ", ") .. ". Choose Setup; approve in Needs you to continue."}
            result.reasons = reasons
            result.actions[#result.actions + 1] = {operation = "configuration_setup", label = "Setup"}
        elseif setup_error then
            result.status = "unknown"
            local reasons: {string} = {setup_error}
            result.reasons = reasons
        end
    end
    if decoded.presentation.start_menu then result.features[#result.features + 1] = "presentation:start_menu" end
    return result, candidate_error
end

local function valid_cursor(value: unknown): integer?
    if value == nil then return 0 end
    if type(value) ~= "string" then return nil end
    local digits = value:match("^catalog:([0-9]+)$")
    if not digits then return nil end
    local offset = tonumber(digits)
    if not offset or offset < 0 or offset ~= math.floor(offset) or offset > 1000000 then return nil end
    return math.floor(offset)
end

function M.list(raw: unknown, workspace: string): (locate.Page?, Fault?)
    local request = object(raw)
    if not request then return nil, fault("INVALID", "catalog request must be an object", "never") end
    local extra = bounds.fields(request, {"kind", "include_unavailable", "cursor", "definition_ref", "query", "sort"})
    if extra then return nil, fault("INVALID", "catalog request: " .. extra, "never") end
    local kind = bounds.member(request.kind, {"definition", "profile"})
    if request.kind ~= nil and not kind then return nil, fault("INVALID", "catalog kind is invalid", "never") end
    if request.include_unavailable ~= nil and type(request.include_unavailable) ~= "boolean" then
        return nil, fault("INVALID", "include_unavailable must be boolean", "never")
    end
    local definition_filter = bounds.id(request.definition_ref)
    if request.definition_ref ~= nil and not definition_filter then return nil, fault("INVALID", "definition_ref must be an identifier", "never") end
    local query = bounds.line(request.query, 80)
    if request.query ~= nil and not query then return nil, fault("INVALID", "query must be bounded text", "never") end
    local sort = request.sort == nil and "name" or bounds.member(request.sort, {"name", "driver"})
    if not sort then return nil, fault("INVALID", "sort must be name or driver", "never") end
    local offset = valid_cursor(request.cursor)
    if not offset then return nil, fault("INVALID", "catalog cursor is invalid", "never") end

    local pinned, pin_error = harness_catalog.pin()
    if not pinned then return nil, fault("UNAVAILABLE", pin_error or "Registry catalog is unavailable.", "refresh") end
    local version = pinned:version()
    local generation = version and (bounds.count(version:id()) or 1) or 1
    local locate_cache, cache_error = locate.new(30000)
    if not locate_cache then return nil, fault("INTERNAL", cache_error or "Readiness cache could not be created.", "never") end
    local readiness_cache = readiness.new_cache()
    local candidates: {locate.Candidate} = {}
    local diagnostics: {Fault} = {}
    local unavailable = 0
    local show_unavailable = request.include_unavailable == true

    if kind == nil or kind == "definition" then
        local found, find_error = pinned:find({["meta.type"] = definition.TYPE})
        if find_error or not found then return nil, fault("UNAVAILABLE", find_error and tostring(find_error) or "Launch definitions could not be read.", "refresh") end
        if #found > M.MAX_DEFINITIONS then return nil, fault("UNAVAILABLE", "Launch definition catalog exceeds its bound.", "refresh") end
        for _, raw_entry in ipairs(found) do
            local entry = object(raw_entry)
            local ref = entry and bounds.id(entry.id) or nil
            if ref and entry and (not definition_filter or ref == definition_filter) then
                local title = bounds.text((object(entry.data) or {}).title, 512) or ref
                local candidate, candidate_error = candidate_for_definition(pinned, ref, entry, "definition", title,
                    nil, nil, workspace, locate_cache, readiness_cache, generation)
                if candidate then
                    if candidate.status == "ready" or show_unavailable then candidates[#candidates + 1] = candidate end
                    if candidate.status ~= "ready" then unavailable = unavailable + 1 end
                else
                    diagnostics[#diagnostics + 1] = fault("UNAVAILABLE", candidate_error or "A launch definition could not be measured.", "refresh")
                end
            end
        end
    end

    local profiles_incomplete = false
    if kind == nil or kind == "profile" then
        local rows, _, profile_failure = profile_rows(workspace, definition_filter, query, sort)
        if profile_failure then
            profiles_incomplete = true
            diagnostics[#diagnostics + 1] = diagnostic_from(profile_failure)
        end
        for _, row in ipairs(rows or {}) do
            if row.migration_diagnostic then
                local draft = bounds.object(row.migration_diagnostic.draft) or {}
                local candidate = unavailable_candidate(locate_cache, "profile", row.profile_id,
                    bounds.line(draft.name, 80) or "Profile needs migration repair", row.revision,
                    "unknown", "Migration diagnostic: edit this profile before launching", generation)
                if candidate then
                    if show_unavailable then candidates[#candidates + 1] = candidate end
                    unavailable = unavailable + 1
                end
            elseif not row.tombstone and row.profile then
                local profile = row.profile
                local entry = harness_catalog.entry(pinned, profile.definition_ref)
                if not entry then
                    local candidate = unavailable_candidate(locate_cache, "profile", row.profile_id, profile.name,
                        row.revision, "missing", "The profile's launch definition is not installed.", generation)
                    if candidate then
                        if show_unavailable then candidates[#candidates + 1] = candidate end
                        unavailable = unavailable + 1
                    end
                else
                    local candidate, candidate_error = candidate_for_definition(pinned, profile.definition_ref, entry,
                        "profile", profile.name, row.revision, row.profile_id, workspace, locate_cache,
                        readiness_cache, generation)
                    if candidate then
                        if candidate.status == "ready" or show_unavailable then candidates[#candidates + 1] = candidate end
                        if candidate.status ~= "ready" then unavailable = unavailable + 1 end
                    else
                        diagnostics[#diagnostics + 1] = fault("UNAVAILABLE", candidate_error or "A saved profile could not be measured.", "refresh")
                    end
                end
            end
        end
    end

    if query and query ~= "" then
        local filtered: {locate.Candidate} = {}
        for _, candidate in ipairs(candidates) do
            if candidate.title:lower():find(query:lower(), 1, true) or candidate.ref:lower():find(query:lower(), 1, true) then filtered[#filtered + 1] = candidate end
        end
        candidates = filtered
    end
    local function driver(candidate: locate.Candidate): string
        for _, feature in ipairs(candidate.features) do
            local name = feature:match("^driver:(.+)$")
            if name then return name end
        end
        return ""
    end
    table.sort(candidates, function(left: locate.Candidate, right: locate.Candidate): boolean
        if sort == "driver" and driver(left) ~= driver(right) then return driver(left) < driver(right) end
        if left.title ~= right.title then return left.title < right.title end
        if left.kind ~= right.kind then return left.kind < right.kind end
        return left.ref < right.ref
    end)
    local rows: {locate.Candidate} = {}
    local first = offset + 1
    local last = math.min(#candidates, offset + M.PAGE_SIZE)
    for index = first, last do rows[#rows + 1] = candidates[index] end
    local complete = last >= #candidates and not profiles_incomplete
    local next_cursor: string? = nil
    if last < #candidates then next_cursor = "catalog:" .. tostring(last) end
    local page, page_error = locate.page(rows, complete, diagnostics, next_cursor)
    if not page then return nil, fault("INTERNAL", page_error or "Catalog page could not be built.", "never") end
    local result: locate.Page = page
    result.unavailable_count = unavailable
    return result, nil
end

return M
