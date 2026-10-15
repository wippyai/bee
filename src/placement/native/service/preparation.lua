local configuration_types = require("configuration_types")
-- MIT. Native launch admission, resources and configuration preparation.
local funcs = require("funcs")
local json = require("json")
local bounds = require("bounds")
local types = require("types")
local request_codec = require("request")
local store = require("store")
local resources = require("resources")
local capability = require("capability")
local homes = require("homes")
local registry = require("registry")
local gateway_configuration = require("gateway_configuration")
local resolver = require("resolver")
local placement_resolver = require("placement_resolver")
local placement_profiles = require("placement_profiles")
local configuration_protocol = require("configuration")
local preferences = require("preferences")
local driver_types = require("driver_types")
local materialization = require("materialization")
local gateway_protocol = require("gateway_protocol")
local service_reply = require("service_reply")
local credential_protocol = require("credential_protocol")
local resource_resolution = require("resource_resolution")
local profile_values = require("profile_values")
local identity = require("identity")
local M = {}
type LocalPreparation = {binding: string, kind: string, spec_json: string, home_directory: string, capability: types.Capability, exit_observation: types.ExitObservation, stdin_close: boolean}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type DecodedReply = service_reply.Reply
type Access = "read" | "write"
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end
local function decode_reply(value: unknown): (DecodedReply?, string?)
    return service_reply.decode(value)
end
local actor = identity.actor

local function transition(attempt_id: string, update: store.Update): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local result = store.transition(db, attempt_id, update)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "transition failed") end
    return succeed(result.attempt)
end
type Resolved = {grant_id: string, root_ref: string, root_digest: string, subpath: string, access: Access, association_revision: integer, expires_at: string}
-- Resolves one grant through the resource authority for the owner this
-- placement admitted; the reply's own code is the refusal.
local function resolve_grant(request: types.LaunchRequest, grant: types.ResourceGrant): (Resolved?, Reply?)
    local raw, call_error = funcs.call(resources.RESOLVE, {grant_id = grant.grant_ref, subject = request.owner_id, audience = request.owner_id, attempt_id = request.attempt_id})
    if call_error then return nil, fail("UNAVAILABLE", "resource authority did not answer for grant " .. grant.grant_ref .. ": " .. tostring(call_error)) end
    local reply, reply_error = decode_reply(raw)
    if not reply then return nil, fail("UNAVAILABLE", "resource authority returned an invalid reply for grant " .. grant.grant_ref .. ": " .. tostring(reply_error)) end
    if reply.ok == false then return nil, fail(reply.error.code, "grant " .. grant.grant_ref .. ": " .. reply.error.message) end
    local resolved, decode_error = resource_resolution.decode(reply.value)
    if not resolved then return nil, fail("UNAVAILABLE", "resource authority returned an invalid grant " .. grant.grant_ref .. ": " .. tostring(decode_error)) end
    if resolved.grant_id ~= grant.grant_ref then return nil, fail("UNAVAILABLE", "resource authority returned another grant for " .. grant.grant_ref) end
    if grant.access == "write" and resolved.access ~= "write" then return nil, fail("FORBIDDEN", "grant " .. grant.grant_ref .. " allows " .. resolved.access .. " only") end
    return {grant_id = resolved.grant_id, root_ref = resolved.root_ref, root_digest = resolved.root_digest, subpath = resolved.subpath,
        access = grant.access, association_revision = resolved.association_revision, expires_at = resolved.expires_at}, nil
end
-- In granted mode every grant is resolved and the caller's concrete root
-- is replaced by the authority's; in host_configured mode the caller's root
-- is checked against the host list. The host selects the mode.
local function admit_resources(request: types.LaunchRequest): ({Resolved}?, Reply?)
    local mode, mode_error, mode_code = resources.resource_mode()
    if not mode then return nil, fail(mode_code or "UNAVAILABLE", "resource mode is unavailable: " .. tostring(mode_error)) end
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
local function check_projection(request: types.LaunchRequest, projection_id: string): (Reply?, string?, boolean?, string?, string?)
    local raw, call_error = funcs.call(resources.CREDENTIAL_CHECK, {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id, attempt_id = request.attempt_id})
    if call_error then return fail("UNAVAILABLE", "credential broker did not answer for projection " .. projection_id .. ": " .. tostring(call_error)), nil end
    local reply, reply_error = decode_reply(raw)
    if not reply then return fail("UNAVAILABLE", "credential broker returned an invalid reply for projection " .. projection_id .. ": " .. tostring(reply_error)), nil end
    if reply.ok == false then return fail(reply.error.code, "projection " .. projection_id .. ": " .. reply.error.code), nil end
    local projection, projection_error = credential_protocol.checked_projection(reply.value, projection_id)
    if not projection then
        return fail("DENIED", "projection " .. projection_id .. " has invalid metadata: " .. tostring(projection_error)), nil
    end
    if projection.subject ~= request.owner_id or projection.audience ~= request.owner_id or projection.attempt_id ~= request.attempt_id
        or projection.profile_id ~= request.profile_id or projection.profile_digest ~= request.profile_digest
        or projection.binding_digest ~= request.binding_digest then
        return fail("DENIED", "projection " .. projection_id .. " belongs to another launch"), nil
    end
    if projection.projection_kind == "environment" then return nil, "environment" end
    local provider_home = request.launch.provider_home
    local private_home = provider_home ~= nil and provider_home.private == true
    if (not request.session_ref or not request.launch.home_ref) and not private_home then
        return fail("DENIED", "file credential projections require a selected retained or declared private provider home"), nil
    end
    local source, source_error = homes.decode_login_source({provider = projection.provider,
        definition_id = projection.definition_id, definition_revision = projection.definition_revision, format = projection.format})
    local destination_name = source and source.path:match("[^/]+$") or nil
    if not source or not destination_name or projection.destination ~= destination_name then
        return fail("DENIED", "projection " .. projection_id .. " has invalid file login metadata"), nil
    end
    if provider_home and provider_home.provider ~= source.source.provider then
        return fail("DENIED", "file credential provider differs from the driver provider home"), nil
    end
    return nil, "file", projection.source_present == true, source.source.provider, source.path
end
-- Checks the gateway binding an attempt holds under its attached carrier
-- epoch; bindings, never bytes.
local function check_gateway(row: store.Row, request: types.LaunchRequest): Reply?
    local carrier_epoch = bounds.count(row.attachment_generation)
    if not carrier_epoch then return fail("STORAGE", "attempt attachment generation is corrupt") end
    if carrier_epoch < 1 then return fail("DENIED", "gateway binding: the attempt is not attached to a carrier") end
    local raw, call_error = funcs.call(resources.GATEWAY_CHECK, {attempt_id = request.attempt_id, carrier_epoch = carrier_epoch})
    if call_error then return fail("UNAVAILABLE", "the gateway did not answer for attempt " .. request.attempt_id .. ": " .. tostring(call_error)) end
    local reply, reply_error = decode_reply(raw)
    if not reply then return fail("UNAVAILABLE", "the gateway returned an invalid reply for attempt " .. request.attempt_id .. ": " .. tostring(reply_error)) end
    if reply.ok == false then return fail(reply.error.code, "gateway binding: " .. reply.error.message) end
    local checked, checked_error = gateway_protocol.checked_binding(reply.value)
    if not checked then return fail("UNAVAILABLE", "gateway returned invalid binding metadata: " .. tostring(checked_error)) end
    if not checked.valid then return fail("DENIED", "gateway binding: " .. tostring(checked.reason or "binding is invalid")) end
    return nil
end
-- Rechecks every recorded grant, projection and gateway binding of an
-- attempt; nil means all still hold. The second value names what failed.
function M.check_grants(row: store.Row, request: types.LaunchRequest): (Reply?, string?)
    local mode, mode_error, mode_code = resources.resource_mode()
    if not mode then return fail(mode_code or "UNAVAILABLE", "resource mode is unavailable: " .. tostring(mode_error)), "grant" end
    if mode == "granted" then
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
    if request.environment_refs.HOME ~= "bee.env:machine_home" then return nil end
    local policy_entry, policy_error = resolver.entry(pinned, request.policy_ref)
    if policy_error then return policy_error end
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
    if request.environment_refs.HOME == "bee.env:machine_home" then
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
    local refused, subject = M.check_grants(row, request)
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
    local raw, call_error = funcs.call(resources.GATEWAY_AUTHORIZE, {attempt_id = attempt.attempt_id, carrier_epoch = carrier_epoch, binding_id = gateway_binding, ttl_ms = 600000})
    local reply = type(raw) == "table" and raw or nil
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
local function configuration_input(pinned: registry.Snapshot, request: types.LaunchRequest, context: LocalPreparation?): (configuration_types.Request?, string?, string?, driver_types.GitWritableRootsAdapter?)
    local policy_entry, policy_error = resolver.entry(pinned, request.policy_ref)
    if policy_error then return nil, nil, policy_error end
    local policy_meta = policy_entry and bounds.object(policy_entry.meta) or {}
    local data = policy_entry and bounds.object(policy_entry.data) or nil
    if not policy_entry or policy_meta.type ~= types.LAUNCH_POLICY_TYPE or not data then return nil, nil, "policy_ref is not a host launch policy" end
    local descriptor = profile_values.schema(request.binding_ref)
    if request.preferences or descriptor then
        local effective, preference_error = preferences.apply(data, request.preferences, descriptor, request.placement_profile_ref)
        if not effective then return nil, nil, preference_error end
        data = effective
    end
    local expected_binding = data.placement_binding
    if request.placement_profile_ref then
        local admitted = bounds.ids(data.placement_profiles or {"bee.placement.profiles:native"}, true)
        if not admitted or not bounds.member(request.placement_profile_ref, admitted) then return nil, nil, "launch policy does not admit this placement profile" end
        local selected, profile_error = placement_profiles.resolve(pinned, request.placement_profile_ref)
        if not selected then return nil, nil, profile_error end
        if selected.digest ~= request.placement_profile_digest then return nil, nil, "placement profile changed since admission" end
        expected_binding = selected.profile.placement_binding
    end
    -- The operation target cannot override the host's selected placement.
    if expected_binding ~= nil and expected_binding ~= (context and context.binding or "bee.placement.native.binding:binding") then
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
    local selected_profile, profile_error = resolver.profile(pinned, request.binding_ref, request.profile_id)
    if profile_error then return nil, nil, profile_error end
    local provider: {[string]: unknown}? = nil
    if provider_ref then
        local provider_error: string?
        provider, provider_error = resolver.entry(pinned, provider_ref)
        if provider_error then return nil, nil, provider_error end
        if not provider then return nil, nil, "launch policy provider is not in the registry" end
    end
    local tools, tools_error = bounds.ids(data.gateway_tools == nil and {} or data.gateway_tools, true)
    if not tools then return nil, nil, "launch policy gateway_tools: " .. tostring(tools_error) end
    local hooks, hooks_error = bounds.ids(data.gateway_hooks == nil and {} or data.gateway_hooks, true)
    if not hooks then return nil, nil, "launch policy gateway_hooks: " .. tostring(hooks_error) end
    hooks = resolver.select_hooks(selected_profile, hooks)
    table.sort(tools)
    tools = gateway_protocol.offered_tools(tools, data, request.preferences ~= nil)
    local gateway: configuration_types.GatewayInput? = nil
    if #tools > 0 or #hooks > 0 then
        local endpoint, endpoint_error = gateway_configuration.endpoint()
        if not endpoint then return nil, nil, endpoint_error or "gateway endpoint" end
        local command_ref = data.hook_command_ref == nil and nil or bounds.id(data.hook_command_ref)
        if data.hook_command_ref ~= nil and not command_ref then return nil, nil, "hook_command_ref requires hooks and an env.variable identifier" end
        local hook_command: string? = nil
        local command_error: string? = nil
        if #hooks > 0 then hook_command, command_error = gateway_configuration.hook_command(command_ref) end
        if command_error then return nil, nil, command_error end
        gateway = {hook_command = hook_command, endpoint = endpoint, action_id = request.action_id, tools = tools, hooks = hooks,
            token_environment = gateway_configuration.DESTINATION,
            hook_token_environment = #hooks > 0 and gateway_configuration.HOOK_DESTINATION or nil}
    end
    -- Use the same decoder as the carrier planner, including empty registry
    -- maps: their raw allocation shape is not a host option selection.
    local option_values, options_error = preferences.decode_prepare_options(data.prepare_options)
    if not option_values then return nil, nil, options_error end
    return {placement_profile_ref = request.placement_profile_ref, option_provenance = bounds.object(data.option_provenance), option_values = option_values, context = request.configuration_context, instructions = instructions, instruction_builder = instruction_builder, provider_ref = provider_ref, provider = provider, gateway = gateway, fixture = data.fixture == true}, target, nil,
        selected_profile and selected_profile.sandbox and selected_profile.sandbox.git_writable_roots_adapter or nil
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
function M.prepare_local(value: unknown, context: LocalPreparation?): Reply
    local request, decode_error = request_codec.decode(value)
    if not request then return fail("INVALID", decode_error or "invalid launch request") end
    -- This implementation is one contract binding. A carrier may select a
    -- different placement, but it must never route that request into native
    -- materialization or create a native intent under the wrong identity.
    if request.placement_binding_ref and request.placement_binding_ref ~= (context and context.binding or placement_resolver.DEFAULT) then
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
    local home_directory, home_error = configured_home(request)
    if context then home_directory, home_error = context.home_directory, nil end
    if not home_directory then return fail("UNAVAILABLE", home_error or "configuration home unavailable") end
    local resolved_grants, resources_refused = admit_resources(request)
    if not resolved_grants then return resources_refused end
    local file_projection = false
    local projected_login_path: string? = nil
    for _, projection_id in ipairs(request.projections) do
        local refused, kind, present, provider, path = check_projection(request, projection_id)
        if refused then return refused end
        if kind == "file" then
            if file_projection then return fail("DENIED", "only one file credential projection may select a retained home") end
            file_projection = true
            if present and request.launch.login and provider == request.launch.login.provider and path then
                projected_login_path = home_directory .. "/" .. path
            end
        end
    end
    local login_notice = materialization.prepare_login_notice(request, home_directory, projected_login_path)
    local prepare_pinned, prepare_pin_error = resolver.pin()
    if not prepare_pinned then return fail("UNAVAILABLE", prepare_pin_error or "pin registry") end
    local selected_placement, placement_error = placement_resolver.resolve(prepare_pinned, request.placement_binding_ref)
    if not selected_placement then return fail("DENIED", placement_error or "native placement binding is unavailable") end
    if request.placement_binding_digest and request.placement_binding_digest ~= selected_placement.binding_digest then
        return fail("CONFLICT", "native placement binding changed since admission")
    end
    local configuration, configure_target, configuration_error, git_writable_roots_adapter = configuration_input(prepare_pinned, request, context)
    if not configuration or not configure_target then return fail("DENIED", configuration_error or "configuration inputs unavailable") end
    local home_authorization_error = host_home_authorization(prepare_pinned, request)
    if home_authorization_error then return fail("DENIED", home_authorization_error) end
    local measured: capability.Measurement
    if context then measured = {capability = context.capability, exit_observation = context.exit_observation, stdin_close = context.stdin_close, detail = "host-admitted Docker profile"}
    else measured = capability.measure() end
    if not types.satisfies(measured.capability, request.required_cleanup) then
        return fail("UNSUPPORTED_CAPABILITY", "this runtime offers " .. measured.capability .. " (" .. measured.detail .. "); the launch requires " .. request.required_cleanup)
    end
    if not types.observes(measured.exit_observation, request.required_exit_observation) then
        return fail("UNSUPPORTED_CAPABILITY", "this runtime observes exit " .. measured.exit_observation .. "; the launch requires " .. request.required_exit_observation)
    end
    if request.launch.stdin_eof == true and not measured.stdin_close then
        return fail("UNSUPPORTED_CAPABILITY", "this runtime cannot close a child's stdin; the launch reads its input until end of file")
    end
    local selected_digest, selected_error = configuration_protocol.digest(request.binding_ref, configuration, configure_target)
    if not selected_digest then return fail("DENIED", selected_error or "configuration inputs are not measurable") end
    if request.configuration_digest then
        if request.configuration_digest ~= selected_digest then return fail("CONFLICT", "host configuration inputs changed since the launch plan") end
    elseif configuration.provider_ref or configuration.gateway or configuration.instructions or configuration.instruction_builder or (configuration.option_values and next(configuration.option_values) ~= nil) then
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
        -- Session is the gateway's reserved control tool, present for every
        -- admitted binding; it is not named in the host's ordinary tool list.
        admitted_tools.session = true
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
        if existing.request_digest ~= digest then
            db:release()
            return fail("CONFLICT", "idempotency key reused with a different request")
        end
        local attempt, attempt_error = store.attempt(db, tostring(existing.attempt_id))
        db:release()
        if attempt_error or not attempt then return fail("STORAGE", attempt_error or "attempt row is corrupt") end
        if attempt then attempt.notice = login_notice end
        return succeed(attempt)
    end
    configuration.private_home = context ~= nil or (request.launch.provider_home ~= nil and request.launch.provider_home.private == true)
    configuration.home_directory = home_directory
    -- Placement supplies the measured attempt identity only while rendering
    -- private delivery. It is excluded from the host configuration digest and
    -- cannot be selected by the caller or saved profile.
    configuration.attempt_id = request.attempt_id
    local delivery, delivery_error = configuration_protocol.call(request.binding_ref, configure_target, configuration)
    if not delivery then db:release(); return fail("DENIED", delivery_error or "configuration rendering failed") end
    delivery.git_writable_roots_adapter = git_writable_roots_adapter
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
    local placement: store.Placement? = nil
    if context then placement = {kind = context.kind, spec_json = context.spec_json} end
    local result = store.intend(db, request, digest, encoded, {capability = measured.capability, exit_observation = measured.exit_observation}, grants_json, placement)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "record intent") end
    if result.attempt then result.attempt.notice = login_notice end
    return succeed(result.attempt)
end
function M.prepare(value: unknown): Reply
    return M.prepare_local(value, nil)
end
M.fail = fail
M.succeed = succeed
M.decode_reply = decode_reply
M.actor = actor
M.transition = transition
M.resolve_grant = resolve_grant
M.admit_resources = admit_resources
M.check_projection = check_projection
M.check_gateway = check_gateway
M.host_home_authorization = host_home_authorization
M.configuration_input = configuration_input
M.configured_home = configured_home
return M
