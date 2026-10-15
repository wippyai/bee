-- MIT. Carrier plan measurement and admission.
local registry = require("registry")
local permission = require("permission")
local acceptance = require("acceptance")
local gateway_configuration = require("gateway_configuration")
local bounds = require("bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local classify = require("classify")
local policy = require("policy")
local continuation = require("continuation")
local driver_types = require("driver_types")
local placement_types = require("placement_types")
local placement_resolver = require("placement_resolver")
local placement_profiles = require("placement_profiles")
local launch_request = require("launch_request")
local configuration_protocol = require("configuration")
local driver_resolver = require("driver_resolver")
local service_reply = require("service_reply")
local carrier_types = require("carrier_types")
local descriptor = require("descriptor")
local readiness = require("readiness")
local profile_values = require("profile_values")
local effective_schema = require("effective_schema")
local M = {}
type Object = {[string]: unknown}
type Reply = service_reply.Reply
type IO = carrier_types.IO
type Request = carrier_types.Request
type Exchange = carrier_types.Exchange
type Acceptance = carrier_types.Acceptance
type Plan = carrier_types.Plan
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
local function must(io: IO, target: string, request: unknown): (unknown, string?)
    local raw, call_error = io.call(target, request)
    local reply, reply_error = reply_of(raw, call_error)
    if not reply then return nil, target .. ": " .. tostring(reply_error) end
    if reply.ok == false then return nil, target .. ": " .. reply.error.code .. ": " .. reply.error.message end
    return reply.value, nil
end
local digest_of = canonical.digest

-- measure: the binding, profile, policy and, when enabled, the adapter and
-- acceptance record, all read from one pinned registry generation.
type Measured = {generation: integer, binding: classify.Binding, profile: classify.Profile, policy: policy.Policy, placement_binding: placement_types.PlacementBinding, exchange: Exchange?, configuration: configuration_protocol.Request, gateway: placement_types.Gateway?}
-- verify_acceptance: the acceptance record a host declaration names,
-- decoded and matched against this snapshot's binding, profile, adapter
-- and proof fixture. The permission exchange stands on this record type;
-- the label names which check failed.
type DeclaredAcceptance = {adapter_ref: string, acceptance_ref: string, fixture_digest: string}
function M.verify_acceptance(pinned: registry.Snapshot, declared: DeclaredAcceptance, binding: classify.Binding, profile: classify.Profile, fixture: boolean, label: string): (Acceptance?, string?)
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
    local snapshot, snapshot_error = catalog.read(pinned, nil, request.binding_ref)
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
    local option_descriptor, _, schema_error = profile_values.schema(request.binding_ref)
    local launch_policy, policy_error = policy.decode(request.policy_ref, policy_entry, nil, request.preferences, option_descriptor, request.placement_profile_ref)
    if not launch_policy then return nil, policy_error end
    -- The policy is host-owned and decoded from this pinned snapshot. It is
    -- the source of placement selection; request fields only prove that the
    -- carrier received the same measured choice from admission.
    local placement_binding_ref = launch_policy.placement_binding
    if request.placement_profile_ref then
        if not bounds.member(request.placement_profile_ref, launch_policy.placement_profiles) then return nil, "launch policy does not admit this placement profile" end
        local selected, profile_error = placement_profiles.resolve(pinned, request.placement_profile_ref)
        if not selected then return nil, profile_error end
        local tuned, tune_error = placement_profiles.tune(selected, request.preferences and request.preferences.docker_overrides)
        if not tuned then return nil, tune_error end
        selected = tuned
        if selected.digest ~= request.placement_profile_digest then return nil, "placement profile changed since admission" end
        placement_binding_ref = selected.profile.placement_binding
    end
    local selected_placement, placement_error = placement_resolver.resolve(pinned, placement_binding_ref)
    if not selected_placement then return nil, placement_error end
    if (request.placement_binding_ref and request.placement_binding_ref ~= selected_placement.binding_id)
        or (request.placement_binding_digest and request.placement_binding_digest ~= selected_placement.binding_digest) then
        return nil, "placement binding changed since admission"
    end
    local exchange: Exchange? = nil
    local declared = launch_policy.permission_exchange
    if declared then
        if not request.workspace_id then return nil, "a permission exchange needs the request's workspace" end
        local verified, verify_error = M.verify_acceptance(pinned, declared, binding, profile, launch_policy.fixture, "permission exchange")
        if not verified then return nil, verify_error end
        local transport = "stdio"
        if not launch_policy.fixture then
            local capability, capability_error = descriptor.find_provider(pinned, binding.driver_id)
            if not capability then return nil, capability_error end
            local context = profile.mode == "window" and "window" or "first_turn"
            local answer = descriptor.permission_answer(capability, context)
            if answer.transport == "provider" then return nil, answer.reason end
            if answer.adapter_ref ~= declared.adapter_ref then return nil, "host permission adapter differs from the driver's declared transport" end
            transport = answer.transport
        end
        exchange = {transport = transport, answer_mode = launch_policy.permission_answers, adapter = verified.adapter, acceptance_ref = verified.acceptance_ref, acceptance_digest = verified.acceptance_digest,
            executable_revision = verified.executable_revision, executable_kind = verified.executable_kind, executable_digest = verified.executable_digest,
            approver_policy = declared.approver_policy, poll_ms = declared.poll_ms, ttl_ms = declared.ttl_ms}
    end
    -- The carrier carries only host-selected configuration inputs. Placement
    -- renders and freezes the driver's final delivery with its own HOME path.
    local gateway: placement_types.Gateway? = nil
    local gateway_input: configuration_protocol.GatewayInput? = nil
    local selected, selected_error = driver_resolver.profile(pinned, request.binding_ref, request.profile_id)
    if selected_error then return nil, selected_error end
    local selected_hooks = driver_resolver.select_hooks(selected, launch_policy.gateway_hooks)
    if #launch_policy.gateway_tools > 0 or #selected_hooks > 0 then
        local address, endpoint_error = gateway_configuration.endpoint()
        if not address then return nil, "gateway: " .. tostring(endpoint_error) end
        local hook_destination: string? = nil
        if #selected_hooks > 0 then hook_destination = gateway_configuration.HOOK_DESTINATION end
        gateway = {endpoint = address, tools = launch_policy.gateway_tools, destination = gateway_configuration.DESTINATION,
            hooks = selected_hooks, hook_destination = hook_destination}
        local hook_command: string? = nil
        local command_error: string? = nil
        if #selected_hooks > 0 then hook_command, command_error = gateway_configuration.hook_command(launch_policy.hook_command_ref) end
        if command_error then return nil, command_error end
        gateway_input = {hook_command = hook_command, endpoint = address, action_id = request.action_id, tools = gateway.tools, hooks = gateway.hooks,
            token_environment = gateway.destination, hook_token_environment = gateway.hook_destination}
    end
    if not launch_policy.fixture then
        local descriptor = option_descriptor
        if request.preferences and not descriptor then return nil, schema_error or "Driver option schema is unavailable" end
        if descriptor then
            local probed = readiness.probe(request.binding_ref, request.profile_id, readiness.new_cache(), request.placement_profile_ref)
            local capabilities = probed.result and probed.result.capabilities or {}
            local values: Object = {}
            if request.preferences then
                for name, value in pairs(request.preferences.options) do values[name] = value end
                if request.preferences.instructions ~= "" then values.system_prompt_append = request.preferences.instructions end
            end
            local _, invalid = effective_schema.compile(descriptor, bounds.object(policy_entry.data), capabilities, values, nil, nil, nil, request.placement_profile_ref)
            if invalid then return nil, invalid end
        end
    end
    if not binding.methods.configure then return nil, "binding " .. request.binding_ref .. " binds no configure" end
    local provider_entry: Object? = nil
    if launch_policy.provider_ref then
        provider_entry = catalog.entry(pinned, launch_policy.provider_ref)
        if not provider_entry then return nil, "provider " .. launch_policy.provider_ref .. " is not in the registry" end
    end
    local configuration: configuration_protocol.Request = {provider_ref = launch_policy.provider_ref,
        placement_profile_ref = request.placement_profile_ref, option_provenance = launch_policy.option_provenance, option_values = launch_policy.prepare_options, provider = provider_entry, instructions = launch_policy.instructions, instruction_builder = launch_policy.instruction_builder,
        gateway = gateway_input, fixture = launch_policy.fixture}
    return {generation = snapshot.generation, binding = binding, profile = profile, policy = launch_policy, placement_binding = selected_placement, exchange = exchange,
        configuration = configuration, gateway = gateway}
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
-- launch, bind executables and requirements from the host policy. A window
-- may start its agent with a prompt: the message waiting for it, which is
-- not the admitted brief.
function M.plan(io: IO, request: Request, prompt: string?): (Plan?, string?)
    local measured, measure_error = measure(request)
    if not measured then return nil, measure_error end
    local binding, profile, launch_policy, placement_binding, exchange, configuration, gateway = measured.binding, measured.profile, measured.policy, measured.placement_binding, measured.exchange, measured.configuration, measured.gateway
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
        -- A window whose previous agent began no conversation starts a new
        -- one in the same session and its home.
        if not resumed and not (profile.mode == "window" and resume_error == continuation.NO_CONVERSATION) then return nil, resume_error end
        previous_private_home = private_home
        if resumed then
            resume_ref = resumed
            local dispatch = binding.methods.dispatch
            if not dispatch then return nil, "driver has no continuation method" end
            prepare_target = dispatch
        end
    end
    local configuration_context = profile.mode == "window" and "window" or (resume_ref and "resume" or "first_turn")
    configuration.context = configuration_context
    local configuration_digest, configuration_error = configuration_protocol.digest(request.binding_ref, configuration, assert(binding.methods.configure))
    if not configuration_digest then return nil, configuration_error end
    local private_home = previous_private_home
    if private_home == nil then private_home = profile.private_home end
    if request.preferences and request.preferences.home and previous_private_home == nil then private_home = request.preferences.home == "private" end
    if placement_binding.placement_kind == "docker" then private_home = true end
    if launch_policy.provider_ref and not private_home then
        return nil, "selected provider configuration requires a private-home profile"
    end
    if not private_home and not launch_policy.allow_host_home then
        return nil, "launch policy does not authorize host HOME"
    end
    local prepare_request: {[string]: unknown} = {}
    prepare_request.placement_profile_ref = request.placement_profile_ref
    prepare_request.option_provenance = launch_policy.option_provenance
    for name, value in pairs(launch_policy.prepare_options) do prepare_request[name] = value end
    prepare_request.profile_id = request.profile_id
    prepare_request.brief = request.brief
    if prompt then
        if profile.mode ~= "window" then return nil, "only a window starts its agent with a prompt" end
        prepare_request.brief = prompt
    end
    prepare_request.resume_ref = resume_ref
    -- The host enabled an interactive permission exchange: the driver
    -- prepares the launch shape that keeps stdin open for the responses.
    if exchange and (exchange.transport == nil or exchange.transport == "stdio") then prepare_request.permission_exchange = true end
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
    local runtime_name = launch.executable
    local bound = launch_policy.executables[runtime_name]
    if bound then launch.executable = bound end
    if placement_binding.placement_kind == "docker" then
        local name = runtime_name:match("^([A-Za-z0-9_.%-]+)$")
        if not name or not name:match("^[A-Za-z0-9_.%-]+$") then return nil, "Docker executable has no runtime name" end
        launch.executable = "/usr/local/bin/" .. name
    end
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
            elseif exchange and not launch_policy.fixture then
                local fault = reply.error or {code = "UNAVAILABLE", message = "measurement failed"}
                refuse_exchange("production exchange: executable measurement: " .. fault.code .. ": " .. fault.message)
            end
        elseif exchange and not launch_policy.fixture then
            refuse_exchange("production exchange: selected placement cannot measure the executable")
        end
    elseif exchange and not launch_policy.fixture then
        refuse_exchange("production exchange: the launch policy binds no absolute executable to measure")
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
    local environment: {[string]: string} = {}
    for name, value in pairs(request.environment) do environment[name] = value end
    for name, value in pairs(launch_policy.environment) do
        -- A resumed session keeps the configuration root in which its provider
        -- recorded the conversation. Fresh sessions still inherit every
        -- host-selected override from the current profile.
        if previous_private_home ~= true or launch_policy.host_environment[name] == nil then environment[name] = value end
    end
    if placement_binding.placement_kind == "docker" then
        environment.HOME = nil
        local home = launch.provider_home
        if home then
            if home.variable then environment[home.variable] = nil end
            for _, item in ipairs(home.extra_variables or {}) do environment[item.variable] = nil end
        end
    end
    if request.working_directory then launch.working_directory_ref = request.working_directory end
    local measured_exchange: {[string]: unknown}? = nil
    if exchange then measured_exchange = {adapter = exchange.adapter.digest, acceptance = exchange.acceptance_ref, acceptance_digest = exchange.acceptance_digest} end
    local plan_digest, digest_error = digest_of({executable = measurement, policy = launch_policy.digest, binding = binding.binding_digest.entry, profile = binding.profile_digest.entry,
        placement_binding_ref = placement_binding.binding_id, placement_binding_digest = placement_binding.binding_digest, placement_methods = placement_binding.methods,
        launch = launch, session_ref = request.session_ref, previous_attempt_id = request.previous_attempt_id, reauthorize = request.reauthorize,
        environment = environment, permission = measured_exchange, configuration = configuration_digest, gateway = gateway})
    if not plan_digest then return nil, digest_error end
    local placement_request: placement_types.LaunchRequest = {
        workspace_id = request.workspace_id,
        preferences = request.preferences,
        idempotency_key = "placement:" .. request.attempt_id, owner_id = request.owner_id, owner_incarnation = request.owner_incarnation,
        action_id = request.action_id, attempt_id = request.attempt_id, binding_ref = binding.binding_id, policy_ref = launch_policy.ref, profile_id = profile.id,
        binding_digest = binding.binding_digest.entry, profile_digest = binding.profile_digest.entry, placement_profile_ref = request.placement_profile_ref, placement_profile_digest = request.placement_profile_digest, placement_binding_ref = placement_binding.binding_id, placement_binding_digest = placement_binding.binding_digest, launch = launch, configuration_context = configuration_context, configuration_digest = configuration_digest, executable = measurement, gateway = gateway, resources = request.resources,
        environment = environment, environment_refs = {}, projections = request.projections or {}, session_ref = request.session_ref, required_cleanup = launch_policy.required_cleanup,
        required_exit_observation = launch_policy.required_exit_observation, timeouts = {stop_grace_ms = launch_policy.stop_grace_ms, drain_ms = launch_policy.runner_drain_ms, retain_ms = launch_policy.retain_ms},
        options = request.options,
    }
    if not private_home then
        placement_request.environment_refs.HOME = "bee.env:machine_home"
    end
    return {request = request, binding = binding, profile = profile, launch = launch, policy = launch_policy, placement_binding = placement_binding, plan_digest = plan_digest,
        placement_request = placement_request, exit_codes_trustworthy = false, prepare_target = prepare_target, resume_ref = resume_ref, normalize_target = normalize_target, exchange = exchange, exchange_refusal = exchange_refusal, gateway = gateway}, nil
end
M.reply_of = reply_of
M.executable_capability = executable_capability
M.executable_measurement = executable_measurement
M.must = must
M.digest_of = digest_of
M.measure = measure
return M
