-- MIT. The carrier machine: one attempt from plan to receipt, expressed as
-- steps over an injected IO so the same code runs in the production
-- process and under a test harness that stops it between steps. Every
-- durable fact lives in thread records, placement receipts and the
-- checkpoint; the machine keeps only what the checkpoint holds.
local json = require("json")
local hash = require("hash")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local permission = require("permission")
local acceptance = require("acceptance")
local gateway_configuration = require("gateway_configuration")
local bounds = require("bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local classify = require("classify")
local policy = require("policy")
local provenance = require("provenance")
local checkpoint = require("checkpoint")
local prestart = require("prestart")
local continuation = require("continuation")
local settle = require("settle")
local stream_json = require("stream_json")
local driver_types = require("driver_types")
local placement_types = require("placement_types")
local placement_resolver = require("placement_resolver")
local placement_protocol = require("placement_protocol")
local placement_decode = require("placement_decode")
local record_types = require("record_types")
local thread_record = require("thread_record")
local record_values = require("record_values")
local observation_decode = require("observation_decode")
local launch_request = require("launch_request")
local configuration_protocol = require("configuration")
local gateway_protocol = require("gateway_protocol")
local service_reply = require("service_reply")
local hook_records = require("hook_records")
local carrier_types = require("carrier_types")
local inbox = require("inbox")
local permission_exchange = require("permission_exchange")
local M = {}
M.PLACEMENT_BINDING = placement_resolver.DEFAULT
M.CARRIER_REGISTRY_PREFIX = prestart.CARRIER_REGISTRY_PREFIX
M.THREADS = inbox.THREADS
M.CARRIER_OPS = "bee.threads.carrier"
M.GATEWAY = "bee.gateway.binding"
M.MAX_RECORDS_PER_COMMIT = 64
-- A frame may be as large as the chunks the runner holds unacknowledged; a
-- checkpoint carries only a partial frame up to checkpoint.MAX_CARRY_BYTES.
M.MAX_FRAME_BYTES = placement_protocol.MAX_OUTSTANDING_CHUNKS * placement_protocol.MAX_CHUNK_BYTES
M.APPROVALS = "bee.approvals.binding"
M.DELIVERY = inbox.DELIVERY
M.WAITER_NAME = "bee.threads.waiter"
M.HINT_REGISTRATION_MS = 60000
type Object = {[string]: unknown}
type Reply = service_reply.Reply
type IO = carrier_types.IO
type Request = carrier_types.Request
type Exchange = carrier_types.Exchange
type Push = carrier_types.Push
type Plan = carrier_types.Plan
type OutputState = carrier_types.OutputState
type Session = carrier_types.Session
type Offer = carrier_types.Offer
type InboxPromptItem = inbox.InboxPromptItem
local inbox_context_value: inbox.Context? = nil
local permission_context_value: permission_exchange.Context? = nil
local function inbox_context(): inbox.Context
    if inbox_context_value == nil then error("carrier inbox context is not initialized") end
    return inbox_context_value
end
local function permission_context(): permission_exchange.Context
    if permission_context_value == nil then error("carrier permission context is not initialized") end
    return permission_context_value
end

M.inbox_prompt = inbox.inbox_prompt
M.push_line = inbox.push_line
function M.open_hints(io: IO, session: Session): (integer?, string?)
    return inbox.open_hints(inbox_context(), io, session)
end
function M.take_hints(io: IO, session: Session): (boolean, integer?, string?)
    return inbox.take_hints(inbox_context(), io, session)
end
function M.acknowledge_hints(io: IO, session: Session): (boolean, string?)
    return inbox.acknowledge_hints(inbox_context(), io, session)
end
function M.close_hints(io: IO, session: Session)
    inbox.close_hints(inbox_context(), io, session)
end
function M.offer_inbox(io: IO, session: Session): (Offer?, string?)
    return inbox.offer_inbox(inbox_context(), io, session)
end
function M.carry_brief(io: IO, request: Request, driver_id: string, mode: string): string
    return inbox.carry_brief(inbox_context(), io, request, driver_id, mode)
end
function M.begin_push_turn(io: IO, session: Session, item: Offer): (string?, string?)
    return inbox.begin_push_turn(inbox_context(), io, session, item)
end

local function step(io: IO, name: string): ()
    if io.after then io.after(name) end
end
-- The durable states travel in the checkpoint so a replacement keeps what
-- was observed; unobserved and incomplete are conclusions, never stored
-- over an observation.
local function mark_output(session: Session, state: OutputState)
    session.output = state
    if state == "open" or state == "complete" or state == "truncated" then session.checkpoint.output = state end
end
local function reply_of(value: unknown, err: string?): (Reply?, string?)
    if err then return nil, err end
    return service_reply.decode(value)
end
type ExecutableCapability = {streaming: boolean, read_only_volume: boolean, detail: string}
local function executable_capability(value: unknown): (ExecutableCapability?, string?)
    local capabilities = bounds.object(value)
    if not capabilities then return nil, "capabilities must be an object" end
    local capability_fields = bounds.fields(capabilities, {"capability", "exit_observation", "stdin_close", "detail", "executable_measurement", "resource_authority",
        "delegated_resource_grants", "revocation_enforcement", "credential_broker", "credential_projections", "max_chunk_bytes", "gateway", "max_write_bytes",
        "max_outstanding_chunks", "max_spool_bytes", "max_evidence_page", "canonical"})
    if capability_fields then return nil, "capabilities: " .. capability_fields end
    local report = bounds.object(capabilities.executable_measurement)
    if not report then return nil, "executable_measurement must be an object" end
    local report_fields = bounds.fields(report, {"streaming", "read_only_volume", "detail"})
    local detail = bounds.text(report.detail, 4096)
    if report_fields or type(report.streaming) ~= "boolean" or type(report.read_only_volume) ~= "boolean" or detail == nil then
        return nil, "executable_measurement is malformed"
    end
    return {streaming = report.streaming, read_only_volume = report.read_only_volume, detail = detail}, nil
end
local function executable_measurement(value: unknown, expected_path: string): (placement_types.ExecutableMeasurement?, string?)
    local object = bounds.object(value)
    if not object then return nil, "measurement must be an object" end
    local unknown_field = bounds.fields(object, {"revision", "path", "kind", "interpreter", "size", "digest"})
    local revision, path = bounds.id(object.revision), bounds.text(object.path, bounds.MAX_TEXT_BYTES)
    local kind = bounds.member(object.kind, {"elf", "script", "other"})
    local size, digest = bounds.count(object.size), bounds.text(object.digest, 64)
    local interpreter: string? = nil
    if object.interpreter ~= nil then interpreter = bounds.text(object.interpreter, 4096) end
    if unknown_field then return nil, "measurement: " .. unknown_field end
    if not revision then return nil, "measurement revision is invalid" end
    if path ~= expected_path then return nil, "measurement names another path" end
    if not kind then return nil, "measurement kind is invalid" end
    if size == nil then return nil, "measurement size is invalid" end
    if not digest then return nil, "measurement digest is invalid" end
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "measurement digest is invalid" end
    if object.interpreter ~= nil and not interpreter then return nil, "measurement interpreter is invalid" end
    if (kind == "script") ~= (interpreter ~= nil) then return nil, "measurement interpreter does not match its kind" end
    local decoded_kind: string
    if kind == "elf" then decoded_kind = "elf"
    elseif kind == "script" then decoded_kind = "script"
    else decoded_kind = "other" end
    local decoded: placement_types.ExecutableMeasurement = {revision = revision, kind = decoded_kind, digest = digest}
    return decoded, nil
end
type ThreadPage = {records: {record_types.Record}, scanned_through: integer, has_more: boolean}
local function thread_page(value: unknown, cursor: integer, limit: integer): (ThreadPage?, string?)
    local object = bounds.object(value)
    if not object then return nil, "page must be an object" end
    local unknown_field = bounds.fields(object, {"records", "scanned_through", "has_more"})
    local rows, rows_error = bounds.array(object.records, limit)
    local scanned_through = bounds.integer(object.scanned_through)
    if unknown_field then return nil, "page: " .. unknown_field end
    if not rows then return nil, "page records: " .. tostring(rows_error) end
    if scanned_through == nil then return nil, "page cursor is invalid" end
    if scanned_through < cursor or scanned_through > bounds.MAX_THREAD_RECORDS then return nil, "page cursor is invalid" end
    if type(object.has_more) ~= "boolean" then return nil, "page has_more flag is invalid" end
    local page_cursor: integer = scanned_through
    local has_more: boolean = object.has_more
    local records: {record_types.Record} = {}
    local previous_sequence = cursor
    for index, raw in ipairs(rows) do
        local decoded, decode_error = thread_record.decode(raw)
        if not decoded then return nil, "page records[" .. tostring(index) .. "]: " .. tostring(decode_error) end
        if decoded.sequence <= previous_sequence or decoded.sequence > page_cursor then return nil, "page records are not in sequence" end
        previous_sequence = decoded.sequence
        records[index] = decoded
    end
    if #records > 0 and page_cursor < previous_sequence then return nil, "page cursor precedes its final record" end
    return {records = records, scanned_through = page_cursor, has_more = has_more}, nil
end
type StdinClosure = {closed: boolean, reason: string?}
local function stdin_closure(value: unknown, attempt_id: string): (StdinClosure?, string?)
    local object = bounds.object(value)
    if not object then return nil, "close_stdin result must be an object" end
    local unknown_field = bounds.fields(object, {"attempt", "closed", "reason"})
    if unknown_field then return nil, "close_stdin: " .. unknown_field end
    local attempt, attempt_error = placement_decode.attempt(object.attempt)
    if not attempt then return nil, "close_stdin attempt: " .. tostring(attempt_error) end
    if attempt.attempt_id ~= attempt_id then return nil, "close_stdin returned another attempt" end
    if type(object.closed) ~= "boolean" then return nil, "close_stdin closed flag is invalid" end
    local reason: string? = nil
    if object.reason ~= nil then
        reason = bounds.text(object.reason, 4096)
        if not reason or reason == "" then return nil, "close_stdin refusal reason is invalid" end
    end
    if (object.closed == true and reason ~= nil) or (object.closed == false and reason == nil) then return nil, "close_stdin result and reason disagree" end
    return {closed = object.closed, reason = reason}, nil
end
local function must(io: IO, target: string, request: unknown): (unknown, string?)
    local raw, call_error = io.call(target, request)
    local reply, reply_error = reply_of(raw, call_error)
    if not reply then return nil, target .. ": " .. tostring(reply_error) end
    if reply.ok == false then return nil, target .. ": " .. reply.error.code .. ": " .. reply.error.message end
    return reply.value, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
-- measure: the binding, profile, policy and, when enabled, the adapter and
-- acceptance record, all read from one pinned registry generation.
type Measured = {generation: integer, binding: classify.Binding, profile: classify.Profile, policy: policy.Policy, placement_binding: placement_types.PlacementBinding, exchange: Exchange?, push: Push?, configuration_digest: string, gateway: placement_types.Gateway?}
-- verify_acceptance: the acceptance record a host declaration names,
-- decoded and matched against this snapshot's binding, profile, adapter
-- and proof fixture. The permission exchange and production inbox push
-- stand on the same record type; the label names which check failed.
type DeclaredAcceptance = {adapter_ref: string, acceptance_ref: string, fixture_digest: string}
local function verify_acceptance(pinned: registry.Snapshot, declared: DeclaredAcceptance, binding: classify.Binding, profile: classify.Profile, fixture: boolean, label: string): (Push?, string?)
    if not fixture and (not profile.permission.eligible or profile.permission.adapter_ref ~= declared.adapter_ref) then
        return nil, "profile " .. profile.id .. " does not pin permission adapter " .. declared.adapter_ref
    end
    local adapter_entry = catalog.entry(pinned, declared.adapter_ref)
    if not adapter_entry then return nil, "permission adapter " .. declared.adapter_ref .. " is not in the registry" end
    local adapter_meta = bounds.object(adapter_entry.meta)
    if not adapter_meta then return nil, "permission adapter " .. declared.adapter_ref .. " has invalid metadata" end
    if adapter_meta.type ~= "harness.permission_adapter" then return nil, declared.adapter_ref .. " is not a harness.permission_adapter" end
    local adapter_data = bounds.object(adapter_entry.data)
    if not adapter_data then return nil, "permission adapter " .. declared.adapter_ref .. " has invalid data" end
    local adapter, adapter_error = permission.decode(declared.adapter_ref, adapter_data.adapter)
    if not adapter then return nil, "permission adapter " .. declared.adapter_ref .. ": " .. tostring(adapter_error) end
    local record_entry = catalog.entry(pinned, declared.acceptance_ref)
    if not record_entry then return nil, "acceptance record " .. declared.acceptance_ref .. " is not in the registry" end
    local record_meta = bounds.object(record_entry.meta)
    if not record_meta then return nil, "acceptance record " .. declared.acceptance_ref .. " has invalid metadata" end
    if record_meta.type ~= acceptance.ENTRY_TYPE then return nil, declared.acceptance_ref .. " is not a " .. acceptance.ENTRY_TYPE end
    local record_data = bounds.object(record_entry.data)
    if not record_data then return nil, "acceptance record " .. declared.acceptance_ref .. " has invalid data" end
    local record, record_error = acceptance.decode(declared.acceptance_ref, record_data.acceptance)
    if not record then return nil, "acceptance record " .. declared.acceptance_ref .. ": " .. tostring(record_error) end
    local mismatch = acceptance.matches(record, {binding_id = binding.binding_id, profile_id = profile.id, binding_digest = binding.binding_digest.entry, profile_digest = binding.profile_digest.entry,
        adapter_ref = declared.adapter_ref, adapter_digest = adapter.digest, fixture_digest = declared.fixture_digest})
    if mismatch then return nil, label .. " acceptance: " .. mismatch end
    return {adapter = adapter, acceptance_ref = declared.acceptance_ref, acceptance_digest = record.digest, executable_revision = record.executable_revision, executable_kind = record.executable_kind, executable_digest = record.executable_digest}, nil
end
local function measure(request: Request): (Measured?, string?)
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, pin_error end
    local snapshot, snapshot_error = catalog.read(pinned, nil)
    if not snapshot then return nil, snapshot_error end
    local usable, usable_error = catalog.usable(snapshot)
    if not usable then return nil, usable_error end
    local binding: classify.Binding? = nil
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == request.binding_ref then binding = candidate end
    end
    if not binding then return nil, "binding " .. request.binding_ref .. " is not usable on this host" end
    local profile: classify.Profile? = nil
    for _, candidate in ipairs(binding.profiles) do
        if candidate.id == request.profile_id then profile = candidate end
    end
    if not profile or not profile.supported then return nil, "profile " .. request.profile_id .. " is not supported by " .. request.binding_ref end
    local policy_entry = catalog.entry(pinned, request.policy_ref)
    if not policy_entry then return nil, "launch policy " .. request.policy_ref .. " is not in the registry" end
    local launch_policy, policy_error = policy.decode(request.policy_ref, policy_entry, nil, request.preferences)
    if not launch_policy then return nil, policy_error end
    -- The policy is host-owned and decoded from this pinned snapshot. It is
    -- the source of placement selection; request fields only prove that the
    -- carrier received the same measured choice from admission.
    local selected_placement, placement_error = placement_resolver.resolve(pinned, launch_policy.placement_binding)
    if not selected_placement then return nil, placement_error end
    if (request.placement_binding_ref and request.placement_binding_ref ~= selected_placement.binding_id)
        or (request.placement_binding_digest and request.placement_binding_digest ~= selected_placement.binding_digest) then
        return nil, "placement binding changed since admission"
    end
    local exchange: Exchange? = nil
    local declared = launch_policy.permission_exchange
    if declared then
        if not request.workspace_id then return nil, "a permission exchange needs the request's workspace" end
        local verified, verify_error = verify_acceptance(pinned, declared, binding, profile, launch_policy.fixture, "permission exchange")
        if not verified then return nil, verify_error end
        exchange = {adapter = verified.adapter, acceptance_ref = verified.acceptance_ref, acceptance_digest = verified.acceptance_digest,
            executable_revision = verified.executable_revision, executable_kind = verified.executable_kind, executable_digest = verified.executable_digest,
            approver_policy = declared.approver_policy, poll_ms = declared.poll_ms, ttl_ms = declared.ttl_ms}
    end
    local push: Push? = nil
    local declared_push = launch_policy.push_acceptance
    if declared_push then
        local verified_push, push_error = verify_acceptance(pinned, declared_push, binding, profile, launch_policy.fixture, "push")
        if not verified_push then return nil, push_error end
        push = verified_push
    elseif launch_policy.inbox_push and not launch_policy.fixture then
        return nil, "inbox push needs a pinned executable acceptance before production admission"
    end
    -- The carrier carries only host-selected configuration inputs. Placement
    -- renders and freezes the driver's final delivery with its own HOME path.
    local gateway: placement_types.Gateway? = nil
    local gateway_input: configuration_protocol.GatewayInput? = nil
    if #launch_policy.gateway_tools > 0 or #launch_policy.gateway_hooks > 0 then
        local address, endpoint_error = gateway_configuration.endpoint()
        if not address then return nil, "gateway: " .. tostring(endpoint_error) end
        local hook_destination: string? = nil
        if #launch_policy.gateway_hooks > 0 then hook_destination = gateway_configuration.HOOK_DESTINATION end
        gateway = {endpoint = address, tools = launch_policy.gateway_tools, destination = gateway_configuration.DESTINATION,
            hooks = launch_policy.gateway_hooks, hook_destination = hook_destination}
        local hook_command, command_error = gateway_configuration.hook_command(launch_policy.hook_command_ref)
        if command_error then return nil, command_error end
        gateway_input = {hook_command = hook_command, endpoint = address, action_id = request.action_id, tools = gateway.tools, hooks = gateway.hooks,
            token_environment = gateway.destination, hook_token_environment = gateway.hook_destination}
    end
    local configure_target = binding.methods.configure
    if not configure_target then return nil, "binding " .. request.binding_ref .. " binds no configure" end
    local provider_entry: Object? = nil
    if launch_policy.provider_ref then
        provider_entry = catalog.entry(pinned, launch_policy.provider_ref)
        if not provider_entry then return nil, "provider " .. launch_policy.provider_ref .. " is not in the registry" end
    end
    local configuration_digest, configuration_error = configuration_protocol.digest({provider_ref = launch_policy.provider_ref,
        provider = provider_entry, instructions = launch_policy.instructions, instruction_builder = launch_policy.instruction_builder, gateway = gateway_input, fixture = launch_policy.fixture}, configure_target)
    if not configuration_digest then return nil, configuration_error end
    return {generation = snapshot.generation, binding = binding, profile = profile, policy = launch_policy, placement_binding = selected_placement, exchange = exchange, push = push,
        configuration_digest = configuration_digest, gateway = gateway}
end
-- A launch may declare a host file it needs before it starts. Bee never
-- copies the owner's configuration or credentials into a private home, so a
-- launch that needs one is only available where the profile inherits the
-- host user's home. The refusal names the declared file without assuming a
-- provider-specific configuration format.
function M.required_file_refusal(launch: driver_types.Launch, private_home: boolean): string?
    if not private_home or not launch.required_files or #launch.required_files == 0 then return nil end
    local file = launch.required_files[1]
    if not file then return nil end
    return "the required host file " .. file.path ..
        " is only available where Bee inherits the user's home; a private home does not carry it"
end
-- plan: pin the usable binding and profile, take the driver's declarative
-- launch, bind executables and requirements from the host policy.
function M.plan(io: IO, request: Request): (Plan?, string?)
    local measured, measure_error = measure(request)
    if not measured then return nil, measure_error end
    local binding, profile, launch_policy, placement_binding, exchange, push, configuration_digest, gateway = measured.binding, measured.profile, measured.policy, measured.placement_binding, measured.exchange, measured.push, measured.configuration_digest, measured.gateway
    if launch_policy.provider_ref and not profile.private_home then
        return nil, "selected provider configuration requires a private-home profile"
    end
    local prepare_target, normalize_target = binding.methods.prepare, binding.methods.normalize
    if not prepare_target or not normalize_target then return nil, "binding " .. request.binding_ref .. " binds no prepare or normalize" end
    local resume_ref: string? = nil
    local previous_private_home: boolean? = nil
    if request.reauthorize == true and (not request.previous_attempt_id or profile.mode ~= "window") then
        return nil, "reauthorization requires a saved window"
    end
    if request.previous_attempt_id then
        if not request.session_ref then return nil, "continuation needs a retained session" end
        if profile.mode == "window" and request.brief ~= "" then return nil, "window continuation cannot replay a brief" end
        local resolver = profile.mode == "window" and continuation.resolve_window or continuation.resolve
        local resumed, resume_error, private_home = resolver(io.call, {thread_id = request.thread_id, action_id = request.action_id, attempt_id = request.attempt_id,
            owner_id = request.owner_id, previous_attempt_id = request.previous_attempt_id, session_ref = request.session_ref,
            binding_ref = binding.binding_id, binding_digest = binding.binding_digest.entry, profile_id = profile.id, profile_digest = binding.profile_digest.entry,
            placement_binding_ref = placement_binding.binding_id, placement_binding_digest = placement_binding.binding_digest, placement_methods = placement_binding.methods, reauthorize = request.reauthorize})
        if not resumed then return nil, resume_error end
        resume_ref = resumed
        previous_private_home = private_home
        local dispatch = binding.methods.dispatch
        if not dispatch then return nil, "driver has no continuation method" end
        prepare_target = dispatch
    end
    local private_home = previous_private_home
    if private_home == nil then private_home = profile.private_home end
    if not private_home and not launch_policy.allow_host_home then
        return nil, "launch policy does not authorize host HOME"
    end
    -- A fresh attempt on a driver without a between-turns controller starts
    -- carrying its oldest outstanding inbox item in the brief. The plan owns
    -- the request table from here; nothing downstream rereads the caller's
    -- brief, and the carry is idempotent across repeated plans.
    request.brief = M.carry_brief(io, request, binding.driver_id, profile.mode)
    local prepare_request: {[string]: unknown} = {}
    for name, value in pairs(launch_policy.prepare_options) do prepare_request[name] = value end
    prepare_request.profile_id = request.profile_id
    prepare_request.brief = request.brief
    prepare_request.resume_ref = resume_ref
    -- The host enabled an interactive permission exchange: the driver
    -- prepares the launch shape that keeps stdin open for the responses.
    if exchange then prepare_request.permission_exchange = true end
    if launch_policy.inbox_push then
        if binding.driver_id ~= "claude" or profile.mode == "window" or profile.protocol ~= "stream-json" then
            return nil, "inbox push requires a Claude structured stream-json profile"
        end
        if not launch_policy.fixture and not push then
            return nil, "inbox push needs a pinned executable acceptance before production admission"
        end
        prepare_request.control_enabled = true
    end
    -- The driver shapes its launch to reach the admitted gateway tools and
    -- to load the hook adapter the runner writes.
    if gateway then
        prepare_request.gateway_tools = gateway.tools
        if #gateway.hooks > 0 then prepare_request.gateway_hooks = gateway.hooks end
    end
    local prepared, prepare_error = io.call(prepare_target, prepare_request)
    if prepare_error or type(prepared) ~= "table" then return nil, "driver prepare: " .. tostring(prepare_error) end
    local prepared_reply = bounds.object(prepared)
    if not prepared_reply then return nil, "driver prepare: reply must be an object" end
    local unexpected = bounds.fields(prepared_reply, {"ok", "error", "launch"})
    if unexpected then return nil, "driver prepare: " .. unexpected end
    if prepared_reply.ok ~= true then return nil, "driver prepare: " .. tostring(prepared_reply.error or "driver refused launch") end
    local decoded_launch, launch_error = launch_request.launch(prepared_reply.launch)
    if not decoded_launch then return nil, "driver prepare: " .. tostring(launch_error) end
    local launch: driver_types.Launch = decoded_launch
    -- The carrier selected HOME from the profile (or preserved it from the
    -- resumed attempt). A driver's provider-home declaration describes its
    -- files and variable, but must follow that same selection: leaving this
    -- private after choosing host HOME makes placement redirect
    -- CLAUDE_CONFIG_DIR into an empty attempt home.
    if launch.provider_home then launch.provider_home.private = private_home end
    local required_refusal = M.required_file_refusal(launch, private_home)
    if required_refusal then return nil, required_refusal end
    if request.session_ref then
        if not bounds.id(request.session_ref) then return nil, "session_ref is not an identifier" end
        local home: string? = nil
        for _, resource in ipairs(request.resources) do
            if resource.purpose == "session" and resource.access == "write" then
                if home then return nil, "retained session needs exactly one home resource" end
                home = resource.name
            end
        end
        if not home then return nil, "retained session needs a writable session resource" end
        launch.home_ref = home
    end
    local bound = launch_policy.executables[launch.executable]
    if bound then launch.executable = bound end
    -- The host-selected executable is measured by placement, read-only,
    -- and the measurement is part of the plan: the runner verifies it
    -- again before exec. An enabled exchange stands on an acceptance record
    -- that names that measurement, so it needs a bound absolute path and a
    -- runtime that can measure it; a fixture policy proceeds without.
    local measurement: placement_types.ExecutableMeasurement? = nil
    local exchange_refusal: string? = nil
    local function refuse_exchange(reason: string)
        if not exchange_refusal then exchange_refusal = reason end
    end
    local push_refusal: string? = nil
    local function refuse_push(reason: string)
        if not push_refusal then push_refusal = reason end
    end
    -- capabilities_refusal: the placement's executable-measurement proof
    -- under the label that needs it, or the hard error when the
    -- capabilities call itself fails. A production channel needs a runtime
    -- that measures a stream and a measurement volume proven read-only;
    -- the report is measured, never declared.
    local function capabilities_refusal(label: string): (string?, string?)
        local capabilities_target = placement_binding.methods.capabilities
        if not capabilities_target then
            return label .. ": selected placement cannot measure an executable", nil
        end
        local capabilities_value, capabilities_error = must(io, capabilities_target, {})
        if capabilities_error then return nil, capabilities_error end
        local reported, report_error = executable_capability(capabilities_value)
        if not reported then return nil, "placement returned malformed executable capabilities: " .. tostring(report_error) end
        if not reported.streaming then return label .. ": this runtime cannot measure an executable as a stream", nil end
        if not reported.read_only_volume then return label .. ": the measurement volume is not proven read-only on this runtime: " .. reported.detail, nil end
        return nil, nil
    end
    if exchange and not launch_policy.fixture then
        local refusal, capabilities_error = capabilities_refusal("production exchange")
        if capabilities_error then return nil, capabilities_error end
        if refusal then refuse_exchange(refusal) end
    end
    if push and not launch_policy.fixture then
        local refusal, capabilities_error = capabilities_refusal("production push")
        if capabilities_error then return nil, capabilities_error end
        if refusal then refuse_push(refusal) end
    end
    if launch.executable:sub(1, 1) == "/" then
        local measure_target = placement_binding.methods.measure_executable
        if measure_target then
            local raw, measure_call_error = io.call(measure_target, {path = launch.executable})
            local reply, reply_error = reply_of(raw, measure_call_error)
            if not reply then return nil, "measure executable: " .. tostring(reply_error) end
            if reply.ok then
                local measured, measured_error = executable_measurement(reply.value, launch.executable)
                if not measured then return nil, "measure executable returned an invalid measurement: " .. tostring(measured_error) end
                measurement = measured
            elseif (exchange or push) and not launch_policy.fixture then
                local fault = reply.error or {code = "UNAVAILABLE", message = "measurement failed"}
                if exchange then refuse_exchange("production exchange: executable measurement: " .. fault.code .. ": " .. fault.message) end
                if push then refuse_push("production push: executable measurement: " .. fault.code .. ": " .. fault.message) end
            end
        elseif (exchange or push) and not launch_policy.fixture then
            if exchange then refuse_exchange("production exchange: selected placement cannot measure the executable") end
            if push then refuse_push("production push: selected placement cannot measure the executable") end
        end
    elseif (exchange or push) and not launch_policy.fixture then
        if exchange then refuse_exchange("production exchange: the launch policy binds no absolute executable to measure") end
        if push then refuse_push("production push: the launch policy binds no absolute executable to measure") end
    end
    if exchange and measurement then
        -- A production exchange covers a measured native image only: a
        -- script's digest pins neither its interpreter nor what it starts.
        if not launch_policy.fixture and measurement.kind ~= "elf" then
            refuse_exchange("production exchange: the executable is a " .. measurement.kind .. ", whose measurement does not cover what runs; a production exchange needs a native image")
        end
        if exchange.executable_revision ~= measurement.revision then refuse_exchange("permission exchange acceptance: executable measurement revision changed since acceptance") end
        if exchange.executable_kind ~= measurement.kind then refuse_exchange("permission exchange acceptance: executable kind changed since acceptance") end
        if exchange.executable_digest ~= measurement.digest then refuse_exchange("permission exchange acceptance: executable measurement changed since acceptance") end
    end
    if push and measurement then
        -- A production push covers the executable the acceptance measured:
        -- push authorizes no tool effect, so the recorded kind stands, and
        -- any revision, kind or digest swap still refuses.
        if push.executable_revision ~= measurement.revision then refuse_push("push acceptance: executable measurement revision changed since acceptance") end
        if push.executable_kind ~= measurement.kind then refuse_push("push acceptance: executable kind changed since acceptance") end
        if push.executable_digest ~= measurement.digest then refuse_push("push acceptance: executable measurement changed since acceptance") end
    end
    local environment: {[string]: string} = {}
    for name, value in pairs(request.environment) do environment[name] = value end
    for name, value in pairs(launch_policy.environment) do
        -- A resumed session keeps the configuration root in which its provider
        -- recorded the conversation. Fresh sessions still inherit every
        -- host-selected override from the current profile.
        if previous_private_home ~= true or launch_policy.host_environment[name] == nil then environment[name] = value end
    end
    if request.working_directory then launch.working_directory_ref = request.working_directory end
    local measured_exchange: {[string]: unknown}? = nil
    if exchange then measured_exchange = {adapter = exchange.adapter.digest, acceptance = exchange.acceptance_ref, acceptance_digest = exchange.acceptance_digest} end
    local measured_push: {[string]: unknown}? = nil
    if push then measured_push = {adapter = push.adapter.digest, acceptance = push.acceptance_ref, acceptance_digest = push.acceptance_digest} end
    local plan_digest, digest_error = digest_of({executable = measurement, policy = launch_policy.digest, binding = binding.binding_digest.entry, profile = binding.profile_digest.entry,
        placement_binding_ref = placement_binding.binding_id, placement_binding_digest = placement_binding.binding_digest, placement_methods = placement_binding.methods,
        launch = launch, session_ref = request.session_ref, previous_attempt_id = request.previous_attempt_id, reauthorize = request.reauthorize,
        environment = environment, permission = measured_exchange, push = measured_push, configuration = configuration_digest, gateway = gateway})
    if not plan_digest then return nil, digest_error end
    local placement_request: placement_types.LaunchRequest = {
        preferences = request.preferences,
        idempotency_key = "placement:" .. request.attempt_id, owner_id = request.owner_id, owner_incarnation = request.owner_incarnation,
        action_id = request.action_id, attempt_id = request.attempt_id, binding_ref = binding.binding_id, policy_ref = launch_policy.ref, profile_id = profile.id,
        binding_digest = binding.binding_digest.entry, profile_digest = binding.profile_digest.entry, placement_binding_ref = placement_binding.binding_id, placement_binding_digest = placement_binding.binding_digest, launch = launch, configuration_digest = configuration_digest, executable = measurement, gateway = gateway, resources = request.resources,
        environment = environment, environment_refs = {}, projections = request.projections or {}, session_ref = request.session_ref, required_cleanup = launch_policy.required_cleanup,
        required_exit_observation = launch_policy.required_exit_observation, timeouts = {start_ms = launch_policy.start_ms, stop_grace_ms = launch_policy.stop_grace_ms, drain_ms = launch_policy.runner_drain_ms, retain_ms = launch_policy.retain_ms},
    }
    if not private_home then
        placement_request.environment_refs.HOME = "bee.env:machine_home"
    end
    return {request = request, binding = binding, profile = profile, launch = launch, policy = launch_policy, placement_binding = placement_binding, plan_digest = plan_digest,
        placement_request = placement_request, exit_codes_trustworthy = false, prepare_target = prepare_target, resume_ref = resume_ref, normalize_target = normalize_target, exchange = exchange, exchange_refusal = exchange_refusal, push = push, push_refusal = push_refusal, gateway = gateway}, nil
end
-- Thread operations of the open sequence key on the attempt and the step,
-- so a start retried after an ambiguous failure replays the same records
-- instead of creating a second action, attempt or turn.
local function thread_call(io: IO, session_request: Request, operation: string, fields: {[string]: unknown}, step_key: string?): (unknown, string?)
    fields.thread_id = session_request.thread_id
    fields.idempotency_key = step_key and ("launch:" .. session_request.attempt_id .. ":" .. step_key) or io.key()
    return must(io, M.THREADS .. ":" .. operation, fields)
end
local function placement_observation(io: IO, session: Session, attempt: placement_types.Attempt): (boolean, string?)
    local payload = json.encode({placement_attempt_id = attempt.attempt_id, execution_state = attempt.execution_state, cleanup_state = attempt.cleanup_state,
        exit_source = attempt.exit_source, evidence_count = attempt.evidence_count, capability = attempt.capability})
    local record = {source = "bee", body = {type = "extension", event_key = "placement:" .. attempt.attempt_id .. ":" .. tostring(attempt.evidence_count),
        data = {type = "extension", event_name = "bee.placement.attempt", event_revision = "1", payload_json = payload}}}
    return M.commit(io, session, {record})
end
-- commit: records and the current checkpoint in one thread transaction.
function M.commit(io: IO, session: Session, records: {{[string]: unknown}}): (boolean, string?)
    local value, err = must(io, M.CARRIER_OPS .. ":commit", {thread_id = session.plan.request.thread_id, idempotency_key = io.key(), attempt_id = session.plan.request.attempt_id,
        carrier_epoch = session.epoch, expected_revision = session.revision, checkpoint = session.checkpoint, records = records})
    if err then return false, err end
    local revision, decode_error = checkpoint.decode_commit(value, session.plan.request.attempt_id, session.epoch)
    if not revision then return false, "carrier commit returned an invalid revision: " .. tostring(decode_error) end
    session.revision = revision
    return true, nil
end
local function new_session(plan: Plan, turn_id: string, epoch: integer, revision: integer, point: checkpoint.Checkpoint): Session
    local decoder = stream_json.new(M.MAX_FRAME_BYTES)
    decoder.framer.carry = point.carry.stdout
    decoder.index = point.envelope_index
    local terminal = point.terminal
    local output: OutputState = "open"
    if point.output == "complete" then output = "complete" elseif point.output == "truncated" then output = "truncated" end
    return {plan = plan, turn_id = turn_id, turn_open = true, epoch = epoch, revision = revision, checkpoint = point, decoder = decoder, normalizer = point.normalizer_state,
        terminal = terminal, stream_ended = point.stream_ended == true, exit = nil, eof = {stdout = false, stderr = false}, runner = nil, settled = nil, recovered = false, output = output, pending_hint = nil, placement_evidence = 0, stderr_sequence = 0,
        last_sequence = {stdout = point.consumed.stdout, stderr = point.consumed.stderr}, held_from = nil,
        dropping_stdout = point.dropping_stdout == true}
end
-- A provider may echo an entire tool input or result in one JSONL status
-- frame. Keep a bounded prefix, record one omission, then drain through the
-- newline. A checkpoint records the drain state for carrier replacement.
type FrameProblem = {index: integer, message: string, sample: string}
type FrameEnvelope = {index: integer, value: {[string]: unknown}}
local function feed_stdout(session: Session, chunk: string, exhausted: boolean): ({FrameEnvelope}, {FrameProblem}, string?)
    local data = chunk
    if session.dropping_stdout then
        local newline = data:find("\n", 1, true)
        if not newline then return {}, {}, nil end
        data = data:sub(newline + 1)
        session.dropping_stdout = false
    end
    local newline = data:find("\n", 1, true)
    local first_length = #session.decoder.framer.carry + (newline or (#data + 1)) - 1
    if first_length > M.MAX_FRAME_BYTES
        or (exhausted and not newline and first_length > checkpoint.MAX_CARRY_BYTES) then
        session.decoder.framer.carry = ""
        session.decoder.index = session.decoder.index + 1
        local problem: FrameProblem = {index = session.decoder.index,
            message = "oversized frame omitted after the bounded runner window", sample = ""}
        if not newline then
            session.dropping_stdout = true
            return {}, {problem}, nil
        end
        local envelopes, rest, feed_error = stream_json.feed(session.decoder, data:sub(newline + 1))
        table.insert(rest, 1, problem)
        return envelopes, rest, feed_error
    end
    local envelopes, problems, feed_error = stream_json.feed(session.decoder, data)
    return envelopes, problems, feed_error
end
-- The gateway binding of an attempt under a carrier epoch: admitted after
-- the durable action and attempt preparation, superseding whatever an
-- earlier or retried carrier admitted, and identified in the checkpoint.
local function gateway_admit(io: IO, plan: Plan, epoch: integer): (string?, string?)
    local gateway = plan.gateway
    if not gateway then return nil, nil end
    local request = plan.request
    -- The admitted attempt's workspace is host-selected, so it travels with the
    -- binding surface's fixed context: a bound tool reads which workspace it
    -- belongs to and no tool argument can replace a host key.
    local surface_value = plan.policy.gateway_surface
    if request.workspace_id then
        -- A policy may declare no surface; the binding then admits with the
        -- same default surface gateway.admit would build, so the workspace
        -- still travels as host-selected fixed context.
        if not surface_value then
            surface_value = {tools = {}, traits = {}, base_tools = gateway.tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
        end
        surface_value = policy.with_workspace(surface_value, request.workspace_id)
        if not surface_value then return nil, "gateway admit: cannot compose the launch workspace" end
    end
    local admitted, admit_error = must(io, M.GATEWAY .. ":admit", {subject = request.owner_id, action_id = request.action_id, attempt_id = request.attempt_id, thread_id = request.thread_id,
        owner_incarnation = request.owner_incarnation, carrier_epoch = epoch, tools = gateway.tools, hooks = gateway.hooks, ttl_ms = plan.policy.gateway_ttl_ms, surface = surface_value,
        policy_ref = plan.policy.ref, workspace_id = request.workspace_id, origin_view = request.origin_view})
    if admit_error then return nil, "gateway admit: " .. admit_error end
    local binding, binding_error = gateway_protocol.admitted_binding(admitted)
    if not binding then return nil, "gateway admit returned an invalid binding: " .. tostring(binding_error) end
    local binding_id = binding.binding_id
    step(io, "gateway_admitted")
    return binding_id, nil
end
-- Readiness under the current listener generation with a valid binding,
-- taken immediately before placement starts the child.
local function gateway_ready(io: IO, binding_id: string): string?
    local ready, ready_error = must(io, M.GATEWAY .. ":ready", {binding_id = binding_id})
    if ready_error then return "gateway readiness: " .. ready_error end
    local report, report_error = gateway_protocol.readiness(ready, binding_id)
    if not report then return "gateway readiness returned malformed data: " .. tostring(report_error) end
    if not report.listening then return "gateway readiness: the listener is not ready" end
    if report.binding_valid ~= true then return "gateway readiness: " .. tostring(report.binding_reason) end
    step(io, "gateway_ready")
    return nil
end
local function gateway_revoke(io: IO, binding_id: string?)
    if not binding_id then return end
    io.call(M.GATEWAY .. ":revoke", {binding_id = binding_id})
end
-- drain_hooks: claim what the gateway queued for this binding under this
-- carrier's epoch, commit it through the carrier's own commit path, then
-- acknowledge; a crash between the commit and the acknowledgment is
-- recovered by the next claim, whose commit replays. Nothing here settles
-- anything or extends an attempt.
function M.drain_hooks(io: IO, session: Session): (integer, string?)
    local binding_id = session.checkpoint.gateway_binding
    local gateway = session.plan.gateway
    if not binding_id then return 0, nil end
    if not gateway then return 0, nil end
    if #gateway.hooks == 0 or session.settled then return 0, nil end
    local drained = 0
    for _ = 1, 8 do
        local raw, call_error = io.call(M.GATEWAY .. ":hook_claim", {binding_id = binding_id, carrier_epoch = session.epoch, limit = 16})
        local reply, reply_error = reply_of(raw, call_error)
        if not reply then return drained, "hook claim: " .. tostring(reply_error) end
        if not reply.ok then
            local fault = reply.error or {code = "UNAVAILABLE", message = "hook claim failed"}
            -- An invalid binding may have rejected only unclaimed rows. A
            -- successful empty claim means no retained claim is recoverable
            -- by this carrier; a conflict leaves takeover to its successor.
            if fault.code == "DENIED" or fault.code == "CONFLICT" then return drained, nil end
            return drained, "hook claim: " .. fault.code .. ": " .. fault.message
        end
        local claim, claim_error = gateway_protocol.hook_claim(reply.value, binding_id, session.epoch)
        if not claim then return drained, "hook claim returned malformed data: " .. tostring(claim_error) end
        local turn_id = session.turn_open and session.turn_id or nil
        local batch, batch_error = hook_records.batch(binding_id, turn_id, claim.hooks)
        if not batch then return drained, "hook batch: " .. tostring(batch_error) end
        if #batch.event_ids == 0 then return drained, nil end
        step(io, "hooks_claimed")
        local records = batch.records
        local event_ids = batch.event_ids
        local committed, commit_error = M.commit(io, session, records)
        if not committed then return drained, commit_error end
        step(io, "hooks_committed")
        local _, ack_error = must(io, M.GATEWAY .. ":hook_ack", {binding_id = binding_id, carrier_epoch = session.epoch, event_ids = event_ids})
        if ack_error then return drained, "hook ack: " .. ack_error end
        step(io, "hooks_acknowledged")
        drained = drained + #event_ids
    end
    return drained, nil
end
-- Preparation is shared by structured and native-window execution. It admits
-- the action, prepares and claims its attempt, admits the gateway, and records
-- placement intent. It does not request a turn, attach a transport or start a
-- child; the selected execution path owns those operations.
type PreparedAttempt = {epoch: integer, gateway_binding: string?, notice: placement_types.LoginNotice?}
type FailedPreparation = {epoch: integer?, gateway_binding: string?, attempt: boolean}
local function prepare_notice(value: unknown): (placement_types.LoginNotice?, string?)
    local attempt, attempt_error = placement_decode.attempt(value)
    if not attempt then return nil, "placement prepare returned an invalid attempt: " .. tostring(attempt_error) end
    return attempt.notice, nil
end
-- Every placement operation is selected once in the measured plan. Persisted
-- and admitted plans always carry the concrete binding and its targets.
function M.placement_target(plan: Plan, method: string): string?
    return plan.placement_binding.methods[method]
end
-- attach_action: a fresh sequential attempt on an action an earlier attempt
-- already admitted. The admit call reports the action exists; this verifies
-- the existing action is the requester's own and discovers its latest
-- settled attempt to chain, so two starters cannot prepare concurrently.
-- Anything unverified fails closed with the admit refusal. The owner still
-- enforces the chain, the open thread and the single live attempt.
M.ATTACH_SCAN_PAGES = 8
M.ATTACH_PAGE_RECORDS = inbox.DELIVERY_PAGE_RECORDS
function M.attach_action(io: IO, request: Request): (string?, boolean, string?)
    local owned = false
    local previous: string? = nil
    local previous_sequence = 0
    local cursor = 0
    for _ = 1, M.ATTACH_SCAN_PAGES do
        local page, read_error = must(io, M.THREADS .. ":read_after", {thread_id = request.thread_id, cursor = cursor, limit = M.ATTACH_PAGE_RECORDS})
        if read_error then return nil, false, read_error end
        local decoded_page, page_error = thread_page(page, cursor, M.ATTACH_PAGE_RECORDS)
        if not decoded_page then return nil, false, "read_after answered with an invalid page: " .. tostring(page_error) end
        for _, record in ipairs(decoded_page.records) do
            if record.action_id == request.action_id then
                if record.kind == "action.admitted" then
                    local admitted = bounds.object(record.body)
                    if admitted and admitted.principal_id == request.owner_id then owned = true end
                elseif record.kind == "receipt" then
                    local receipt = bounds.object(record.body)
                    if receipt and receipt.scope == "attempt" and record.attempt_id and record.sequence > previous_sequence then
                        previous, previous_sequence = record.attempt_id, record.sequence
                    end
                end
            end
        end
        if not decoded_page.has_more then break end
        if decoded_page.scanned_through <= cursor then return nil, false, "read_after did not advance its cursor" end
        cursor = decoded_page.scanned_through
    end
    if not owned then return nil, false, nil end
    return previous, true, nil
end
function M.prepare_attempt(io: IO, plan: Plan): (PreparedAttempt?, string?, FailedPreparation?)
    if plan.exchange_refusal then return nil, plan.exchange_refusal, nil end
    if plan.push_refusal then return nil, plan.push_refusal, nil end
    local request = plan.request
    local attempt_prepared = false
    local action_admitted = false
    local epoch: integer? = nil
    local gateway_binding: string? = nil
    local grant_refs: {string} = {}
    for _, grant in ipairs(request.resources) do grant_refs[#grant_refs + 1] = grant.grant_ref end
    -- A sequential attempt chains the action's latest settled attempt. A
    -- resumed attempt names its predecessor; a fresh one discovers it when
    -- the action is already admitted, so two starters still serialize on
    -- the owner's chain check.
    local expected_previous: string? = request.previous_attempt_id
    if not request.previous_attempt_id then
        -- Opening an interactive UI is an action even with no initial prompt.
        -- Describe that action in the ledger without sending text to the child.
        local action_input = request.brief
        if action_input == "" and plan.profile.mode == "window" then action_input = "Open " .. plan.binding.title .. " window" end
        local admitted_body = {request_id = "launch:" .. request.attempt_id, principal_id = request.owner_id,
            binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, grant_refs = grant_refs, budget_ref = plan.policy.ref, input = {text = action_input}}
        if request.parent_action_id then admitted_body.parent_action_id = request.parent_action_id end
        local _, admit_error = thread_call(io, request, "admit_action", {action_id = request.action_id, admitted = admitted_body}, "admit")
        if admit_error then
            local previous, attached, attach_error = M.attach_action(io, request)
            if not attached then return nil, attach_error or admit_error, nil end
            expected_previous = previous
        end
        action_admitted = true
    end
    step(io, "admitted")
    local _, prepare_error = thread_call(io, request, "prepare_attempt", {action_id = request.action_id, attempt_id = request.attempt_id, expected_previous_attempt_id = expected_previous, prepared = {
        binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry,
        placement_binding = plan.placement_binding.binding_id, placement_binding_digest = plan.placement_binding.binding_digest,
        placement_attempt_id = request.attempt_id, plan_digest = plan.plan_digest}}, "prepare")
    if prepare_error then
        if not action_admitted then return nil, prepare_error, nil end
        return nil, prepare_error, {epoch = nil, gateway_binding = nil, attempt = false}
    end
    attempt_prepared = true
    step(io, "prepared")
    local claimed, claim_error = must(io, M.CARRIER_OPS .. ":claim", {thread_id = request.thread_id, idempotency_key = "launch:" .. request.attempt_id .. ":claim", attempt_id = request.attempt_id})
    if claim_error then return nil, claim_error, {epoch = nil, gateway_binding = nil, attempt = attempt_prepared} end
    local claimed_epoch, claim_decode_error = checkpoint.decode_claim(claimed)
    if not claimed_epoch then return nil, "carrier claim returned an invalid epoch: " .. tostring(claim_decode_error) end
    epoch = claimed_epoch
    local gateway_error: string?
    gateway_binding, gateway_error = gateway_admit(io, plan, epoch)
    if gateway_error then return nil, gateway_error, {epoch = epoch, gateway_binding = nil, attempt = attempt_prepared} end
    local function abandon(err: string): (PreparedAttempt?, string?, FailedPreparation?)
        gateway_revoke(io, gateway_binding)
        return nil, err, {epoch = epoch, gateway_binding = gateway_binding, attempt = attempt_prepared}
    end
    local prepare_target = M.placement_target(plan, "prepare")
    if not prepare_target then return abandon("selected placement binds no prepare") end
    local intent, intent_error = must(io, prepare_target, plan.placement_request)
    if intent_error then return abandon(intent_error) end
    local notice, notice_error = prepare_notice(intent)
    if notice_error then return abandon(notice_error) end
    step(io, "placement_intent")
    return {epoch = epoch, gateway_binding = gateway_binding, notice = notice}, nil, nil
end
local function settle_prestart_failure(io: IO, plan: Plan, epoch: integer, gateway_binding: string?, reason: string,
    session: Session?, turn_id: string?, outcome: prestart.Outcome?)
    local request = plan.request
    local inspection = prestart.inspect(io.call, M.placement_target(plan, "status"), M.placement_target(plan, "stop"),
        request.attempt_id, outcome or "failed", reason)
    local settled_outcome, message = inspection.outcome, inspection.reason
    gateway_revoke(io, gateway_binding)
    local code = settled_outcome == "uncertain" and "launch_uncertain" or "launch_failed"
    local failure = {code = code, message = message, retryable = false}
    if turn_id then
        thread_call(io, request, "end_turn", {action_id = request.action_id, attempt_id = request.attempt_id,
            turn_id = turn_id, carrier_epoch = epoch, turn_end = {outcome = settled_outcome, answer_message_ids = {},
                evidence_refs = {}, error = failure}}, "failed:end_turn")
    end
    local point = session and session.checkpoint or checkpoint.new({binding_ref = plan.binding.binding_id,
        binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id,
        profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest,
        gateway_binding = gateway_binding}, epoch)
    point.terminal = {outcome = settled_outcome, answer = nil, error = failure}
    local stored, stored_error = must(io, M.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    local stored_object = bounds.object(stored)
    local revision = stored_object and bounds.integer(stored_object.checkpoint_revision)
    if not stored_error and revision and stored_object and stored_object.carrier_epoch == epoch then
        must(io, M.CARRIER_OPS .. ":commit", {thread_id = request.thread_id,
            attempt_id = request.attempt_id, idempotency_key = "launch:" .. request.attempt_id .. ":failure:checkpoint",
            carrier_epoch = epoch, expected_revision = revision, checkpoint = point, records = {}})
    end
    thread_call(io, request, "receipt", {action_id = request.action_id, attempt_id = request.attempt_id,
        carrier_epoch = epoch, receipt = {scope = "attempt", outcome = settled_outcome, evidence_refs = {}, error = failure}}, "failed:receipt")
end
-- Structured execution requests a turn and starts the pipe runner only after
-- shared preparation. Failures before execution retire the admitted gateway.
function M.open(io: IO, plan: Plan): (Session?, string?)
    if plan.profile.mode == "window" or plan.profile.protocol ~= "stream-json" then
        return nil, "structured carrier requires a stream-json session or batch profile"
    end
    local prepared, preparation_error, failed_preparation = M.prepare_attempt(io, plan)
    if not prepared then
        if failed_preparation and failed_preparation.attempt and failed_preparation.epoch then
            settle_prestart_failure(io, plan, failed_preparation.epoch, failed_preparation.gateway_binding,
                "launch preparation failed: " .. tostring(preparation_error))
        end
        return nil, preparation_error
    end
    local request = plan.request
    local epoch, gateway_binding = prepared.epoch, prepared.gateway_binding
    local turn_id = "turn:" .. request.attempt_id .. ":1"
    local _, turn_error = thread_call(io, request, "request_turn", {action_id = request.action_id, attempt_id = request.attempt_id, turn_id = turn_id, carrier_epoch = epoch,
        turn = {input_message_ids = {}, input = {text = request.brief}, resume_ref = plan.resume_ref, delivery_ids = {}}}, "turn")
    if turn_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "request turn failed: " .. turn_error, nil, turn_id)
        return nil, turn_error
    end
    step(io, "turn_requested")
    local point = checkpoint.new({binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest, gateway_binding = gateway_binding}, epoch)
    point.retained_session_ref = request.session_ref
    local session = new_session(plan, turn_id, epoch, 0, point)
    local committed, commit_error = M.commit(io, session, {})
    if not committed then
        local reason = "initial checkpoint failed: " .. tostring(commit_error or "commit")
        settle_prestart_failure(io, plan, epoch, gateway_binding, reason, session, turn_id)
        return nil, commit_error or "commit"
    end
    local attach_target = M.placement_target(plan, "attach")
    if not attach_target then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "selected placement binds no attach", session, turn_id)
        return nil, "selected placement binds no attach"
    end
    local _, attach_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
    if attach_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "placement attach failed: " .. attach_error, session, turn_id)
        return nil, attach_error
    end
    step(io, "attached")
    if gateway_binding then
        local readiness_error = gateway_ready(io, gateway_binding)
        if readiness_error then
            settle_prestart_failure(io, plan, epoch, gateway_binding, readiness_error, session, turn_id)
            return nil, readiness_error
        end
    end
    local start_target = M.placement_target(plan, "start")
    if not start_target then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "selected placement binds no start", session, turn_id)
        return nil, "selected placement binds no start"
    end
    local started_value, start_error = must(io, start_target, {attempt_id = request.attempt_id, gateway_binding = gateway_binding})
    if start_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "placement start failed: " .. start_error, session, turn_id)
        return nil, start_error
    end
    step(io, "placement_started")
    local attempt, attempt_error = placement_decode.attempt(started_value)
    if not attempt then
        local reason = "placement start returned an invalid attempt: " .. tostring(attempt_error)
        settle_prestart_failure(io, plan, epoch, gateway_binding, reason, session, turn_id)
        return nil, reason
    end
    session.runner = attempt.runner
    local _, started_error = thread_call(io, request, "start_attempt", {action_id = request.action_id, attempt_id = request.attempt_id,
        started = {execution_kind = "process", execution_ref = attempt.attempt_id, owner_epoch = io.now_ms()}})
    if started_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "recording placement start failed: " .. started_error, session, turn_id)
        return nil, started_error
    end
    step(io, "attempt_started")
    local observed, observe_error = placement_observation(io, session, attempt)
    if not observed then return nil, observe_error end
    return session, nil
end
-- resume: a replacement carrier continues from the stored checkpoint under
-- a new epoch; the runner resends what the old carrier never acknowledged.
function M.resume(io: IO, plan: Plan): (Session?, string?)
    if plan.profile.mode == "window" or plan.profile.protocol ~= "stream-json" then
        return nil, "structured carrier requires a stream-json session or batch profile"
    end
    local request = plan.request
    local stored, stored_error = must(io, M.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    if stored_error then return nil, stored_error end
    local view, view_error = checkpoint.decode_checkpoint_view(stored)
    if not view then return nil, "stored checkpoint view: " .. tostring(view_error) end
    if view.attempt_state == "ended" then return nil, "attempt has ended" end
    if view.checkpoint == nil then return nil, "no checkpoint to resume from" end
    local point, point_error = checkpoint.decode(view.checkpoint)
    if not point then return nil, "stored checkpoint: " .. tostring(point_error) end
    if point.binding_digest ~= plan.binding.binding_digest.entry or point.profile_digest ~= plan.binding.profile_digest.entry then return nil, "pinned measurements changed since the checkpoint" end
    if view.placement_binding ~= plan.placement_binding.binding_id then return nil, "placement binding changed since the checkpoint" end
    if view.placement_binding_digest ~= plan.placement_binding.binding_digest then return nil, "placement binding digest missing or changed since the checkpoint" end
    step(io, "checkpoint_read")
    local claimed, claim_error = must(io, M.CARRIER_OPS .. ":claim", {thread_id = request.thread_id, idempotency_key = io.key(), attempt_id = request.attempt_id})
    if claim_error then return nil, claim_error end
    local epoch, claim_decode_error = checkpoint.decode_claim(claimed)
    if not epoch then return nil, "carrier claim returned an invalid epoch: " .. tostring(claim_decode_error) end
    -- A live carrier commits until the claim fences it, so the replacement
    -- continues from the checkpoint as the claim left it, not as first read.
    local fenced, fenced_error = must(io, M.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    if fenced_error then return nil, fenced_error end
    local fenced_view, fenced_view_error = checkpoint.decode_checkpoint_view(fenced)
    if not fenced_view then return nil, "fenced checkpoint view: " .. tostring(fenced_view_error) end
    view = fenced_view
    if view.carrier_epoch ~= epoch then return nil, "carrier epoch " .. tostring(epoch) .. " was superseded by " .. tostring(view.carrier_epoch) end
    if view.attempt_state == "ended" then return nil, "attempt has ended" end
    local fenced_point, fenced_point_error = checkpoint.decode(view.checkpoint)
    if not fenced_point then return nil, "stored checkpoint: " .. tostring(fenced_point_error) end
    local moved = checkpoint.continues(point, fenced_point)
    if moved then return nil, "stored checkpoint: " .. moved end
    point = fenced_point
    local session = new_session(plan, "turn:" .. request.attempt_id .. ":1", epoch, view.checkpoint_revision, checkpoint.rebind(point, epoch))
    session.recovered = true
    local status_target = M.placement_target(plan, "status")
    if not status_target then return nil, "selected placement binds no status" end
    local status_value, status_error = must(io, status_target, {attempt_id = request.attempt_id})
    if status_error then return nil, status_error end
    local status, status_decode_error = placement_decode.status(status_value)
    if not status then return nil, "placement status is malformed: " .. tostring(status_decode_error) end
    local attempt = status.attempt
    -- Before placement starts, a plan that no longer digests as recorded
    -- refuses: nothing was materialized under it. A started attempt is
    -- still carried, and revalidation refuses any dispatch under it.
    if attempt.execution_state == "intended" and point.plan_digest and point.plan_digest ~= plan.plan_digest then
        return nil, "pinned measurements changed since the checkpoint: the plan no longer digests as recorded"
    end
    if attempt.execution_state == "intended" then
        -- A start that failed between placement intent and placement start
        -- resumes by starting the same attempt; placement start is idempotent.
        -- The gateway binding is admitted anew under this epoch, which
        -- supersedes whatever the lost carrier admitted, and readiness is
        -- taken again immediately before the start.
        local gateway_binding, gateway_error = gateway_admit(io, plan, epoch)
        if gateway_error then return nil, gateway_error end
        session.checkpoint.gateway_binding = gateway_binding
        local function abandon(err: string): (Session?, string?)
            gateway_revoke(io, gateway_binding)
            return nil, err
        end
        if gateway_binding then
            local committed, commit_error = M.commit(io, session, {})
            if not committed then return abandon(commit_error or "commit") end
        end
        local attach_target = M.placement_target(plan, "attach")
        if not attach_target then return abandon("selected placement binds no attach") end
        local _, attach_first_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
        if attach_first_error then return abandon(attach_first_error) end
        if gateway_binding then
            local readiness_error = gateway_ready(io, gateway_binding)
            if readiness_error then return abandon(readiness_error) end
        end
        local start_target = M.placement_target(plan, "start")
        if not start_target then return abandon("selected placement binds no start") end
        local started_value, placement_error = must(io, start_target, {attempt_id = request.attempt_id, gateway_binding = gateway_binding})
        if placement_error then return abandon(placement_error) end
        local started_attempt, started_decode_error = placement_decode.attempt(started_value)
        if not started_attempt then return abandon("placement start returned an invalid attempt: " .. tostring(started_decode_error)) end
        attempt = started_attempt
        session.runner = attempt.runner
        step(io, "placement_started")
        local _, started_error = thread_call(io, request, "start_attempt", {action_id = request.action_id, attempt_id = request.attempt_id,
            started = {execution_kind = "process", execution_ref = attempt.attempt_id, owner_epoch = io.now_ms()}})
        if started_error then return nil, started_error end
        step(io, "attempt_started")
        local observed, observe_error = placement_observation(io, session, attempt)
        if not observed then return nil, observe_error end
        session.turn_open = view.open_turn_id ~= nil
        if view.open_turn_id then session.turn_id = view.open_turn_id end
        step(io, "reattached")
        return session, nil
    end
    if view.attempt_state == "prepared" then
        local _, started_error = thread_call(io, request, "start_attempt", {action_id = request.action_id, attempt_id = request.attempt_id,
            started = {execution_kind = "process", execution_ref = attempt.attempt_id, owner_epoch = io.now_ms()}})
        if started_error then return nil, started_error end
        step(io, "attempt_started")
    end
    session.turn_open = view.open_turn_id ~= nil
    if view.open_turn_id then session.turn_id = view.open_turn_id end
    if attempt.execution_state == "exited" then
        local exit = attempt.exit
        session.exit = {code = exit and exit.code or nil, signal = exit and exit.signal or nil, uncertain = attempt.exit_source == nil}
    end
    -- A runner that still holds unacknowledged output or an unanswered
    -- write outlives the child; attach reaches it while it lives. Once it
    -- is gone nothing resends output past the checkpoint, no write can be
    -- asked about, and settlement comes from the recorded exit after the
    -- drain.
    local attach_target = M.placement_target(plan, "attach")
    if not attach_target then return nil, "selected placement binds no attach" end
    local attached_value, attach_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
    if attach_error then
        if attempt.execution_state ~= "exited" and attempt.execution_state ~= "uncertain" then return nil, attach_error end
        -- Placement can prove neither exit nor presence and no runner
        -- answers: the outcome is uncertain, the effect unknown, and
        -- nothing is resent or rewritten.
        if attempt.execution_state == "uncertain" then session.exit = {code = nil, signal = nil, uncertain = true} end
        session.eof = {stdout = true, stderr = true}
        -- Durable evidence stands: only an output state the checkpoint never
        -- settled becomes unobserved.
        if session.output == "open" then session.output = "unobserved" end
        step(io, "reattached")
        return session, nil
    end
    local attached_attempt, attached_decode_error = placement_decode.attempt(attached_value)
    if not attached_attempt then return nil, "placement attach returned an invalid attempt: " .. tostring(attached_decode_error) end
    session.runner = attached_attempt.runner
    step(io, "reattached")
    return session, nil
end
local function snapshot_object(value: unknown, label: string, maximum: integer): (Object?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, label .. " must be an object" end
    local encoded, encode_error = canonical.encode(object)
    if not encoded then return nil, label .. " is not valid JSON: " .. tostring(encode_error) end
    if #encoded > maximum then return nil, label .. " exceeds " .. tostring(maximum) .. " bytes" end
    local decoded, decode_error = json.decode(encoded)
    if decode_error then return nil, label .. " could not be copied: " .. tostring(decode_error) end
    local copied = bounds.object(decoded)
    if not copied then return nil, label .. " did not decode as an object" end
    return copied, nil
end
local function snapshot_state(value: unknown): (Object?, string?)
    if value == nil then return nil, nil end
    local state, state_error = checkpoint.normalizer_state(value)
    if not state then return nil, state_error end
    return snapshot_object(state, "normalizer_state", checkpoint.MAX_NORMALIZER_STATE_BYTES)
end
local function snapshot_terminal(value: driver_types.Terminal?): (driver_types.Terminal?, string?)
    if value == nil then return nil, nil end
    local copied, copy_error = snapshot_object(value, "terminal", checkpoint.MAX_TERMINAL_BYTES)
    if not copied then return nil, copy_error end
    return checkpoint.decode_terminal(copied)
end
type Normalized = {state: Object, observations: {record_types.Observation}, terminal: driver_types.Terminal?}
local function decode_normalized(value: unknown): (Normalized?, string?)
    local object = bounds.object(value)
    if not object then return nil, "reply must be an object" end
    local unknown_field = bounds.fields(object, {"ok", "error", "state", "observations", "terminal"})
    if unknown_field then return nil, "reply: " .. unknown_field end
    if object.ok == false then
        if object.state ~= nil or object.observations ~= nil or object.terminal ~= nil then return nil, "failed reply carries successful result fields" end
        local message = bounds.text(object.error, 4096)
        if not message or message == "" then return nil, "failure has no bounded error" end
        return nil, message
    end
    if object.ok ~= true or object.error ~= nil then return nil, "reply status is invalid" end
    if object.state == nil then return nil, "successful reply has no normalizer state" end
    local state, state_error = checkpoint.normalizer_state(object.state)
    if not state then return nil, "normalizer state: " .. tostring(state_error) end
    local raw_observations, array_error = bounds.array(object.observations, bounds.MAX_ARRAY_ITEMS)
    if not raw_observations then return nil, "normalizer observations must be a bounded dense list: " .. tostring(array_error) end
    local observations: {record_types.Observation} = {}
    for index, raw in ipairs(raw_observations) do
        local item, observation_error = observation_decode.decode(raw)
        if not item then return nil, "normalizer observations[" .. tostring(index) .. "]: " .. tostring(observation_error) end
        observations[index] = item
    end
    local terminal: driver_types.Terminal? = nil
    if object.terminal ~= nil then
        terminal, state_error = checkpoint.decode_terminal(object.terminal)
        if not terminal then return nil, "normalizer terminal: " .. tostring(state_error) end
    end
    return {state = state, observations = observations, terminal = terminal}, nil
end
local function normalize(io: IO, session: Session, index: integer, envelope: {[string]: unknown}?, eof: boolean): ({record_types.Observation}?, driver_types.Terminal?, string?)
    local reply, err = io.call(session.plan.normalize_target, {state = session.normalizer, index = index, envelope = envelope, eof = eof, resumed = false})
    if err then return nil, nil, "driver normalize: " .. err end
    local result, decode_error = decode_normalized(reply)
    if not result then return nil, nil, "driver normalize: " .. tostring(decode_error) end
    session.normalizer = result.state
    return result.observations, result.terminal, nil
end
-- One output chunk: frame, normalize, commit in bounded batches, then
-- acknowledge. A chunk the carrier cannot checkpoint is never acknowledged.
-- attached: the runner names itself to the recipient of the current
-- generation; only that sender's traffic is honoured afterwards.
function M.on_attached(session: Session, sender: string, message: placement_protocol.Attached): boolean
    if message.generation ~= session.epoch or message.attempt_id ~= session.plan.request.attempt_id then return false end
    session.runner = sender
    return true
end
local function from_runner(session: Session, sender: string, generation: integer): boolean
    return session.runner ~= nil and sender == session.runner and generation == session.epoch
end
-- Permission exchange. Every key is derived once from owner, attempt and
-- the request's event key and kept in the checkpoint; the thread carries
-- one control record per phase under a deterministic key.
local function acknowledged_through(session: Session, sequence: integer): integer
    local held = session.held_from
    if held and held - 1 < sequence then return held - 1 end
    return sequence
end
function M.on_output(io: IO, session: Session, sender: string, message: placement_protocol.Output): (boolean, string?)
    if not from_runner(session, sender, message.generation) then return true, nil end
    if message.sequence <= session.last_sequence[message.stream] then
        io.send(sender, placement_protocol.TOPIC_ACK, {generation = session.epoch, consumed_through = acknowledged_through(session, message.sequence)})
        return true, nil
    end
    local before_state, before_state_error = snapshot_state(session.normalizer)
    if session.normalizer ~= nil and before_state == nil then return false, "normalizer state cannot be checkpointed: " .. tostring(before_state_error) end
    local before_terminal, before_terminal_error = snapshot_terminal(session.terminal)
    if session.terminal ~= nil and before_terminal == nil then return false, "terminal cannot be checkpointed: " .. tostring(before_terminal_error) end
    local was_held = session.held_from ~= nil
    local before = {carry = session.decoder.framer.carry, index = session.decoder.index, state = before_state,
        terminal = before_terminal, stream_ended = session.stream_ended, dropping_stdout = session.dropping_stdout,
        output = session.output, checkpoint_output = session.checkpoint.output, eof_stdout = session.eof.stdout,
        eof_stderr = session.eof.stderr, held_from = session.held_from, stderr_sequence = session.stderr_sequence}
    local function refuse(reason: string): (boolean, string?)
        session.decoder.framer.carry = before.carry
        session.decoder.index = before.index
        session.normalizer = before.state
        session.terminal = before.terminal
        session.stream_ended = before.stream_ended
        session.dropping_stdout = before.dropping_stdout
        session.output = before.output
        session.checkpoint.output = before.checkpoint_output
        session.eof.stdout = before.eof_stdout
        session.eof.stderr = before.eof_stderr
        session.held_from = before.held_from
        session.stderr_sequence = before.stderr_sequence
        return false, reason
    end
    local records: {{[string]: unknown}} = {}
    if message.eof then
        session.eof[message.stream] = true
        if message.truncated then
            mark_output(session, "truncated")
            local truncation: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = "output:" .. session.plan.request.attempt_id .. ":" .. message.stream .. ":truncated",
                data = {type = "extension", event_name = "bee.carrier.output", event_revision = "1", payload_json = json.encode({attempt_id = session.plan.request.attempt_id, stream = message.stream, state = "truncated", attachment_generation = session.epoch})}}}
            records[#records + 1] = truncation
        elseif session.eof.stdout and session.eof.stderr and session.output == "open" then
            mark_output(session, "complete")
        end
        if message.stream == "stdout" then
            local observations, terminal, err = normalize(io, session, session.decoder.index + 1, nil, true)
            if not observations then return refuse(err or "driver normalize failed") end
            for event_index, item in ipairs(observations) do
                records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence,
                    source_last_sequence = message.sequence, envelope_index = session.decoder.index + 1, event_index = event_index - 1}, body = item}
            end
            if terminal and not session.terminal then
                session.terminal = terminal
                session.stream_ended = true
            end
        end
    elseif message.stream == "stdout" then
        -- The runner stops sending once its unacknowledged window is full.
        -- Count from the last durable acknowledgment, not from the chunk
        -- where the partial frame first exceeded the checkpoint carry. The
        -- runner cannot send chunk 17 until all 16 unacknowledged chunks move.
        local exhausted = message.sequence - session.checkpoint.consumed.stdout >= placement_protocol.MAX_OUTSTANDING_CHUNKS
        local envelopes, problems, framing_error = feed_stdout(session, message.data or "", exhausted)
        if framing_error then
            local fault = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence, source_last_sequence = message.sequence,
                envelope_index = session.decoder.index + 1, event_index = 0}, body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "error", code = "framing", content = {text = framing_error}}}}
            session.terminal = {outcome = "uncertain", answer = nil, resume_ref = nil, usage = nil, error = {code = "framing", message = framing_error, retryable = false}}
            records[#records + 1] = fault
        else
            for _, problem in ipairs(problems) do
                local code = problem.message:find("oversized frame omitted", 1, true) and "oversized_frame" or "undecodable_frame"
                records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence, source_last_sequence = message.sequence,
                    envelope_index = problem.index, event_index = 0}, body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "warning", code = code, content = {text = problem.message}}}}
            end
            for _, envelope in ipairs(envelopes) do
                local observations, terminal, err = normalize(io, session, envelope.index, envelope.value, false)
                if not observations then return refuse(err or "driver normalize failed") end
                for event_index, item in ipairs(observations) do
                    records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stdout", source_first_sequence = message.sequence,
                        source_last_sequence = message.sequence, envelope_index = envelope.index, event_index = event_index - 1}, body = item}
                end
                if terminal and not session.terminal then session.terminal = terminal end
            end
        end
    else
        session.stderr_sequence = session.stderr_sequence + 1
        records[#records + 1] = {source = "stream", provenance = {schema_revision = provenance.REVISION, stream_id = "stderr", source_first_sequence = message.sequence, source_last_sequence = message.sequence,
            envelope_index = message.sequence, event_index = 0}, body = {type = "notice", event_key = "ignored", data = {type = "notice", level = "info", code = "stderr", content = {text = message.data or ""}}}}
    end
    if session.turn_open then
        for _, record in ipairs(records) do record.turn_id = session.turn_id end
    end
    if message.stream == "stdout" then
        if #session.decoder.framer.carry > checkpoint.MAX_CARRY_BYTES then
            session.held_from = session.held_from or message.sequence
        else
            session.held_from = nil
        end
    end
    -- Only a boundary whose partial frame fits the checkpoint moves the
    -- stdout position; records committed beyond it replay idempotently from
    -- the chunks the runner still holds.
    local at_boundary = session.held_from == nil
    local detected, detect_error = permission_exchange.detect(permission_context(), session, records)
    if detect_error then return refuse(detect_error) end
    permission_exchange.acknowledge(session, records)
    local total = #records
    local offset = 0
    while true do
        local batch: {{[string]: unknown}} = {}
        for index = offset + 1, math.min(offset + M.MAX_RECORDS_PER_COMMIT, total) do batch[#batch + 1] = records[index] end
        local final = offset + #batch >= total
        if final and at_boundary then
            local state, state_error = snapshot_state(session.normalizer)
            if session.normalizer ~= nil and state == nil then return refuse("normalizer state cannot be checkpointed: " .. tostring(state_error)) end
            local terminal, terminal_error = snapshot_terminal(session.terminal)
            if session.terminal ~= nil and terminal == nil then return refuse("terminal cannot be checkpointed: " .. tostring(terminal_error)) end
            session.checkpoint.consumed[message.stream] = message.sequence
            session.checkpoint.carry.stdout = session.decoder.framer.carry
            session.checkpoint.dropping_stdout = session.dropping_stdout
            session.checkpoint.envelope_index = session.decoder.index
            session.checkpoint.normalizer_state = state
            session.checkpoint.event_cursor = nil
            session.checkpoint.terminal = terminal
            session.checkpoint.stream_ended = session.stream_ended
        elseif final and message.stream == "stderr" then
            session.checkpoint.consumed.stderr = message.sequence
        elseif not final and not was_held and at_boundary then
            session.checkpoint.carry.stdout = before.carry
            session.checkpoint.dropping_stdout = before.dropping_stdout
            session.checkpoint.envelope_index = before.index
            session.checkpoint.normalizer_state = before.state
            session.checkpoint.event_cursor = {envelope_index = before.index + 1, events_committed = offset + #batch}
        end
        local committed, commit_error = M.commit(io, session, batch)
        if not committed then return false, commit_error end
        if final then break end
        offset = offset + #batch
        step(io, "partial_commit")
    end
    session.last_sequence[message.stream] = message.sequence
    step(io, "committed")
    if detected > 0 then step(io, "permission_intended") end
    io.send(sender, placement_protocol.TOPIC_ACK, {generation = session.epoch, consumed_through = acknowledged_through(session, message.sequence)})
    step(io, "acknowledged")
    return true, nil
end
type ApprovalState = "pending" | "decided" | "expired" | "withdrawn"
-- Wakeup hints: a durable subscription to the thread's approval
-- transitions whose pages are only reasons to read the approval owner.
-- The projected decision never authorizes consumption or a write, bounded
-- polling stays the fallback through every failure here, and a page is
-- acknowledged only after its hints were processed, which certifies
-- nothing about consumption or child input.
function M.on_exit(io: IO, session: Session, sender: string, message: placement_protocol.Exit)
    if not from_runner(session, sender, message.generation) then return end
    session.exit = {code = message.code, signal = message.signal, uncertain = message.uncertain, stopped = message.stopped == true}
end
function M.drained(session: Session): boolean
    return session.eof.stdout and session.eof.stderr
end
local function input_record(session: Session, phase: string, extra: {[string]: unknown}): {[string]: unknown}
    local payload: {[string]: unknown} = {attempt_id = session.plan.request.attempt_id, attachment_generation = session.epoch, phase = phase}
    for key, value in pairs(extra) do payload[key] = value end
    return {source = "bee", body = {type = "extension", event_key = "input:" .. session.plan.request.attempt_id .. ":" .. tostring(session.epoch) .. ":" .. phase,
        data = {type = "extension", event_name = "bee.carrier.input", event_revision = "1", payload_json = json.encode(payload)}}}
end
-- stop_session: the fallback end of a settled session, a cooperative stop
-- through placement, which keeps signal and cleanup authority.
function M.stop_session(io: IO, session: Session): (string, string?)
    if session.exit or not session.runner then return "none", nil end
    local stop_target = M.placement_target(session.plan, "stop")
    if not stop_target then return "none", "selected placement binds no stop" end
    local _, stop_error = must(io, stop_target, {attempt_id = session.plan.request.attempt_id, mode = "cooperative"})
    if stop_error then return "none", stop_error end
    return "stopping", nil
end
local function evidence_of(session: Session, drain_elapsed: boolean): settle.Evidence
    return {terminal = session.terminal, stream_ended = session.stream_ended, exit = session.exit, drained = M.drained(session) or drain_elapsed,
        exit_codes_trustworthy = session.plan.exit_codes_trustworthy}
end
-- ready_to_settle: the turn's outcome is decidable and no write is still
-- awaiting its answer, so a declared session end may run before the
-- settlement records end the attempt.
function M.ready_to_settle(session: Session, drain_elapsed: boolean): boolean
    if session.settled then return false end
    local decided = settle.decide(evidence_of(session, drain_elapsed))
    if not decided then return false end
    if #session.checkpoint.pending_writes > 0 and not drain_elapsed then return false end
    return true
end
-- end_session: a turn whose outcome is decided while the child still runs
-- ends the way the driver declared. A session that ends when stdin closes
-- has the closure committed to the checkpoint first, so a recovered
-- carrier never writes to it again, then placement closes stdin and the
-- outcome is on record; the caller awaits the exit within the policy
-- grace, and the cooperative stop remains the fallback. Every exchange is
-- closed by then, so no response is owed when stdin closes. Records are
-- committed only while the attempt is still open on the thread; a resumed
-- carrier finding a settled attempt ends the session without them.
-- Returns "closed", "stopping" or "none".
function M.end_session(io: IO, session: Session, record: boolean): (string, string?)
    if session.exit or not session.runner then return "none", nil end
    if session.plan.launch.session_end == "stdin_close" then
        if record and not session.checkpoint.input_closed then
            session.checkpoint.input_closed = true
            local intended, intent_error = M.commit(io, session, {input_record(session, "close_intended", {})})
            if not intended then return "none", intent_error end
        end
        -- A refusal (the attempt already gone, no runner) is a closure
        -- that did not happen, on record with its reason; the stop path
        -- then settles what remains.
        local close_target = session.plan.placement_binding.methods.close_stdin
        if not close_target then return "none", "selected placement cannot close stdin" end
        local raw, call_error = io.call(close_target, {attempt_id = session.plan.request.attempt_id})
        local reply, reply_error = reply_of(raw, call_error)
        if not reply then return "none", reply_error end
        local closed = false
        local reason = "stdin could not be closed"
        if reply.ok then
            local answer, answer_error = stdin_closure(reply.value, session.plan.request.attempt_id)
            if not answer then return "none", "placement returned malformed close_stdin data: " .. tostring(answer_error) end
            closed = answer.closed
            if answer.reason then reason = answer.reason end
        else
            local fault = reply.error or {code = "INTERNAL", message = "close_stdin failed"}
            reason = fault.code .. ": " .. fault.message
        end
        if closed then
            if record then
                local recorded, record_error = M.commit(io, session, {input_record(session, "closed", {})})
                if not recorded then return "none", record_error end
            end
            return "closed", nil
        end
        if record then
            local recorded, record_error = M.commit(io, session, {input_record(session, "close_uncertain", {reason = reason})})
            if not recorded then return "none", record_error end
        end
    end
    return M.stop_session(io, session)
end
-- close: record the placement's final states as observations once the
-- attempt is settled; cleanup runs when the placement can prove its scope.
function M.close(io: IO, session: Session): (placement_types.Attempt?, string?)
    local request = session.plan.request
    -- Intake ends in order: seal, drain what was accepted within the host's
    -- drain budget, reject explicitly what is left, then revoke.
    local binding_id = session.checkpoint.gateway_binding
    if binding_id and session.plan.gateway and #session.plan.gateway.hooks > 0 then
        io.call(M.GATEWAY .. ":seal", {binding_id = binding_id})
        local deadline = io.now_ms() + session.plan.policy.drain_ms
        local was_settled = session.settled
        session.settled = nil
        while io.now_ms() < deadline do
            local drained = M.drain_hooks(io, session)
            if drained == 0 then break end
        end
        session.settled = was_settled
        io.call(M.GATEWAY .. ":hook_reject", {binding_id = binding_id, carrier_epoch = session.epoch, reason = "attempt settled"})
    end
    gateway_revoke(io, binding_id)
    local status_target = M.placement_target(session.plan, "status")
    if not status_target then return nil, "selected placement binds no status" end
    local status_value, status_error = must(io, status_target, {attempt_id = request.attempt_id})
    if status_error then return nil, status_error end
    local status, status_decode_error = placement_decode.status(status_value)
    if not status then return nil, "placement status is malformed: " .. tostring(status_decode_error) end
    local attempt = status.attempt
    if attempt.execution_state == "exited" and attempt.cleanup_state == "pending" then
        local cleanup_target = M.placement_target(session.plan, "cleanup")
        if not cleanup_target then return nil, "selected placement binds no cleanup" end
        local cleaned, cleanup_error = io.call(cleanup_target, {attempt_id = request.attempt_id})
        local reply, reply_error = reply_of(cleaned, cleanup_error)
        if not reply then return nil, "placement cleanup reply is malformed: " .. tostring(reply_error) end
        if reply.ok == true then
            local cleaned_attempt, cleaned_error = placement_decode.attempt(reply.value)
            if not cleaned_attempt then return nil, "placement cleanup returned an invalid attempt: " .. tostring(cleaned_error) end
            attempt = cleaned_attempt
        else
            return nil, "placement cleanup refused: " .. reply.error.code .. ": " .. reply.error.message
        end
    end
    return attempt, nil
end
local function control_record(session: Session, write_id: string, phase: string, extra: {[string]: unknown}): {[string]: unknown}
    local payload: {[string]: unknown} = {write_id = write_id, attempt_id = session.plan.request.attempt_id, turn_id = session.turn_id, attachment_generation = session.epoch, phase = phase}
    for key, value in pairs(extra) do payload[key] = value end
    return {source = "bee", body = {type = "extension", event_key = "write:" .. write_id .. ":" .. phase, data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1", payload_json = json.encode(payload)}}}
end
local function forget_write(session: Session, write_id: string)
    local kept: {checkpoint.PendingWrite} = {}
    for _, pending in ipairs(session.checkpoint.pending_writes) do
        if pending.write_id ~= write_id then kept[#kept + 1] = pending end
    end
    session.checkpoint.pending_writes = kept
end
-- write: intent is committed with the write held in the checkpoint before
-- any dispatch; acceptance or uncertainty is committed after. A write is
-- refused once the runner is not bound or the intent cannot be committed,
-- so a fenced carrier never dispatches.
function M.write(io: IO, session: Session, write_id: string, data: string): (boolean, string?)
    if not session.runner then return false, "no runner is bound" end
    if session.plan.launch.stdin_eof == true then
        -- The launch closed stdin after its initial input; a later write is
        -- refused on record rather than dispatched or dropped silently.
        local digest = digest_of(data) or ""
        return M.commit(io, session, {control_record(session, write_id, "refused", {input_digest = digest, reason = "stdin closed after the initial input"})})
    end
    if session.checkpoint.input_closed then
        local digest = digest_of(data) or ""
        return M.commit(io, session, {control_record(session, write_id, "refused", {input_digest = digest, reason = "stdin closed after settlement"})})
    end
    if #data > checkpoint.MAX_PENDING_WRITE_BYTES then return false, "write exceeds " .. tostring(checkpoint.MAX_PENDING_WRITE_BYTES) .. " bytes" end
    if #session.checkpoint.pending_writes >= checkpoint.MAX_PENDING_WRITES then return false, "too many writes await acknowledgment" end
    local digest, digest_error = digest_of(data)
    if not digest then return false, digest_error end
    local pending: checkpoint.PendingWrite = {write_id = write_id, input_digest = digest, data = data, dispatched = false}
    session.checkpoint.pending_writes[#session.checkpoint.pending_writes + 1] = pending
    local intended, intended_error = M.commit(io, session, {control_record(session, write_id, "intended", {input_digest = digest})})
    if not intended then
        forget_write(session, write_id)
        return false, intended_error
    end
    step(io, "write_intended")
    local runner = session.runner
    if not runner then return false, "no runner is bound" end
    io.send(runner, placement_protocol.TOPIC_INPUT, {write_id = write_id, generation = session.epoch, data = data})
    pending.dispatched = true
    step(io, "write_dispatched")
    return true, nil
end
local function pending_write(session: Session, write_id: string): checkpoint.PendingWrite?
    for _, pending in ipairs(session.checkpoint.pending_writes) do
        if pending.write_id == write_id then return pending end
    end
    return nil
end
-- One record per write and phase, with deterministic content: an accepted
-- write carries no reason, an uncertain one carries why.
local function settle_write(io: IO, session: Session, write_id: string, phase: string, reason: string?): (boolean, string?)
    forget_write(session, write_id)
    local extra: {[string]: unknown} = {}
    if phase == "uncertain" then extra.reason = reason end
    local committed, commit_error = M.commit(io, session, {control_record(session, write_id, phase, extra)})
    if not committed then return false, commit_error end
    step(io, "write_settled")
    return true, nil
end
function M.on_write_ack(io: IO, session: Session, sender: string, message: placement_protocol.InputAck): (boolean, string?)
    if not from_runner(session, sender, message.generation) then return true, nil end
    if not pending_write(session, message.write_id) then return true, nil end
    if message.accepted then
        local accepted, accept_error = inbox.accept_write(inbox_context(), io, session, message.write_id)
        if not accepted then return false, accept_error end
    end
    local phase = message.accepted and "accepted" or "uncertain"
    return settle_write(io, session, message.write_id, phase, message.reason)
end
-- A resuming carrier asks the runner about every pending write; an answer
-- of accepted is recorded, an unknown write is dispatched for the first
-- time, and no answer at all leaves it uncertain.
function M.reconcile_writes(io: IO, session: Session): (boolean, string?)
    if #session.checkpoint.pending_writes == 0 then return true, nil end
    local runner = session.runner
    if not runner then
        for _, pending in ipairs(session.checkpoint.pending_writes) do
            local settled, err = settle_write(io, session, pending.write_id, "uncertain", "no runner survived to answer")
            if not settled then return false, err end
        end
        return true, nil
    end
    for _, pending in ipairs(session.checkpoint.pending_writes) do
        io.send(runner, placement_protocol.TOPIC_CONTROL, {command = "write_status", write_id = pending.write_id})
    end
    return true, nil
end
function M.on_write_status(io: IO, session: Session, sender: string, message: placement_protocol.WriteStatus): (boolean, string?)
    if not from_runner(session, sender, message.generation) then return true, nil end
    local found = pending_write(session, message.write_id)
    if not found then return true, nil end
    if message.status == "accepted" then
        local accepted, accept_error = inbox.accept_write(inbox_context(), io, session, message.write_id)
        if not accepted then return false, accept_error end
        return settle_write(io, session, message.write_id, "accepted", nil)
    end
    if found.dispatched then return true, nil end
    local runner = session.runner
    if not runner then return false, "no runner is bound" end
    io.send(runner, placement_protocol.TOPIC_INPUT, {write_id = found.write_id, generation = session.epoch, data = found.data})
    found.dispatched = true
    return true, nil
end
function M.advance_permissions(io: IO, session: Session, poll: boolean): (boolean, string?)
    return permission_exchange.advance(permission_context(), io, session, poll)
end
function M.close_exchanges(io: IO, session: Session, drain_elapsed: boolean): (boolean, string?)
    return permission_exchange.close_exchanges(permission_context(), io, session, drain_elapsed)
end
function M.finish_push_turn(io: IO, session: Session): (boolean, string?)
    return permission_exchange.finish_push_turn(permission_context(), io, session)
end

function M.settle(io: IO, session: Session, drain_elapsed: boolean): (settle.Settlement?, string?)
    if session.settled then return session.settled, nil end
    local decided = settle.decide(evidence_of(session, drain_elapsed))
    if not decided then return nil, nil end
    -- Settling while the streams are still open, whether the carrier's own
    -- deadline won or a terminal envelope arrived first, is incomplete
    -- output; elapsed time never implies completeness.
    if session.output == "open" then session.output = "incomplete" end
    local reason = decided.reason
    if session.output ~= "complete" then
        reason = reason .. "; output " .. session.output .. ", so the ended streams do not prove complete output"
    end
    local decision: settle.Settlement = {outcome = decided.outcome, answer = decided.answer, resume_ref = decided.resume_ref, reason = reason, exit_reconciled = decided.exit_reconciled}
    local closed_all, close_error = M.close_exchanges(io, session, drain_elapsed)
    if close_error then return nil, close_error end
    if not closed_all then return nil, nil end
    -- What the child reported before its end is committed before the turn
    -- ends; anything queued after this is rejected at close.
    local _, hooks_error = M.drain_hooks(io, session)
    if hooks_error then return nil, hooks_error end
    local request = session.plan.request
    local fault: {code: string, message: string, retryable: boolean}? = nil
    if session.terminal and session.terminal.error then fault = session.terminal.error end
    if decision.outcome ~= "succeeded" and not fault then fault = {code = decision.outcome, message = decision.reason, retryable = false} end
    step(io, "terminal_received")
    -- The output state is recorded before the turn ends, once per carrier
    -- generation since each observed its own stretch: complete only when
    -- both streams ended on their own; anything else is not complete output.
    local state_record: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = "output:" .. request.attempt_id .. ":" .. tostring(session.epoch),
        data = {type = "extension", event_name = "bee.carrier.output", event_revision = "1", payload_json = json.encode({attempt_id = request.attempt_id, state = session.output, attachment_generation = session.epoch})}}}
    if session.turn_open then state_record.turn_id = session.turn_id end
    local state_committed, state_error = M.commit(io, session, {state_record})
    if not state_committed then return nil, state_error end
    if session.turn_open then
        local _, end_error = thread_call(io, request, "end_turn", {action_id = request.action_id, attempt_id = request.attempt_id, turn_id = session.turn_id, carrier_epoch = session.epoch,
            turn_end = {outcome = decision.outcome, answer_message_ids = {}, evidence_refs = {}, usage = session.terminal and session.terminal.usage or nil, error = fault}})
        if end_error then return nil, end_error end
        session.turn_open = false
    end
    step(io, "turn_ended")
    local _, receipt_error = thread_call(io, request, "receipt", {action_id = request.action_id, attempt_id = request.attempt_id, carrier_epoch = session.epoch,
        receipt = {scope = "attempt", outcome = decision.outcome, evidence_refs = {}, error = fault}})
    if receipt_error then return nil, receipt_error end
    session.settled = decision
    return decision, nil
end
-- What this carrier can promise; the resource mode is the placement's.
function M.capabilities(): {[string]: unknown}
    return {max_frame_bytes = M.MAX_FRAME_BYTES, max_records_per_commit = M.MAX_RECORDS_PER_COMMIT, max_checkpoint_bytes = 65536,
        max_pending_writes = checkpoint.MAX_PENDING_WRITES, max_pending_write_bytes = checkpoint.MAX_PENDING_WRITE_BYTES,
        max_permissions = checkpoint.MAX_PERMISSIONS, permission_exchange = "host_policy_with_acceptance_record",
        takeover = "claim", resource_authority = "host_configured", delegated_resource_grants = false, credential_broker = false}
end
inbox_context_value = {threads = M.THREADS, delivery = M.DELIVERY, must = must, commit = M.commit, step = step,
    thread_call = thread_call, write = M.write}
permission_context_value = {approvals = M.APPROVALS, max_consume_attempts = permission_exchange.MAX_CONSUME_ATTEMPTS, commit = M.commit, must = must, step = step,
    digest_of = digest_of, plan = M.plan, placement_target = M.placement_target, write = M.write, settle_write = settle_write,
    thread_call = thread_call, drain_hooks = M.drain_hooks}
return M
