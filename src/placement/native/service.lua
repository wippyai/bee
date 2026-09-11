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
local codex_configuration = require("codex_configuration")
local gateway_configuration = require("gateway_configuration")
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
local function load(attempt_id: unknown): (types.Attempt?, Reply?)
    local id = bounds.id(attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    local db, open_error = store.open()
    if not db then return nil, fail("STORAGE", open_error or "open placement store") end
    local attempt, read_error = store.attempt(db, id)
    db:release()
    if read_error then return nil, fail("STORAGE", read_error) end
    if not attempt then return nil, fail("NOT_FOUND", "attempt is not recorded") end
    local denied = owned(attempt)
    if denied then return nil, denied end
    return attempt, nil
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
-- Checks one credential projection's bindings without bytes.
local function check_projection(request: types.LaunchRequest, projection_id: string): Reply?
    local raw, call_error = funcs.call(resources.CREDENTIAL_CHECK, {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id, attempt_id = request.attempt_id})
    if call_error or type(raw) ~= "table" then return fail("UNAVAILABLE", "credential broker did not answer for projection " .. projection_id) end
    local reply = raw :: Reply
    if not reply.ok then return fail(reply.error and reply.error.code or "DENIED", "projection " .. projection_id .. ": " .. tostring(reply.error and reply.error.code)) end
    return nil
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
    for _, projection_id in ipairs(request.projections) do
        local refused = check_projection(request, projection_id)
        if refused then return refused, "credential" end
    end
    if request.gateway then
        local refused = check_gateway(row, request)
        if refused then return refused, "gateway" end
    end
    return nil, nil
end
-- Authorizes one concrete execution path after its recorded grants have been
-- rechecked.  Both the ordinary runner and the native window use this seam;
-- callers never supply a gateway materialization key as authority.
function M.authorize_materialization(attempt: types.Attempt, row: store.Row, request: types.LaunchRequest, gateway_binding: string?): (string?, Reply?)
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
-- prepare: validate the admitted request against this host, refuse what the
-- runtime cannot clean, record intent. Same key and digest replays.
function M.prepare(value: unknown): Reply
    local request, decode_error = request_codec.decode(value)
    if not request then return fail("INVALID", decode_error or "invalid launch request") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if caller ~= request.owner_id then return fail("FORBIDDEN", "owner_id is not the caller") end
    local digest, digest_error = request_codec.digest(request)
    if not digest then return fail("INVALID", digest_error or "request is not measurable") end
    local resolved_grants, resources_refused = admit_resources(request)
    if not resolved_grants then return resources_refused :: Reply end
    for _, projection_id in ipairs(request.projections) do
        local refused = check_projection(request, projection_id)
        if refused then return refused end
    end
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
    -- The host launch policy the request names authorizes its host-selected
    -- parts: a configuration is authorized by the provider that policy
    -- selects, never by the caller's choice or content; placement renders
    -- the provider itself and the request must match it exactly.
    local policy_entry, policy_error = registry.get(request.policy_ref)
    if policy_error or not policy_entry then return fail("DENIED", "policy_ref " .. request.policy_ref .. " is not in the registry") end
    local policy_meta = bounds.object(policy_entry.meta) or {}
    if policy_meta.type ~= types.LAUNCH_POLICY_TYPE then return fail("DENIED", "policy_ref " .. request.policy_ref .. " is not a host launch policy") end
    local policy_data = bounds.object(policy_entry.data) or {}
    if request.configuration then
        local configuration = request.configuration
        if policy_data.codex_provider_ref ~= configuration.provider_ref then
            return fail("DENIED", "configuration names provider " .. configuration.provider_ref .. " which the launch policy " .. request.policy_ref .. " does not select")
        end
        local provider_entry, provider_error = registry.get(configuration.provider_ref)
        if provider_error or not provider_entry then return fail("DENIED", "configuration names provider " .. configuration.provider_ref .. " which is not in the registry") end
        local provider, decode_error = codex_configuration.decode(configuration.provider_ref, provider_entry)
        if not provider then return fail("DENIED", "configuration provider: " .. tostring(decode_error)) end
        -- A launch with a gateway binding carries the gateway section inside
        -- this file, rendered by the gateway library for this action.
        local gateway_section: string? = nil
        if request.gateway then
            local address, endpoint_error = gateway_configuration.endpoint()
            if not address then return fail("DENIED", endpoint_error or "gateway endpoint") end
            gateway_section = gateway_configuration.codex_section(address, request.action_id)
            if #request.gateway.hooks > 0 then
                local codex_hooks, hooks_error = gateway_configuration.codex_hooks(address, request.action_id, request.gateway.hooks)
                if not codex_hooks then return fail("INVALID", hooks_error or "codex hooks") end
                gateway_section = gateway_section .. codex_hooks.section
            end
        end
        local expected, render_error = codex_configuration.projection(provider, gateway_section)
        if not expected then return fail("INVALID", render_error or "configuration") end
        if configuration.revision ~= expected.revision or configuration.path ~= expected.path or configuration.digest ~= expected.digest or configuration.content ~= expected.content then
            return fail("DENIED", "configuration does not match what the host provider " .. configuration.provider_ref .. " renders")
        end
    end
    -- A gateway binding is host-selected the same way: the policy names the
    -- tool set and the configuration must be exactly what the host's
    -- endpoint renders for this action.
    if request.gateway then
        local gateway = request.gateway
        local declared, tools_error = bounds.ids(policy_data.gateway_tools == nil and {} or policy_data.gateway_tools, true)
        if not declared then return fail("DENIED", "launch policy gateway_tools: " .. tostring(tools_error)) end
        table.sort(declared)
        local wanted: {string} = {}
        for index, tool in ipairs(gateway.tools) do wanted[index] = tool end
        table.sort(wanted)
        if #declared == 0 or #declared ~= #wanted then return fail("DENIED", "gateway tools are not what the launch policy " .. request.policy_ref .. " admits") end
        for index, tool in ipairs(declared) do
            if wanted[index] ~= tool then return fail("DENIED", "gateway tools are not what the launch policy " .. request.policy_ref .. " admits") end
        end
        if gateway.destination ~= gateway_configuration.DESTINATION then return fail("DENIED", "gateway destination must be " .. gateway_configuration.DESTINATION) end
        -- Hook events are the policy's, and their adapters are exactly what
        -- the endpoint renders: the Claude settings adapter for a launch
        -- without a provider file, the Codex hooks file and trust hashes
        -- for one with it.
        local declared_hooks, hooks_error = bounds.ids(policy_data.gateway_hooks == nil and {} or policy_data.gateway_hooks, true)
        if not declared_hooks then return fail("DENIED", "launch policy gateway_hooks: " .. tostring(hooks_error)) end
        table.sort(declared_hooks)
        local wanted_hooks: {string} = {}
        for index, event in ipairs(gateway.hooks) do wanted_hooks[index] = event end
        table.sort(wanted_hooks)
        if #declared_hooks ~= #wanted_hooks then return fail("DENIED", "gateway hooks are not what the launch policy " .. request.policy_ref .. " admits") end
        for index, event in ipairs(declared_hooks) do
            if wanted_hooks[index] ~= event then return fail("DENIED", "gateway hooks are not what the launch policy " .. request.policy_ref .. " admits") end
        end
        if #gateway.hooks > 0 then
            if gateway.hook_destination ~= gateway_configuration.HOOK_DESTINATION then return fail("DENIED", "gateway hook destination must be " .. gateway_configuration.HOOK_DESTINATION) end
            local address, endpoint_error = gateway_configuration.endpoint()
            if not address then return fail("DENIED", endpoint_error or "gateway endpoint") end
            if request.configuration then
                if gateway.hook_configuration then return fail("DENIED", "a launch with a provider configuration carries its hooks in the Codex hooks file, not a settings adapter") end
                local expected_codex, codex_error = gateway_configuration.codex_hooks(address, request.action_id, gateway.hooks)
                if not expected_codex then return fail("INVALID", codex_error or "codex hooks") end
                local codex = gateway.codex_hooks
                if not codex then return fail("DENIED", "a launch with a provider configuration and hook events needs codex_hooks") end
                local file = codex.hooks
                if file.revision ~= expected_codex.hooks.revision or file.path ~= expected_codex.hooks.path or file.digest ~= expected_codex.hooks.digest or file.content ~= expected_codex.hooks.content or file.provider_ref ~= expected_codex.hooks.provider_ref then
                    return fail("DENIED", "codex hooks file does not match what the host endpoint renders for action " .. request.action_id)
                end
                if codex.profile ~= expected_codex.profile then return fail("DENIED", "codex hooks profile must be " .. expected_codex.profile) end
                for label, digest in pairs(expected_codex.trust) do
                    if codex.trust[label] ~= digest then return fail("DENIED", "codex hook trust for " .. label .. " does not match what the host renders") end
                end
                for label in pairs(codex.trust) do
                    if expected_codex.trust[label] == nil then return fail("DENIED", "codex hook trust names " .. label .. " which the host does not render") end
                end
            else
                if gateway.codex_hooks then return fail("DENIED", "a launch without a provider configuration carries no codex hooks") end
                local expected_settings, settings_error = gateway_configuration.claude_hooks(address, request.action_id, gateway.hooks)
                if not expected_settings then return fail("INVALID", settings_error or "hook configuration") end
                local settings = gateway.hook_configuration
                if not settings then return fail("DENIED", "a launch without a provider configuration and with hook events needs the hook configuration adapter") end
                if settings.revision ~= expected_settings.revision or settings.path ~= expected_settings.path or settings.digest ~= expected_settings.digest or settings.content ~= expected_settings.content or settings.provider_ref ~= expected_settings.provider_ref then
                    return fail("DENIED", "hook configuration does not match what the host endpoint renders for action " .. request.action_id)
                end
            end
        elseif gateway.hook_configuration or gateway.codex_hooks then
            return fail("DENIED", "hook adapters need admitted hook events")
        end
        -- The configuration lives either in the provider file (verified
        -- above with the gateway section) or in the standalone file the
        -- endpoint renders for this action; never both, never neither.
        local given = gateway.configuration
        if request.configuration then
            if given then return fail("DENIED", "a launch with a provider configuration carries the gateway section there, not a second file") end
        else
            if not given then return fail("DENIED", "a launch without a provider configuration needs the gateway configuration file") end
            local address, endpoint_error = gateway_configuration.endpoint()
            if not address then return fail("DENIED", endpoint_error or "gateway endpoint") end
            local expected, render_error = gateway_configuration.projection(address, request.action_id)
            if not expected then return fail("INVALID", render_error or "gateway configuration") end
            if given.provider_ref ~= expected.provider_ref or given.revision ~= expected.revision or given.path ~= expected.path or given.digest ~= expected.digest or given.content ~= expected.content then
                return fail("DENIED", "gateway configuration does not match what the host endpoint renders for action " .. request.action_id)
            end
        end
    elseif policy_data.gateway_tools ~= nil then
        return fail("DENIED", "launch policy " .. request.policy_ref .. " admits gateway tools the request does not carry")
    end
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
    local encoded, encode_error = json.encode(request)
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
    local attempt, denied = load(id)
    if not attempt then return denied :: Reply end
    local liveness: types.Liveness = {observed = false, alive = nil, at = store.now(), detail = "no execution identity recorded"}
    local recorded = recorded_identity(attempt.attempt_id)
    if recorded then
        local observation = identity.observe(recorded)
        liveness = {observed = observation.observed, alive = observation.alive, at = store.now(), detail = observation.detail}
    end
    return succeed({attempt = attempt, liveness = liveness})
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
    local recorded, _, row = recorded_identity(attempt.attempt_id)
    local proven, why = scope_proven(attempt, recorded)
    if not proven then return fail("CONFLICT", "cleanup scope " .. attempt.required_cleanup .. " is not proven gone: " .. why) end
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
        credential_broker = true, credential_projections = {"environment"}, max_chunk_bytes = protocol.MAX_CHUNK_BYTES,
        gateway = {materialization = "placement_authorized_key", token_projection = "environment", takeover_grace_ms = protocol.TAKEOVER_GRACE_MS, seal_on = {"child_exit"}, revocation_on = {"refused_start", "carrier_loss_without_takeover", "reconcile_end", "carrier_close"},
            hook_events = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"}, shutdown_events_not_admitted = {"SessionEnd", "StopFailure"}},
        max_write_bytes = protocol.MAX_WRITE_BYTES, max_outstanding_chunks = protocol.MAX_OUTSTANDING_CHUNKS, max_spool_bytes = protocol.MAX_SPOOL_BYTES,
        max_evidence_page = store.MAX_EVIDENCE_PAGE, canonical = canonical.encode({capability = measured.capability})})
end
return M
