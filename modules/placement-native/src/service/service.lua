-- MIT. The native placement operations. Every operation authenticates the
-- owner, reads the recorded attempt, and changes it only through a
-- transition with evidence. The runner does the external work.
local process = require("process")
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local security = require("security")
local uuid = require("uuid")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local request_codec = require("request")
local transitions = require("transitions")
local store = require("store")
local executable = require("executable")
local resources = require("resources")
local capability = require("capability")
local homes = require("homes")
local identity = require("identity")
local protocol = require("protocol")
local registry = require("registry")
local gateway_configuration = require("gateway_configuration")
local resolver = require("resolver")
local placement_resolver = require("placement_resolver")
local configuration_protocol = require("configuration")
local preferences = require("preferences")
local materialization = require("materialization")
local M = {}
M.SWEEP_INTERVAL_MS = 30000
M.RECONCILE_TIMEOUT_MS = 5000
M.SWEEP_BOUND = 64
M.SWEEPER_NAME = "bee.placement.sweeper"
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end
local function actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function owned(attempt: types.Attempt): Reply?
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if caller ~= attempt.owner_id then return fail("FORBIDDEN", "the attempt belongs to another owner") end
    return nil
end
local function load(attempt_id: unknown): (types.Attempt?, Reply?, store.Row?)
    local id = bounds.id(attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    local db, open_error = store.open()
    if not db then return nil, fail("STORAGE", open_error or "open placement store") end
    local attempt, read_error = store.attempt(db, id)
    local row = store.row(db, id)
    db:release()
    if read_error then return nil, fail("STORAGE", read_error) end
    if not attempt then return nil, fail("NOT_FOUND", "attempt is not recorded") end
    local denied = owned(attempt)
    if denied then return nil, denied end
    return attempt, nil, row
end
-- Requests that name only an attempt: {attempt_id}.
local function named(value: unknown): (string?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id"})
    if unknown_field then return nil, fail("INVALID", unknown_field) end
    local id = bounds.id(object.attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    return id, nil
end
local function transition(attempt_id: string, update: store.Update): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local result = store.transition(db, attempt_id, update)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "transition failed") end
    return succeed(result.attempt)
end
local function recorded_identity(attempt_id: string): (identity.Identity?, string?, store.Row?)
    local db, open_error = store.open()
    if not db then return nil, open_error, nil end
    local row, row_error = store.row(db, attempt_id)
    db:release()
    if not row then return nil, row_error or "attempt is not recorded", nil end
    local pid = row.pid
    if type(pid) ~= "number" then return nil, nil, row end
    local ticks: integer? = nil
    if type(row.start_ticks) == "number" then ticks = math.floor(row.start_ticks :: number) end
    local pgid: integer? = nil
    if type(row.pgid) == "number" then pgid = math.floor(row.pgid :: number) end
    local boot: string? = nil
    if type(row.boot_id) == "string" then boot = row.boot_id :: string end
    return {pid = math.floor(pid), pgid = pgid, start_ticks = ticks, boot_id = boot}, nil, row
end
type Resolved = {grant_id: string, root_ref: string, root_digest: string, subpath: string, access: string, association_revision: integer, expires_at: string}
-- Resolves one grant through the resource authority for the owner this
-- placement admitted; the reply's own code is the refusal.
local function resolve_grant(request: types.LaunchRequest, grant: types.ResourceGrant): (Resolved?, Reply?)
    local raw, call_error = funcs.call(resources.RESOLVE, {grant_id = grant.grant_ref, subject = request.owner_id, audience = request.owner_id, attempt_id = request.attempt_id})
    if call_error or type(raw) ~= "table" then return nil, fail("UNAVAILABLE", "resource authority did not answer for grant " .. grant.grant_ref) end
    local reply = raw :: Reply
    if not reply.ok then return nil, fail(reply.error and reply.error.code or "DENIED", "grant " .. grant.grant_ref .. ": " .. tostring(reply.error and reply.error.message)) end
    local resolved = reply.value :: {[string]: unknown}
    local access = tostring(resolved.access)
    if grant.access == "write" and access ~= "write" then return nil, fail("FORBIDDEN", "grant " .. grant.grant_ref .. " allows " .. access .. " only") end
    return {grant_id = grant.grant_ref, root_ref = tostring(resolved.root_ref), root_digest = tostring(resolved.root_digest), subpath = tostring(resolved.subpath),
        access = grant.access, association_revision = math.floor(resolved.association_revision :: number), expires_at = tostring(resolved.expires_at)}, nil
end
-- In granted mode every grant is resolved and the caller's concrete root
-- is replaced by the authority's; in host_configured mode the caller's root
-- is checked against the host list. The host selects the mode.
local function admit_resources(request: types.LaunchRequest): ({Resolved}?, Reply?)
    local mode = resources.resource_mode()
    local resolved_list: {Resolved} = {}
    if mode == "granted" then
        for _, grant in ipairs(request.resources) do
            local resolved, refused = resolve_grant(request, grant)
            if not resolved then return nil, refused end
            grant.root_ref = resolved.root_ref
            grant.subpath = resolved.subpath
            resolved_list[#resolved_list + 1] = resolved
        end
        return resolved_list, nil
    end
    local roots, roots_error = resources.admitted_roots()
    if not roots then return nil, fail("STORAGE", roots_error or "admitted roots") end
    for _, grant in ipairs(request.resources) do
        local admitted = roots[grant.root_ref]
        if not admitted then return nil, fail("FORBIDDEN", "resource root " .. grant.root_ref .. " is not admitted on this host") end
        if grant.access == "write" and admitted ~= "write" then return nil, fail("FORBIDDEN", "resource root " .. grant.root_ref .. " is admitted read-only on this host") end
        local _, directory_error = resources.directory(grant.root_ref)
        if directory_error then return nil, fail("INVALID", directory_error) end
    end
    return resolved_list, nil
end
-- Checks one credential projection's bindings without bytes. File logins are
-- meaningful only in a caller-selected retained home: an attempt home would
-- discard them on cleanup.
local function check_projection(request: types.LaunchRequest, projection_id: string): (Reply?, string?)
    local raw, call_error = funcs.call(resources.CREDENTIAL_CHECK, {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id, attempt_id = request.attempt_id})
    if call_error or type(raw) ~= "table" then return fail("UNAVAILABLE", "credential broker did not answer for projection " .. projection_id), nil end
    local reply = raw :: Reply
    if not reply.ok then return fail(reply.error and reply.error.code or "DENIED", "projection " .. projection_id .. ": " .. tostring(reply.error and reply.error.code)), nil end
    local projection = bounds.object(reply.value)
    if not projection then return fail("DENIED", "projection " .. projection_id .. " has invalid metadata"), nil end
    if projection.projection_kind == "environment" then return nil, "environment" end
    if projection.projection_kind ~= "file" then return fail("DENIED", "projection " .. projection_id .. " has unsupported kind"), nil end
    if not request.session_ref or not request.launch.home_ref then
        return fail("DENIED", "file credential projections require a selected retained home"), nil
    end
    local source, source_error = homes.decode_login_source({provider = projection.provider,
        definition_id = projection.definition_id, definition_revision = projection.definition_revision, format = projection.format})
    if not source or projection.destination ~= (source.path:match("[^/]+$") :: string) then
        return fail("DENIED", "projection " .. projection_id .. " has invalid file login metadata"), nil
    end
    return nil, "file"
end
-- Checks the gateway binding an attempt holds under its attached carrier
-- epoch; bindings, never bytes.
local function check_gateway(row: store.Row, request: types.LaunchRequest): Reply?
    local carrier_epoch = type(row.attachment_generation) == "number" and math.floor(row.attachment_generation :: number) or 0
    if carrier_epoch < 1 then return fail("DENIED", "gateway binding: the attempt is not attached to a carrier") end
    local raw, call_error = funcs.call(resources.GATEWAY_CHECK, {attempt_id = request.attempt_id, carrier_epoch = carrier_epoch})
    if call_error or type(raw) ~= "table" then return fail("UNAVAILABLE", "the gateway did not answer for attempt " .. request.attempt_id) end
    local reply = raw :: {[string]: unknown}
    if reply.ok ~= true then
        local reply_error = bounds.object(reply.error)
        local reply_code = reply_error and type(reply_error.code) == "string" and reply_error.code or "DENIED"
        local reply_message = reply_error and type(reply_error.message) == "string" and reply_error.message or "gateway refused"
        return fail(reply_code, "gateway binding: " .. reply_message)
    end
    local checked = bounds.object(reply.value) or {}
    if checked.valid ~= true then return fail("DENIED", "gateway binding: " .. tostring(checked.reason)) end
    return nil
end
-- Retires the gateway bindings an attempt holds at or below its attached
-- carrier epoch; the placement supervision owns this independently of any
-- carrier, and the epoch fence keeps a later carrier's binding alive.
local function retire_gateway(attempt: types.Attempt, why: string)
    local db = store.open()
    if not db then return end
    local row = store.row(db, attempt.attempt_id)
    local request = row and store.request(row) or nil
    db:release()
    if not request or not request.gateway or attempt.attachment_generation < 1 then return end
    local raw, call_error = funcs.call(resources.GATEWAY_REVOKE_ATTEMPT, {attempt_id = attempt.attempt_id, carrier_epoch = attempt.attachment_generation})
    local reply = type(raw) == "table" and raw :: {[string]: unknown} or nil
    local detail = why .. "; bindings through carrier epoch " .. tostring(attempt.attachment_generation)
    if call_error or not reply or reply.ok ~= true then
        local reply_error = reply and bounds.object(reply.error)
        local reply_code = reply_error and type(reply_error.code) == "string" and reply_error.code or nil
        detail = detail .. " not revoked: " .. tostring(call_error or reply_code or "no answer")
        transition(attempt.attempt_id, {evidence = {kind = "gateway.revoke_failed", detail = detail}})
        return
    end
    transition(attempt.attempt_id, {evidence = {kind = "gateway.revoked", detail = detail}})
end
-- Rechecks every recorded grant, projection and gateway binding of an
-- attempt; nil means all still hold. The second value names what failed.
local function recheck_grants(row: store.Row, request: types.LaunchRequest): (Reply?, string?)
    if resources.resource_mode() == "granted" then
        for _, grant in ipairs(request.resources) do
            local _, refused = resolve_grant(request, grant)
            if refused then return refused, "grant" end
        end
    end
    local file_projection = false
    for _, projection_id in ipairs(request.projections) do
        local refused, kind = check_projection(request, projection_id)
        if refused then return refused, "credential" end
        if kind == "file" then
            if file_projection then return fail("DENIED", "only one file credential projection may select a retained home"), "credential" end
            file_projection = true
        end
    end
    if request.gateway then
        local refused = check_gateway(row, request)
        if refused then return refused, "gateway" end
    end
    return nil, nil
end
-- Host HOME is a policy decision, not a property of the caller's request.
-- Check the pinned policy at every native authorization boundary so a policy
-- update cannot turn an already-recorded request into an unapproved launch.
local function host_home_authorization(pinned: registry.Snapshot, request: types.LaunchRequest): string?
    if request.environment_refs.HOME ~= "bee.environment:machine_home" then return nil end
    local policy_entry = resolver.entry(pinned, request.policy_ref)
    local policy_meta = policy_entry and bounds.object(policy_entry.meta) or {}
    local policy_data = policy_entry and bounds.object(policy_entry.data) or nil
    if not policy_entry or policy_meta.type ~= types.LAUNCH_POLICY_TYPE or not policy_data or policy_data.allow_host_home ~= true then
        return "launch policy does not authorize host HOME"
    end
    return nil
end
-- Authorizes one concrete execution path after its recorded grants have been
-- rechecked.  Both the ordinary runner and the native window use this seam;
-- callers never supply a gateway materialization key as authority.
function M.authorize_materialization(attempt: types.Attempt, row: store.Row, request: types.LaunchRequest, gateway_binding: string?): (string?, Reply?)
    if request.environment_refs.HOME == "bee.environment:machine_home" then
        local pinned, pin_error = resolver.pin()
        if not pinned then
            return nil, fail("UNAVAILABLE", pin_error or "pin registry for HOME authorization")
        end
        local home_authorization_error = host_home_authorization(pinned, request)
        if home_authorization_error then
            transition(attempt.attempt_id, {evidence = {kind = "environment.refused", detail = "at start: " .. home_authorization_error}})
            return nil, fail("DENIED", home_authorization_error)
        end
    end
    local refused, subject = recheck_grants(row, request)
    if refused then
        transition(attempt.attempt_id, {evidence = {kind = tostring(subject) .. ".refused", detail = "at start: " .. tostring(refused.error and refused.error.code) .. ": " .. tostring(refused.error and refused.error.message)}})
        return nil, refused
    end
    -- Materialization is authorized here, for this start, with a one-time
    -- key the execution owner alone receives. The carrier-recorded binding
    -- must be the one the attempt holds under its attached carrier epoch.
    if not request.gateway then return nil, nil end
    if not gateway_binding then return nil, fail("INVALID", "gateway_binding is required for a launch with a gateway binding") end
    local carrier_epoch = bounds.integer(row.attachment_generation) or 0
    local raw, call_error = funcs.call(resources.GATEWAY_AUTHORIZE, {attempt_id = attempt.attempt_id, carrier_epoch = carrier_epoch, binding_id = gateway_binding, ttl_ms = math.max(1000, request.timeouts.start_ms)})
    local reply = type(raw) == "table" and raw :: {[string]: unknown} or nil
    if call_error or not reply or reply.ok ~= true then
        local reply_error = reply and bounds.object(reply.error)
        local fault_code = reply_error and type(reply_error.code) == "string" and reply_error.code or "UNAVAILABLE"
        local fault_message = reply_error and type(reply_error.message) == "string" and reply_error.message or tostring(call_error or "no answer")
        transition(attempt.attempt_id, {evidence = {kind = "gateway.refused", detail = "materialization authorization: " .. fault_code .. ": " .. fault_message}})
        return nil, fail(fault_code, "gateway materialization authorization: " .. fault_message)
    end
    local materialization_key = bounds.id((bounds.object(reply.value) or {}).materialization_key)
    if not materialization_key then
        transition(attempt.attempt_id, {evidence = {kind = "gateway.refused", detail = "materialization authorization returned no key"}})
        return nil, fail("UNAVAILABLE", "gateway materialization authorization returned no key")
    end
    return materialization_key, nil
end
-- Configuration inputs come from one host snapshot, not caller-authored
-- files. The renderer receives the final owner-derived HOME only when a new
-- intent is recorded; replay uses that intent's frozen delivery.
local function configuration_input(pinned: registry.Snapshot, request: types.LaunchRequest): (configuration_protocol.Request?, string?, string?)
    local policy_entry = resolver.entry(pinned, request.policy_ref)
    local policy_meta = policy_entry and bounds.object(policy_entry.meta) or {}
    local data = policy_entry and bounds.object(policy_entry.data) or nil
    if not policy_entry or policy_meta.type ~= types.LAUNCH_POLICY_TYPE or not data then return nil, nil, "policy_ref is not a host launch policy" end
    if request.preferences then
        local effective, preference_error = preferences.apply(data, request.preferences)
        if not effective then return nil, nil, preference_error end
        data = effective
    end
    -- The operation target cannot override the host's selected placement.
    if data.placement_binding ~= nil and data.placement_binding ~= "bee.placement.native:binding" then
        return nil, nil, "launch policy does not select native placement"
    end
    if data.placement_options ~= nil then
        return nil, nil, "native placement does not support placement_options"
    end
    local instructions, instructions_error = configuration_protocol.instructions(data.instructions)
    if instructions_error then return nil, nil, instructions_error end
    local instruction_builder, builder_error = configuration_protocol.instruction_builder(data.instruction_builder)
    if builder_error then return nil, nil, "launch policy " .. builder_error end
    local provider_ref = data.provider_ref == nil and nil or bounds.id(data.provider_ref)
    if data.provider_ref ~= nil and not provider_ref then return nil, nil, "launch policy provider_ref is not an identifier" end
    local target, target_error = resolver.configure(pinned, request.binding_ref)
    if not target then return nil, nil, target_error or "binding is not activated" end
    local provider: {[string]: unknown}? = nil
    if provider_ref then
        provider = resolver.entry(pinned, provider_ref)
        if not provider then return nil, nil, "launch policy provider is not in the registry" end
    end
    local tools, tools_error = bounds.ids(data.gateway_tools == nil and {} or data.gateway_tools, true)
    if not tools then return nil, nil, "launch policy gateway_tools: " .. tostring(tools_error) end
    local hooks, hooks_error = bounds.ids(data.gateway_hooks == nil and {} or data.gateway_hooks, true)
    if not hooks then return nil, nil, "launch policy gateway_hooks: " .. tostring(hooks_error) end
    table.sort(tools); table.sort(hooks)
    local gateway: configuration_protocol.GatewayInput? = nil
    if #tools > 0 or #hooks > 0 then
        local endpoint, endpoint_error = gateway_configuration.endpoint()
        if not endpoint then return nil, nil, endpoint_error or "gateway endpoint" end
        local command_ref = data.hook_command_ref == nil and nil or bounds.id(data.hook_command_ref)
        if data.hook_command_ref ~= nil and (not command_ref or #hooks == 0) then return nil, nil, "hook_command_ref requires hooks and an env.variable identifier" end
        local hook_command, command_error = gateway_configuration.hook_command(command_ref)
        if command_error then return nil, nil, command_error end
        gateway = {hook_command = hook_command, endpoint = endpoint, action_id = request.action_id, tools = tools, hooks = hooks,
            token_environment = gateway_configuration.DESTINATION,
            hook_token_environment = #hooks > 0 and gateway_configuration.HOOK_DESTINATION or nil}
    end
    return {instructions = instructions, instruction_builder = instruction_builder, provider_ref = provider_ref, provider = provider, gateway = gateway, fixture = data.fixture == true}, target, nil
end
local function configured_home(request: types.LaunchRequest): (string?, string?)
    local path: string? = nil
    if request.launch.home_ref and request.session_ref then
        local key, err = homes.session_key(request.owner_id, request.session_ref)
        if not key then return nil, err end
        path = "/" .. homes.SESSIONS .. "/" .. key .. "/home"
    else
        local key, err = homes.attempt_key(request.owner_id, request.attempt_id)
        if not key then return nil, err end
        path = "/" .. homes.ATTEMPTS .. "/" .. key .. "/home"
    end
    return homes.os_path(path)
end
-- prepare: validate the admitted request against this host, refuse what the
-- runtime cannot clean, record intent. Same key and digest replays.
function M.prepare(value: unknown): Reply
    local request, decode_error = request_codec.decode(value)
    if not request then return fail("INVALID", decode_error or "invalid launch request") end
    -- This implementation is one contract binding. A carrier may select a
    -- different placement, but it must never route that request into native
    -- materialization or create a native intent under the wrong identity.
    if request.placement_binding_ref and request.placement_binding_ref ~= placement_resolver.DEFAULT then
        return fail("DENIED", "native placement cannot prepare a non-native placement binding")
    end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if caller ~= request.owner_id then return fail("FORBIDDEN", "owner_id is not the caller") end
    local environment_conflict = materialization.environment_conflict(request)
    if environment_conflict then return fail("INVALID", environment_conflict) end
    -- A declared host file is available only from the inherited user home.
    -- Refuse the launch before intent when it is absent, rather than letting
    -- the executable start and fail. Existence only; contents are never read.
    local missing_file = materialization.required_file_missing(request)
    if missing_file then return fail("DENIED", missing_file) end
    local digest, digest_error = request_codec.digest(request)
    if not digest then return fail("INVALID", digest_error or "request is not measurable") end
    local resolved_grants, resources_refused = admit_resources(request)
    if not resolved_grants then return resources_refused :: Reply end
    local file_projection = false
    for _, projection_id in ipairs(request.projections) do
        local refused, kind = check_projection(request, projection_id)
        if refused then return refused end
        if kind == "file" then
            if file_projection then return fail("DENIED", "only one file credential projection may select a retained home") end
            file_projection = true
        end
    end
    local prepare_pinned, prepare_pin_error = resolver.pin()
    if not prepare_pinned then return fail("UNAVAILABLE", prepare_pin_error or "pin registry") end
    local selected_placement, placement_error = placement_resolver.resolve(prepare_pinned, request.placement_binding_ref)
    if not selected_placement then return fail("DENIED", placement_error or "native placement binding is unavailable") end
    if request.placement_binding_digest and request.placement_binding_digest ~= selected_placement.binding_digest then
        return fail("CONFLICT", "native placement binding changed since admission")
    end
    local configuration, configure_target, configuration_error = configuration_input(prepare_pinned, request)
    if not configuration or not configure_target then return fail("DENIED", configuration_error or "configuration inputs unavailable") end
    local home_authorization_error = host_home_authorization(prepare_pinned, request)
    if home_authorization_error then return fail("DENIED", home_authorization_error) end
    local measured = capability.measure()
    if not types.satisfies(measured.capability, request.required_cleanup) then
        return fail("UNSUPPORTED_CAPABILITY", "this runtime offers " .. measured.capability .. " (" .. measured.detail .. "); the launch requires " .. request.required_cleanup)
    end
    if not types.observes(measured.exit_observation, request.required_exit_observation) then
        return fail("UNSUPPORTED_CAPABILITY", "this runtime observes exit " .. measured.exit_observation .. "; the launch requires " .. request.required_exit_observation)
    end
    if request.launch.stdin_eof == true and not measured.stdin_close then
        return fail("UNSUPPORTED_CAPABILITY", "this runtime cannot close a child's stdin; the launch reads its input until end of file")
    end
    local selected_digest, selected_error = configuration_protocol.digest(configuration, configure_target)
    if not selected_digest then return fail("DENIED", selected_error or "configuration inputs are not measurable") end
    if request.configuration_digest then
        if request.configuration_digest ~= selected_digest then return fail("CONFLICT", "host configuration inputs changed since the launch plan") end
    elseif configuration.provider_ref or configuration.gateway or configuration.instructions or configuration.instruction_builder then
        return fail("DENIED", "configured launches require the selected configuration digest")
    end
    local selected_gateway = configuration.gateway
    local gateway = request.gateway
    if selected_gateway then
        if not gateway then return fail("DENIED", "launch policy requires its gateway binding") end
        if gateway.endpoint ~= selected_gateway.endpoint or gateway.destination ~= selected_gateway.token_environment
            or gateway.hook_destination ~= selected_gateway.hook_token_environment then
            return fail("DENIED", "gateway endpoint or credential destinations differ from the host selection")
        end
        local tools: {string} = {}
        local hooks: {string} = {}
        for index, item in ipairs(gateway.tools) do tools[index] = item end
        for index, item in ipairs(gateway.hooks) do hooks[index] = item end
        table.sort(tools); table.sort(hooks)
        if #tools ~= #selected_gateway.tools or #hooks ~= #selected_gateway.hooks then return fail("DENIED", "gateway tools or hooks differ from the host selection") end
        for index, item in ipairs(tools) do
            if item ~= selected_gateway.tools[index] then return fail("DENIED", "gateway tools differ from the host selection") end
        end
        for index, item in ipairs(hooks) do
            if item ~= selected_gateway.hooks[index] then return fail("DENIED", "gateway hooks differ from the host selection") end
        end
    elseif gateway then return fail("DENIED", "launch policy selects no gateway binding") end
    -- A launch line may allow gateway tools by name only within the admitted
    -- set: neither the client's own allow list nor a tool annotation is
    -- authorization, and a wider list is refused before anything runs.
    local admitted_tools: {[string]: boolean} = {}
    if request.gateway then
        for _, tool in ipairs(request.gateway.tools) do admitted_tools[tool] = true end
    end
    local argv = request.launch.argv
    for index, item in ipairs(argv) do
        local listed: string? = nil
        if item == "--allowedTools" or item == "--allowed-tools" then listed = argv[index + 1]
        elseif item:find("^%-%-allowed[%-]?[tT]ools=") then listed = item:match("=(.*)$") end
        for name in (listed or ""):gmatch("[^,%s]+") do
            if name:find("^mcp__" .. gateway_configuration.SERVER) then
                local tool = name:match("^mcp__" .. gateway_configuration.SERVER .. "__([a-z_]+)$")
                if not tool or not admitted_tools[tool] then return fail("DENIED", "the launch allows gateway tool " .. name .. " which the binding does not admit") end
            end
        end
    end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local existing, existing_error = store.by_key(db, request.owner_id, request.idempotency_key)
    if existing_error then
        db:release()
        return fail("STORAGE", existing_error)
    end
    if existing then
        local attempt = store.attempt(db, existing.attempt_id :: string)
        db:release()
        if existing.request_digest ~= digest then return fail("CONFLICT", "idempotency key reused with a different request") end
        return succeed(attempt)
    end
    local home_directory, home_error = configured_home(request)
    if not home_directory then db:release(); return fail("UNAVAILABLE", home_error or "configuration home unavailable") end
    configuration.home_directory = home_directory
    -- Placement supplies the measured attempt identity only while rendering
    -- private delivery. It is excluded from the host configuration digest and
    -- cannot be selected by the caller or saved profile.
    configuration.attempt_id = request.attempt_id
    local delivery, delivery_error = configuration_protocol.call(configure_target, configuration)
    if not delivery then db:release(); return fail("DENIED", delivery_error or "configuration rendering failed") end
    -- Keep the admitted request unchanged: its digest excludes this private
    -- delivery, while the durable payload includes the validated driver output.
    local stored: {[string]: unknown} = {}
    for key, value in pairs(request) do stored[key] = value end
    stored.delivery = delivery
    local encoded, encode_error = json.encode(stored)
    if not encoded then
        db:release()
        return fail("INVALID", "request is not encodable")
    end
    local grants_json: string? = nil
    if #resolved_grants > 0 then grants_json = json.encode(resolved_grants) end
    local result = store.intend(db, request, digest, encoded, {capability = measured.capability, exit_observation = measured.exit_observation}, grants_json)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "record intent") end
    return succeed(result.attempt)
end
-- start: spawn the runner and wait for its startup acknowledgment within
-- the admitted start budget. Idempotent: a live attempt returns its status.
function M.start(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "start request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "gateway_binding"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local gateway_binding: string? = nil
    if object.gateway_binding ~= nil then
        gateway_binding = bounds.id(object.gateway_binding)
        if not gateway_binding then return fail("INVALID", "gateway_binding is not an identifier") end
    end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return denied :: Reply end
    if attempt.execution_state ~= "intended" then return succeed(attempt) end
    local host, host_error = resources.runner_host()
    if not host then return fail("STORAGE", host_error or "runner host") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local row = store.row(db, attempt.attempt_id)
    local request = row and store.request(row) or nil
    db:release()
    if not request then return fail("STORAGE", "attempt request unreadable") end
    local materialization_key, authorization_denied = M.authorize_materialization(attempt, row :: store.Row, request, gateway_binding)
    if authorization_denied then return authorization_denied end
    local reply_topic = "bee.placement.start." .. (uuid.v7() or attempt.attempt_id)
    local replies = assert(process.listen(reply_topic, {message = true}))
    local events = assert(process.events())
    local runner, spawn_error = process.spawn(resources.RUNNER, host, attempt.attempt_id, process.pid(), reply_topic, gateway_binding, materialization_key)
    if not runner then
        process.unlisten(replies)
        return fail("UNAVAILABLE", "spawn runner: " .. tostring(spawn_error))
    end
    process.monitor(runner)
    local timer = time.after(tostring(request.timeouts.start_ms) .. "ms")
    local outcome: Reply? = nil
    while not outcome do
        local selected = channel.select({replies:case_receive(), events:case_receive(), timer:case_receive()})
        if not selected.ok then
            outcome = fail("UNAVAILABLE", "start interrupted")
        elseif selected.channel == replies then
            local message = selected.value
            if tostring(message:from()) == tostring(runner) then
                local data: unknown = message:payload():data()
                if type(data) == "table" and data.started == true then
                    outcome = succeed(data.attempt)
                else
                    local reason = type(data) == "table" and tostring(data.reason) or "runner refused"
                    outcome = fail("UNAVAILABLE", reason)
                end
            end
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == tostring(runner) then
                local reason = "runner exited before acknowledging startup"
                if event.result and event.result.error then reason = reason .. ": " .. tostring(event.result.error) end
                outcome = transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "runner.exited", detail = reason}})
                if outcome.ok then outcome = fail("UNCERTAIN", reason) end
            elseif event.kind == process.event.CANCEL then
                outcome = fail("UNAVAILABLE", "start cancelled")
            end
        else
            local current = load(attempt.attempt_id)
            outcome = succeed(current)
        end
    end
    process.unlisten(replies)
    process.unmonitor(runner)
    return outcome :: Reply
end
function M.status(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid :: Reply end
    local attempt, denied, row = load(id)
    if not attempt then return denied :: Reply end
    local liveness: types.Liveness = {observed = false, alive = nil, at = store.now(), detail = "no execution identity recorded"}
    local recorded = recorded_identity(attempt.attempt_id)
    if recorded then
        local observation = identity.observe(recorded)
        liveness = {observed = observation.observed, alive = observation.alive, at = store.now(), detail = observation.detail}
    end
    local private_home: boolean? = nil
    if attempt.session_ref then
        if not row then return fail("STORAGE", "retained placement row is unavailable") end
        local selected, selection_error = store.private_home(row)
        if selected == nil then return fail("STORAGE", selection_error or "read retained placement HOME selection") end
        private_home = selected
    end
    return succeed({attempt = attempt, liveness = liveness, private_home = private_home})
end
-- stop: the runner signals when it lives; otherwise the identified leader's
-- group is signalled, and an unidentified attempt becomes uncertain.
function M.stop(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "stop request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "mode"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local mode = bounds.member(object.mode == nil and "cooperative" or object.mode, types.STOP_MODES)
    if not mode then return fail("INVALID", "mode must be cooperative or forced") end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return denied :: Reply end
    return M.stop_attempt(attempt, mode)
end
-- stop_attempt is the owner-independent core shared with supervision.
function M.stop_attempt(attempt: types.Attempt, mode: string): Reply
    if attempt.execution_state == "intended" then
        -- Both runners must claim starting before materializing files or
        -- creating a child. Winning that same claim proves there is nothing
        -- to signal or remove and releases the retained session atomically.
        local stopped = transition(attempt.attempt_id, {expected_execution = "intended",
            execution = "exited", cleanup = "complete", evidence = {
                kind = "stop.before_start", detail = "stopped before runner claim; no child or attempt home was created"}})
        if stopped.ok or not stopped.error or stopped.error.code ~= "CONFLICT" then return stopped end
        -- Startup may have won. Use its recorded identity and normal stop
        -- path; never infer that the now-starting child is absent.
        local current, denied = load(attempt.attempt_id)
        if not current then return denied :: Reply end
        attempt = current
    end
    if not transitions.live(attempt.execution_state) then return succeed(attempt) end
    local recorded, _, row = recorded_identity(attempt.attempt_id)
    local runner = row and row.runner_pid or nil
    local db = store.open()
    local request = row and store.request(row) or nil
    if db then db:release() end
    local grace = request and request.timeouts.stop_grace_ms or request_codec.DEFAULT_STOP_GRACE_MS
    if type(runner) == "string" and runner ~= "" then
        -- The intent is recorded before the runner acts on it: a runner that
        -- observes the exit at once records exited next, and stopping is the
        -- only state that exit follows from here.
        local requested = transition(attempt.attempt_id, {execution = "stopping", evidence = {kind = "stop.requested", detail = mode .. " through the runner, grace " .. tostring(grace) .. " ms"}})
        if not requested.ok then
            local current = load(attempt.attempt_id)
            if current and not transitions.live(current.execution_state) then return succeed(current) end
            return requested
        end
        local sent = process.send(runner, protocol.TOPIC_CONTROL, {command = "stop", mode = mode, grace_ms = grace})
        if sent then return requested end
    end
    if recorded then
        local signal = mode == "forced" and 9 or 15
        local signalled, signal_error = identity.signal_group(recorded, signal)
        if signalled then
            return transition(attempt.attempt_id, {execution = "stopping", evidence = {kind = "signal.group", detail = "signal " .. tostring(signal) .. " to group " .. tostring(recorded.pgid) .. " without a runner"}})
        end
        return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "stop.unproven", detail = "no runner and the group cannot be signalled safely: " .. tostring(signal_error)}})
    end
    return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "stop.unproven", detail = "no runner and no execution identity"}})
end
-- measure_executable: a read-only measurement of one host path, for the
-- plan and the acceptance record; the runner repeats it before exec.
function M.measure_executable(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "measure_executable request must be an object") end
    local unknown_field = bounds.fields(object, {"path"})
    if unknown_field then return fail("INVALID", unknown_field) end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local measured, err = executable.measure(object.path)
    if not measured then return fail("UNAVAILABLE", err or "measurement failed") end
    return succeed(measured)
end
-- close_stdin: the owner ends a settled session whose harness reads stdin
-- until end of file; the runner closes it and answers, and its evidence
-- records closure apart from input acceptance and exit. Signalling and
-- cleanup stay with stop and cleanup.
function M.close_stdin(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "close_stdin request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return denied :: Reply end
    if not transitions.live(attempt.execution_state) then return fail("CONFLICT", "the attempt is not live") end
    local _, _, row = recorded_identity(attempt.attempt_id)
    local runner = row and row.runner_pid or nil
    if type(runner) ~= "string" or runner == "" then return fail("CONFLICT", "no runner supervises the attempt") end
    local probe, probe_error = uuid.v4()
    if probe_error or not probe then return fail("INTERNAL", "probe") end
    local expected: protocol.StatusProbe = {runner = runner, attempt_id = attempt.attempt_id, generation = attempt.attachment_generation, probe = probe}
    local replies = assert(process.listen(protocol.TOPIC_STDIN, {message = true}))
    process.send(runner, protocol.TOPIC_CONTROL, {command = "close_stdin", attempt_id = attempt.attempt_id, probe = probe})
    local timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")
    local answer: protocol.StdinReply? = nil
    while not answer do
        local selected = channel.select({replies:case_receive(), timer:case_receive()})
        if not selected.ok or selected.channel == timer then break end
        local message = selected.value
        local accepted = protocol.stdin_reply_accepted(tostring(message:from()), message:payload():data(), expected)
        if accepted then answer = accepted end
    end
    process.unlisten(replies)
    if not answer then return fail("CONFLICT", "the runner did not answer the stdin closure") end
    local current = load(attempt.attempt_id)
    return succeed({attempt = current or attempt, closed = answer.closed, reason = answer.reason})
end
-- reconcile: prove alive or gone from identity; keep uncertainty otherwise.
-- reconcile_attempt is the owner-independent core the supervision sweep
-- A runner that answers a typed status request for this attempt is
-- supervising it: that proves supervision and reports what the runner
-- observes, never that the child runs or that its scope is gone.
local function runner_status(row: store.Row?, attempt: types.Attempt): (string?, string?)
    local runner = row and row.runner_pid or nil
    if type(runner) ~= "string" or runner == "" then return nil, nil end
    local probe, probe_error = uuid.v4()
    if probe_error or not probe then return nil, nil end
    local expected: protocol.StatusProbe = {runner = runner, attempt_id = attempt.attempt_id, generation = attempt.attachment_generation, probe = probe}
    local replies = assert(process.listen(protocol.TOPIC_STATUS, {message = true}))
    process.send(runner, protocol.TOPIC_CONTROL, {command = "status", attempt_id = attempt.attempt_id, probe = probe})
    local timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")
    local detail: string? = nil
    local execution: string? = nil
    while true do
        local selected = channel.select({replies:case_receive(), timer:case_receive()})
        if not selected.ok or selected.channel == timer then break end
        local message = selected.value
        local status = protocol.status_reply_accepted(tostring(message:from()), message:payload():data(), expected)
        if status then
            execution = status.execution
            detail = "runner reports " .. status.execution .. ", generation " .. tostring(status.generation) .. ", eof " .. tostring(status.eof_seen) .. ", pending outputs " .. tostring(status.pending_outputs) .. ", remembered writes " .. tostring(status.remembered_writes)
            break
        end
    end
    process.unlisten(replies)
    return execution, detail
end
-- shares; M.reconcile authenticates the owner first.
function M.reconcile_attempt(attempt: types.Attempt): Reply
    if attempt.execution_state == "exited" or attempt.execution_state == "intended" then return succeed(attempt) end
    local recorded, _, row = recorded_identity(attempt.attempt_id)
    if not recorded then
        if attempt.execution_state == "uncertain" then return succeed(attempt) end
        local supervised, supervised_detail = runner_status(row, attempt)
        if supervised then
            local enforcement = M.enforce_grants(attempt)
            if enforcement then return enforcement end
            return transition(attempt.attempt_id, {evidence = {kind = "reconcile.supervised", detail = tostring(supervised_detail) .. "; no execution identity recorded"}})
        end
        retire_gateway(attempt, "attempt uncertain: no execution identity")
        return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "reconcile.unidentified", detail = "no execution identity to prove presence or absence"}})
    end
    local observation = identity.observe(recorded)
    if not observation.observed then
        if attempt.execution_state == "uncertain" then return succeed(attempt) end
        local supervised, supervised_detail = runner_status(row, attempt)
        if supervised then
            local enforcement = M.enforce_grants(attempt)
            if enforcement then return enforcement end
            return transition(attempt.attempt_id, {evidence = {kind = "reconcile.supervised", detail = tostring(supervised_detail) .. "; " .. observation.detail}})
        end
        retire_gateway(attempt, "attempt uncertain: " .. observation.detail)
        return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "reconcile.unobserved", detail = observation.detail}})
    end
    if observation.alive then
        local enforcement = M.enforce_grants(attempt)
        if enforcement then return enforcement end
        return transition(attempt.attempt_id, {evidence = {kind = "reconcile.alive", detail = observation.detail}})
    end
    retire_gateway(attempt, "leader absent")
    return transition(attempt.attempt_id, {execution = "exited", fields = {exit_source = "reconcile"}, evidence = {kind = "reconcile.absent", detail = observation.detail .. "; exit code unknown; leader absence only"}})
end
function M.reconcile(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid :: Reply end
    local attempt, denied = load(id)
    if not attempt then return denied :: Reply end
    return M.reconcile_attempt(attempt)
end
-- sweep: placement's own supervision reconciles every live attempt, which
-- bounds how long a revoked grant or projection stays in use.
function M.sweep(): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local rows, err = db:query("SELECT attempt_id FROM bee_placement_attempts WHERE execution_state IN ('starting', 'running', 'stopping') ORDER BY updated_at LIMIT ?", {M.SWEEP_BOUND})
    if err or not rows then
        db:release()
        return fail("STORAGE", "read live attempts")
    end
    local live: {types.Attempt} = {}
    for _, row in ipairs(rows) do
        local attempt = store.attempt(db, tostring(row.attempt_id))
        if attempt then live[#live + 1] = attempt end
    end
    db:release()
    local outcomes: {{attempt_id: string, ok: boolean, code: string?}} = {}
    for index, attempt in ipairs(live) do
        local result = M.reconcile_attempt(attempt)
        outcomes[index] = {attempt_id = attempt.attempt_id, ok = result.ok, code = result.error and result.error.code or nil}
    end
    return succeed({reconciled = #live, outcomes = outcomes})
end
-- The required cleanup scope must be proven gone before a home is removed:
-- the direct process by an observed exit or proven leader absence; a group
-- by no member answering; a contained tree by nothing this runtime offers.
local function scope_proven(attempt: types.Attempt, recorded: identity.Identity?): (boolean, string)
    if attempt.required_cleanup == "contained_tree" then return false, "no runtime here proves a contained tree" end
    if attempt.required_cleanup == "direct_process" then
        if attempt.exit_source == "runner" then return true, "exit observed by the runner" end
        if attempt.exit_source == "reconcile" then return true, "leader absence proven by identity" end
        return false, "exit not observed"
    end
    if not recorded or not recorded.pgid then return false, "no process group recorded" end
    local absent, probe_error = identity.group_absent(recorded.pgid)
    if absent == nil then return false, "group probe failed: " .. tostring(probe_error) end
    if not absent then return false, "processes remain in group " .. tostring(recorded.pgid) end
    return true, "no process remains in group " .. tostring(recorded.pgid)
end
-- A live attempt whose grant no longer resolves is stopped; enforcement
-- stays pending until the exit is proven.
function M.enforce_grants(attempt: types.Attempt): Reply?
    local db = store.open()
    if not db then return nil end
    local row = store.row(db, attempt.attempt_id)
    local request = row and store.request(row) or nil
    db:release()
    if not row or not request then return nil end
    local refused, subject = recheck_grants(row, request)
    if not refused then return nil end
    local noted = transition(attempt.attempt_id, {evidence = {kind = tostring(subject) .. ".revoked", detail = tostring(refused.error and refused.error.code) .. ": " .. tostring(refused.error and refused.error.message) .. "; stopping, enforcement pending"}})
    if not noted.ok then return noted end
    return M.stop_attempt(attempt, "cooperative")
end
-- cleanup: only a proven-exited attempt whose cleanup scope is proven gone
-- loses its home.
function M.cleanup(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid :: Reply end
    local attempt, denied = load(id)
    if not attempt then return denied :: Reply end
    if attempt.cleanup_state == "complete" then return succeed(attempt) end
    if not transitions.may_clean(attempt.execution_state) then return fail("CONFLICT", "cleanup needs a proven exit; execution is " .. attempt.execution_state) end
    local recorded, identity_error, row = recorded_identity(attempt.attempt_id)
    if identity_error then return fail("STORAGE", identity_error) end
    if not row then return fail("STORAGE", "attempt is not recorded") end
    local proven, why = scope_proven(attempt, recorded)
    -- Materialization can acknowledge a stop before creating any child. Its
    -- completion and this proof commit together in the existing evidence ledger.
    -- Missing identity alone is never proof; contradictory identity refuses it.
    if not proven and attempt.exit_source == "runner" and not recorded
        and row.pid == nil and row.pgid == nil and row.start_ticks == nil and row.boot_id == nil then
        local db, open_error = store.open()
        if not db then return fail("STORAGE", open_error or "open placement store") end
        local proofs, proof_error = db:query("SELECT sequence FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'child.not_started' LIMIT 1", {attempt.attempt_id})
        db:release()
        if proof_error then return fail("STORAGE", "read child creation evidence") end
        if proofs and #proofs == 1 then
            proven, why = true, "the runner recorded completion before creating a child"
        end
    end
    if not proven then
        -- A refusal is durable evidence: a continuation that waits on this
        -- cleanup reads its reason from the previous attempt's ledger.
        local message = "cleanup scope " .. attempt.required_cleanup .. " is not proven gone: " .. why
        local noted = transition(attempt.attempt_id, {evidence = {kind = "cleanup.refused", detail = message}})
        if not noted.ok then return noted end
        return fail("CONFLICT", message)
    end
    local home_key = row and row.home_key or nil
    if type(home_key) == "string" and home_key ~= "" then
        local remove_error = homes.remove_attempt(home_key)
        if remove_error then
            return transition(attempt.attempt_id, {cleanup = "uncertain", evidence = {kind = "cleanup.failed", detail = remove_error}})
        end
    end
    return transition(attempt.attempt_id, {cleanup = "complete", evidence = {kind = "cleanup.complete", detail = (home_key and "attempt home removed" or "no attempt home was created") .. "; " .. why}})
end
function M.evidence(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "evidence request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "after", "limit"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return denied :: Reply end
    local after = bounds.integer(object.after == nil and 0 or object.after)
    if not after or after < 0 then return fail("INVALID", "after must be a nonnegative integer") end
    local limit = bounds.integer(object.limit == nil and store.MAX_EVIDENCE_PAGE or object.limit)
    if not limit then return fail("INVALID", "limit must be an integer") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local page, page_error = store.evidence(db, attempt.attempt_id, after, limit)
    db:release()
    if not page then return fail("STORAGE", page_error or "read evidence") end
    return succeed(page)
end
-- attach: bind the recipient under a generation the owner supplies (its
-- carrier epoch); a generation at or below the current one is a stale
-- carrier and is refused. The runner resends what the previous recipient
-- never acknowledged.
function M.attach(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "attach request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "recipient", "generation"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local recipient = bounds.text(object.recipient, 256)
    if not recipient or recipient == "" then return fail("INVALID", "recipient must be a process address") end
    local generation = bounds.integer(object.generation)
    if not generation or generation < 1 then return fail("INVALID", "generation must be a positive integer") end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return denied :: Reply end
    -- A runner outlives an exited child while it holds unacknowledged
    -- output or an unanswered write, so an exited attempt is attachable
    -- exactly as long as its runner still answers the fence.
    local exited = attempt.execution_state == "exited"
    if not transitions.live(attempt.execution_state) and attempt.execution_state ~= "intended" and not exited then return fail("CONFLICT", "the attempt is not live") end
    if generation <= attempt.attachment_generation then return fail("CONFLICT", "generation " .. tostring(generation) .. " is not newer than " .. tostring(attempt.attachment_generation)) end
    local _, _, row = recorded_identity(attempt.attempt_id)
    local runner = row and row.runner_pid or nil
    if exited and (type(runner) ~= "string" or runner == "") then return fail("CONFLICT", "the attempt has exited and its runner is gone") end
    local result = transition(attempt.attempt_id, {fields = {attachment_generation = generation, recipient = recipient}, evidence = {kind = "attach", detail = "generation " .. tostring(generation)}})
    if not result.ok then return result end
    if type(runner) == "string" and runner ~= "" then
        -- The runner installs the generation before attach returns, so a
        -- caller holding the reply knows the previous recipient is fenced
        -- at the execution channel, not only at the thread.
        local fences = assert(process.listen(protocol.TOPIC_FENCED, {message = true}))
        process.send(runner, protocol.TOPIC_CONTROL, {command = "attach", recipient = recipient, generation = generation})
        local timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")
        local fenced = false
        local answered = false
        while not answered do
            local selected = channel.select({fences:case_receive(), timer:case_receive()})
            if not selected.ok or selected.channel == timer then
                answered = true
            else
                local message = selected.value
                local data: unknown = message:payload():data()
                if tostring(message:from()) == runner and type(data) == "table" and data.generation == generation then
                    answered = true
                    fenced = data.fenced == true
                end
            end
        end
        process.unlisten(fences)
        if not fenced then
            if exited then
                transition(attempt.attempt_id, {evidence = {kind = "attach.unanswered", detail = "runner gone after exit; generation " .. tostring(generation) .. " has nothing to attach to"}})
                return fail("CONFLICT", "the attempt has exited and its runner is gone")
            end
            return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "attach.unfenced", detail = "runner did not install generation " .. tostring(generation) .. " within " .. tostring(protocol.FENCE_TIMEOUT_MS) .. " ms"}})
        end
        return transition(attempt.attempt_id, {evidence = {kind = "attach.fenced", detail = "runner installed generation " .. tostring(generation)}})
    end
    return result
end
-- What this placement is: its measured capability, its interim authority
-- limits and its bounds. Roots are host policy, grants are correlation
-- data, and no credential broker exists yet.
function M.capabilities(): Reply
    local measured = capability.measure()
    local mode = resources.resource_mode()
    local measurement = executable.capabilities()
    return succeed({capability = measured.capability, exit_observation = measured.exit_observation, stdin_close = measured.stdin_close, detail = measured.detail,
        executable_measurement = {streaming = measurement.streaming, read_only_volume = measurement.read_only_volume, detail = measurement.detail},
        resource_authority = mode, delegated_resource_grants = mode == "granted",
        revocation_enforcement = {mode = "stop_on_reconcile", scheduling_delay_ms = M.SWEEP_INTERVAL_MS, reconcile_timeout_ms = M.RECONCILE_TIMEOUT_MS, stop_grace_ms = "per attempt", sweep_bound = M.SWEEP_BOUND},
        credential_broker = true, credential_projections = {"environment", "file"}, max_chunk_bytes = protocol.MAX_CHUNK_BYTES,
        gateway = {materialization = "placement_authorized_key", token_projection = "environment", takeover_grace_ms = protocol.TAKEOVER_GRACE_MS, seal_on = {"child_exit"}, revocation_on = {"refused_start", "carrier_loss_without_takeover", "reconcile_end", "carrier_close"},
            hook_events = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"}, shutdown_events_not_admitted = {"SessionEnd", "StopFailure"}},
        max_write_bytes = protocol.MAX_WRITE_BYTES, max_outstanding_chunks = protocol.MAX_OUTSTANDING_CHUNKS, max_spool_bytes = protocol.MAX_SPOOL_BYTES,
        max_evidence_page = store.MAX_EVIDENCE_PAGE, canonical = canonical.encode({capability = measured.capability})})
end
return M
