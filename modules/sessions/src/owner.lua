-- MIT. Sessions owns admission and the public session operations; Threads
-- remains the only durable store.
local bounds = require("bounds")
local journal = require("journal")
local admission = require("admission")
local catalog_service = require("catalog_service")
local driver_route = require("driver_route")
local registry = require("registry")
local security = require("security")
local M = {}

type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, error?: Object}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function fail(code: string, message: string, operation_key: string?): Reply
    local error: Object = {code = code, message = message, retry = "never"}
    if operation_key then error.operation_key = operation_key end
    return {ok = false, error = error}
end

local function unavailable(message: string, operation_key: string?): Reply
    local reply = fail("UNAVAILABLE", message, operation_key)
    local failure = reply.error
    if failure then failure.retry = "refresh" end
    return reply
end

local function succeed(value: unknown): Reply
    return {ok = true, value = value}
end

local function identity(): (string?, string?)
    local caller = security.actor()
    if not caller then return nil, nil end
    local id = bounds.id(caller:id())
    local meta = object(caller:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    if not id or not workspace then return nil, nil end
    return id, workspace
end

local function key(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 128 or value:find("%c") then return nil end
    return value
end

local function ref(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 256 or value:find("%c") then return nil end
    return value
end

local function snapshot(value: unknown): (Object?, string?)
    local row = object(value)
    if not row or type(row.session) ~= "string" or type(row.title) ~= "string"
        or type(row.state) ~= "string" or type(row.revision) ~= "number" then
        return nil, "Threads returned a malformed session snapshot"
    end
    local queued = type(row.queued) == "number" and row.queued or 0
    local active = type(row.active) == "number" and row.active or 0
    local uncertain = type(row.uncertain) == "number" and row.uncertain or 0
    local stalled = type(row.stalled) == "number" and row.stalled or 0
    local lifecycle = row.state
    if lifecycle ~= "active" and lifecycle ~= "suspended" and lifecycle ~= "closing" and lifecycle ~= "closed" then
        return nil, "Threads returned an unsupported session lifecycle"
    end
    local activity = "idle"
    if stalled > 0 then activity = "stalled"
    elseif uncertain > 0 then activity = "blocked"
    elseif active > 0 or queued > 0 then activity = "working" end
    local at = type(row.updated_at) == "string" and row.updated_at or row.created_at
    if type(at) ~= "string" then return nil, "Threads omitted the session timestamp" end
    return {session = row.session, revision = row.revision, incarnation = 1, title = row.title,
        lifecycle = lifecycle, activity = activity,
        execution = {state = active > 0 and "running" or "quiescent", evidence_at = at, stale = false},
        queue_count = queued, effective_limits = {}, continuity = {mode = "provider_resume"}, actions = {}}, nil
end

local function describe(session: string): (Object?, string?)
    local value, err = journal.invoke("session_describe", {session = session})
    if err or not value then return nil, err or "Threads returned no session" end
    return snapshot(value)
end

local function driver_options(policy_ref: string): (Object?, string?)
    local entry, entry_error = registry.get(policy_ref)
    local data = entry and object(entry.data)
    local options = data and object(data.prepare_options)
    if entry_error or not options then return nil, "launch policy omits driver preparation options" end
    return options, nil
end

local function open(request: Object): Reply
    local operation_key = key(request.operation_key)
    local spec = object(request.spec)
    if not operation_key or not spec or bounds.fields(spec, {"definition", "profile", "workdir"}) then
        return fail("INVALID", "open requires a definition, optional profile/workdir, and operation_key", operation_key)
    end
    local definition = ref(spec.definition)
    if not definition then return fail("INVALID", "definition is not a ref", operation_key) end
    local profile = object(spec.profile)
    local profile_id: string? = nil
    local profile_revision: integer? = nil
    if spec.profile ~= nil then
        if not profile or bounds.fields(profile, {"id", "revision"}) then return fail("INVALID", "profile is malformed", operation_key) end
        profile_id = ref(profile.id)
        profile_revision = bounds.integer(profile.revision)
        if not profile_id or not profile_revision or profile_revision < 1 then return fail("INVALID", "profile is malformed", operation_key) end
    end
    local workdir: string? = nil
    if spec.workdir ~= nil then
        workdir = ref(spec.workdir)
        if not workdir then return fail("INVALID", "workdir is not a resource ref", operation_key) end
    end
    local _, workspace = identity()
    if not workspace then return fail("DENIED", "the authenticated caller has no workspace", operation_key) end
    local plan, refused = admission.resolve(definition, nil, workspace, profile_id, profile_revision)
    if not plan then
        local fault = object(refused)
        local details = fault and object(fault.error)
        return fail(details and tostring(details.code or "UNAVAILABLE") or "UNAVAILABLE",
            details and tostring(details.message or "admission refused the session") or "admission refused the session", operation_key)
    end
    local plan_value = object(plan)
    local driver_binding_ref = plan_value and ref(plan_value.binding_ref)
    local profile_ref = plan_value and ref(plan_value.profile_id)
    if not plan_value or not driver_binding_ref or not profile_ref then
        return unavailable("admission returned an incomplete executor route", operation_key)
    end
    if plan_value.mode ~= "session" then
        return fail("UNSUPPORTED", "the selected launch definition does not provide a session profile", operation_key)
    end
    local methods, methods_error = driver_route.resolve(driver_binding_ref)
    if not methods then return unavailable(methods_error or "selected driver methods are unavailable", operation_key) end
    local policy_ref = ref(plan_value.policy_ref)
    if not policy_ref then return unavailable("admission omitted the selected launch policy", operation_key) end
    local options, options_error = driver_options(policy_ref)
    if not options then return unavailable(options_error or "launch policy is unavailable", operation_key) end
    local placement_methods = object(plan_value.placement_methods)
    if not placement_methods then return unavailable("admission omitted placement operations", operation_key) end
    local route: Object = {definition = definition, plan_digest = plan_value.plan_digest,
        driver_binding_ref = driver_binding_ref, profile_id = profile_ref, driver_methods = methods, driver_options = options,
        placement_methods = placement_methods, placement_request = {binding_ref = driver_binding_ref,
            profile_id = profile_ref, workspace_id = workspace, workdir = workdir}}
    local created, create_error = journal.invoke("session_create", {operation_key = operation_key,
        title = plan_value.title or definition, route = route})
    if create_error or not created then return unavailable(create_error or "Threads returned no open receipt", operation_key) end
    local receipt = object(created)
    local session = receipt and ref(receipt.session)
    local operation = receipt and ref(receipt.operation)
    if not session or not operation then return unavailable("Threads returned a malformed open receipt", operation_key) end
    local current, read_error = describe(session)
    if not current then return unavailable(read_error or "cannot read the opened session", operation_key) end
    return succeed({session = session, operation = operation, snapshot = current})
end

local function send(request: Object): Reply
    local operation_key = key(request.operation_key)
    local session = ref(request.session)
    if not operation_key or not session or request.input == nil
        or bounds.fields(request, {"session", "input", "output", "expected_incarnation", "operation_key"}) then
        return fail("INVALID", "send requires session, input, and operation_key", operation_key)
    end
    if request.expected_incarnation ~= nil and request.expected_incarnation ~= 1 then
        return fail("STALE", "session incarnation changed", operation_key)
    end
    local current, read_error = describe(session)
    if not current then return fail("NOT_FOUND", read_error or "session is unavailable", operation_key) end
    if current.lifecycle ~= "active" then return fail("CONFLICT", "session is not accepting work", operation_key) end
    local output_schema = request.output == nil and "bee:Text@1" or ref(request.output)
    if not output_schema then return fail("INVALID", "output must be a schema ref", operation_key) end
    local receipt, send_error = journal.invoke("work_send", {session = session, operation_key = operation_key,
        input = request.input, output_schema = output_schema})
    if send_error or not receipt then return unavailable(send_error or "Threads returned no work receipt", operation_key) end
    return succeed(receipt)
end

local function work_value(value: unknown): (Object?, string?)
    local row = object(value)
    if not row or not ref(row.work) or not ref(row.session) or not bounds.integer(row.revision)
        or (row.phase ~= "queued" and row.phase ~= "reserved" and row.phase ~= "accepted" and row.phase ~= "settled")
        or not object(row.sender) then return nil, "Threads returned a malformed work row" end
    local state: Object = {work = row.work, session = row.session, sender = row.sender,
        revision = row.revision, cancelling = false, phase = row.phase}
    if row.uncertainty ~= nil then
        state.uncertainty = {summary = tostring((object(row.uncertainty) or {}).summary or "turn outcome is uncertain"), artifacts = {}}
    end
    if row.result ~= nil then
        local result = object(row.result)
        if not result then return nil, "Threads returned a malformed work result" end
        local outcome = result.state
        if outcome == "succeeded" then
            state.phase = "settled"
            state.result = {outcome = outcome, schema = result.schema or row.output_schema,
                value = result.value, artifacts = result.artifacts or {}, usage = result.usage or {}}
        elseif outcome == "failed" or outcome == "cancelled" or outcome == "expired" or outcome == "rejected" then
            local failure = object(result.error) or {}
            state.phase = "settled"
            state.cancelling = false
            state.result = {outcome = outcome, error = {code = failure.code or "EXECUTOR_FAILED",
                message = failure.message or "the executor failed", retry = "never"}, artifacts = result.artifacts or {}}
        else
            return nil, "Threads returned an unsupported result state"
        end
    end
    return state, nil
end

local function session_get(request: Object): Reply
    if bounds.fields(request, {"session", "work"}) then return fail("INVALID", "get accepts a session or work ref") end
    if request.session ~= nil then
        local session = ref(request.session)
        if not session or request.work ~= nil then return fail("INVALID", "get needs exactly one subject") end
        local value, err = describe(session)
        if not value then return unavailable(err or "session is unavailable", nil) end
        return succeed({kind = "session", value = value})
    end
    local work = ref(request.work)
    if not work then return fail("INVALID", "get needs exactly one subject") end
    local value, err = journal.invoke("work_describe", {work = work})
    if err or not value then return unavailable(err or "work is unavailable", nil) end
    local state, decode_error = work_value(value)
    if not state then return unavailable(decode_error or "work is malformed", nil) end
    return succeed({kind = "work", value = state})
end

local function await(request: Object): Reply
    local subject = ref(request.subject)
    if not subject or bounds.fields(request, {"subject", "timeout_ms"}) then return fail("INVALID", "await needs a work or operation ref") end
    if subject:sub(1, 3) == "bw:" then
        local value, err = journal.invoke("work_describe", {work = subject})
        if err or not value then return unavailable(err or "work is unavailable", nil) end
        local row = object(value)
        local state = row and work_value(row)
        if not state then return unavailable("Threads returned a malformed work state", nil) end
        local result = object((state :: Object).result)
        if result then
            return succeed({subject_kind = "work", subject = subject, cursor = tostring((state :: Object).revision),
                tag = "ready", result = result})
        end
        local uncertainty = object((state :: Object).uncertainty)
        if uncertainty then return succeed({subject_kind = "work", subject = subject,
            cursor = tostring((state :: Object).revision), tag = "uncertain", evidence = uncertainty}) end
        return succeed({subject_kind = "work", subject = subject, cursor = tostring((state :: Object).revision),
            tag = "pending", reason = "timeout"})
    end
    return fail("UNAVAILABLE", "operation observations are not available", nil)
end

local function not_ready(_: Object): Reply
    return fail("UNAVAILABLE", "session operation is not yet available", nil)
end

local function catalog(request: Object): Reply
    local _, workspace = identity()
    if not workspace then return fail("DENIED", "the authenticated caller has no workspace", nil) end
    local page, catalog_error = catalog_service.list(request, workspace)
    if not page then return fail("INVALID", catalog_error or "catalog request is invalid", nil) end
    return succeed(page)
end

local function list(request: Object): Reply
    if bounds.fields(request, {filter = true, cursor = true}) then return fail("INVALID", "list accepts only filter and cursor") end
    local filter = object(request.filter)
    if request.filter ~= nil and (not filter or bounds.fields(filter, {lifecycle = true, activity = true})) then
        return fail("INVALID", "session filter is malformed")
    end
    local lifecycle = filter and filter.lifecycle or nil
    if lifecycle ~= nil and lifecycle ~= "opening" and lifecycle ~= "active" and lifecycle ~= "suspended"
        and lifecycle ~= "closing" and lifecycle ~= "closed" then return fail("INVALID", "lifecycle filter is invalid") end
    local activity = filter and filter.activity or nil
    if activity ~= nil and activity ~= "idle" and activity ~= "working" and activity ~= "blocked" and activity ~= "stalled" then
        return fail("INVALID", "activity filter is invalid")
    end
    local cursor = request.cursor == nil and nil or ref(request.cursor)
    if request.cursor ~= nil and not cursor then return fail("INVALID", "cursor is invalid") end
    local page, scan_error = journal.invoke("session_scan", {cursor = cursor, limit = 64})
    if scan_error or not page then return unavailable(scan_error or "Threads returned no session page", nil) end
    local scan = object(page)
    local refs = scan and scan.items
    if type(refs) ~= "table" then return unavailable("Threads returned a malformed session page", nil) end
    local items: {Object} = {}
    for _, raw_ref in ipairs(refs :: {unknown}) do
        local session = ref(raw_ref)
        if not session then return unavailable("Threads returned a malformed session ref", nil) end
        local current, read_error = describe(session)
        if not current then return unavailable(read_error or "cannot read a listed session", nil) end
        if (lifecycle == nil or current.lifecycle == lifecycle) and (activity == nil or current.activity == activity) then
            items[#items + 1] = current
        end
    end
    return succeed({items = items, next = scan and ref(scan.next) or nil})
end

function M.call(method: string, request: unknown): Reply
    local input = object(request)
    if not input then return fail("INVALID", "request must be an object", nil) end
    if method == "open" then return open(input) end
    if method == "run" then
        local operation_key = key(input.operation_key)
        local opened = open({spec = input.spec, operation_key = operation_key})
        if not opened.ok then return opened end
        local receipt = object(opened.value)
        if not receipt then return unavailable("open returned no session receipt", operation_key) end
        return send({session = receipt.session, input = input.input, output = input.output,
            expected_incarnation = 1, operation_key = operation_key})
    end
    if method == "send" then return send(input) end
    if method == "get" then return session_get(input) end
    if method == "await" then return await(input) end
    if method == "list" then return list(input) end
    if method == "catalog" then return catalog(input) end
    if method == "join" or method == "cancel" or method == "close" then
        return not_ready(input)
    end
    return fail("UNSUPPORTED", "unknown sessions operation", nil)
end

return M
