-- MIT. The host-facing driver library. A host names a driver by its id and
-- gets the options a person can set, the launch the driver prepares for one
-- placement, and a reader that folds the CLI's output into records. Bindings,
-- descriptors and codecs stay behind this surface.
local registry = require("registry")
local contract = require("contract")
local bounds = require("bounds")
local resolver = require("resolver")
local profile_codec = require("profile")
local descriptor = require("descriptor")
local effective = require("effective")
local codec_registry = require("codec_registry")
local configuration = require("configuration")
local stream_json = require("stream_json")
local credential_format = require("credential_format")
local observation = require("observation")
local driver_types = require("driver_types")
local placements = require("placements")
local configuration_types = require("configuration_types")
local record_types = require("record_types")
local composition = require("composition")
local hash = require("hash")

type Object = {[string]: unknown}
type Placement = placements.Placement
-- The host's MCP and hook endpoint for one run.
type Gateway = configuration_types.GatewayInput
-- A file to write under the CLI home: secret_fields name environment values
-- the host injects at JSON paths, composition a file it merges onto.
type DeliveredFile = configuration_types.Configuration
type Observation = record_types.Observation
type Terminal = driver_types.Terminal
type Option = {name: string, label: string, description: string, section: string, group: string, order: number,
    type: string, values: {unknown}?, schema: Object?, default: unknown, profiles: {string}?}
type Profile = {id: string, mode: string}
type Initializer = {path: string, content: string}
type CredentialFile = {path: string, content_format: "json" | "opaque", write_back: boolean, initialize: {Initializer}}
type Credentials = {files: {CredentialFile}, variables: {string}}
-- unattended: the option values the CLI runs with when no person answers its
-- prompts, absent when the driver declares no unattended mode.
-- endpoints: the protocols of host-selected endpoints the CLI can reach.
type Driver = {id: string, title: string, executable: string, default_profile: string, profiles: {Profile}, options: {Option},
    capabilities: {string}, unattended: Object?, credentials: Credentials, endpoints: {string}}
-- Endpoint: where the CLI sends model traffic instead of its vendor's default,
-- in one of the protocols the driver lists; its key reaches the CLI as a
-- credential variable.
type Endpoint = {protocol: string, base_url: string, model: string?}
type LaunchRequest = {brief: string, placement: Placement, home: string, profile_id: string?, resume_ref: string?,
    options: Object?, unattended: boolean?, gateway: Gateway?, instructions: string?, endpoint: Endpoint?}
type Launch = {executable: string, argv: {string}, stdin: string?, stdin_eof: boolean?, environment: {[string]: string},
    files: {DeliveredFile}, readiness: string}
type Problem = {index: integer, message: string, sample: string}
type Step = {observations: {Observation}, terminal: Terminal?, problems: {Problem}}
type Reader = {feed: (Reader, string) -> (Step?, error?), finish: (Reader) -> (Step?, error?)}
-- configure_target: the binding's configure method, which the configure
-- function validates under its own authority when it renders.
type Selected = {binding_ref: string, driver_id: string, profiles_ref: string?, credential_format_ref: string,
    configure_target: string, descriptor: descriptor.Descriptor, descriptor_ref: string}

local M = {}

local function fail(kind: string, message: string): error
    return errors.new({kind = kind, message = message})
end

local function selected_in(pinned: registry.Snapshot, ref: string): (Selected?, error?)
    local binding, binding_error = resolver.entry(pinned, ref)
    if binding_error then return nil, fail(errors.INTERNAL, binding_error) end
    local meta = binding and bounds.object(binding.meta)
    local driver_id = meta and bounds.id(meta.driver_id)
    local descriptor_ref = meta and bounds.id(meta.descriptor_ref)
    local credential_format_ref = meta and bounds.id(meta.credential_format_ref)
    if not binding or binding.kind ~= "contract.binding" or not meta or meta.type ~= "harness.driver" or not driver_id or not descriptor_ref or not credential_format_ref then
        return nil, fail(errors.INTERNAL, "activated binding " .. ref .. " is not a declarative driver")
    end
    local configure_target: string? = nil
    for _, raw in ipairs(bounds.array((bounds.object(binding.data) or {}).contracts, 8) or {}) do
        local declared = bounds.object(raw) or {}
        if declared.contract == "bee.drivers:driver" then configure_target = bounds.id((bounds.object(declared.methods) or {}).configure) end
    end
    if not configure_target then return nil, fail(errors.INTERNAL, "activated binding " .. ref .. " binds no configure method") end
    local loaded, load_error = descriptor.load_from(pinned, descriptor_ref)
    if not loaded then return nil, fail(errors.INTERNAL, ref .. " descriptor: " .. tostring(load_error)) end
    return {binding_ref = ref, driver_id = driver_id, profiles_ref = bounds.id(meta.profiles_ref), credential_format_ref = credential_format_ref,
        configure_target = configure_target, descriptor = loaded, descriptor_ref = descriptor_ref}, nil
end

-- index maps each activated driver id to its binding. Two activated
-- bindings declaring one driver id make the id ambiguous, so it is refused.
local function index(pinned: registry.Snapshot): ({[string]: string}?, error?)
    local active, active_error = resolver.active(pinned)
    if not active then return nil, fail(errors.INTERNAL, tostring(active_error)) end
    local by_id: {[string]: string} = {}
    for ref in pairs(active) do
        local binding, binding_error = resolver.entry(pinned, ref)
        if binding_error then return nil, fail(errors.INTERNAL, binding_error) end
        local meta = binding and bounds.object(binding.meta)
        local driver_id = meta and bounds.id(meta.driver_id)
        if not driver_id then return nil, fail(errors.INTERNAL, "activated binding " .. ref .. " declares no driver_id") end
        if by_id[driver_id] then
            return nil, fail(errors.CONFLICT, "activated bindings " .. by_id[driver_id] .. " and " .. ref .. " both declare driver " .. driver_id)
        end
        by_id[driver_id] = ref
    end
    return by_id, nil
end

local function find(pinned: registry.Snapshot, driver_id: string): (Selected?, error?)
    local by_id, index_error = index(pinned)
    if not by_id then return nil, index_error end
    local ref = by_id[driver_id]
    if not ref then return nil, fail(errors.NOT_FOUND, "driver " .. driver_id .. " is not activated") end
    return selected_in(pinned, ref)
end

local function snapshot(): (registry.Snapshot?, error?)
    local pinned, pin_error = registry.snapshot()
    if not pinned then return nil, fail(errors.UNAVAILABLE, "registry snapshot: " .. tostring(pin_error)) end
    return pinned, nil
end

-- provider_field returns the declaration of an option a host may set: a
-- descriptor field with a provider path. Fields without one are protocol
-- fields the library sets from its own request (resume_ref, gateway tools).
local function provider_field(selected: Selected, name: string): Object?
    local field = bounds.object((bounds.object(selected.descriptor.options.fields) or {})[name])
    if not field or field.path == nil then return nil end
    return field
end

local function options_of(selected: Selected): {Option}
    local result: {Option} = {}
    for name in pairs(bounds.object(selected.descriptor.options.fields) or {}) do
        local field = provider_field(selected, name)
        if field then
            local spec = descriptor.runtime_spec(field)
            result[#result + 1] = {name = name, label = bounds.text(field.label, 256) or name, description = bounds.text(field.description, 1024) or "",
                section = bounds.id(field.section) or "advanced", group = bounds.text(field.group, 128) or "", order = type(field.order) == "number" and field.order or 0,
                type = tostring(spec.type), values = bounds.array(spec.values, 64), schema = bounds.object(spec.schema), default = field.default,
                profiles = bounds.ids(spec.profiles, true)}
        end
    end
    table.sort(result, function(a: Option, b: Option): boolean
        if a.section ~= b.section then return a.section < b.section end
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)
    return result
end

-- capabilities_of names every capability the driver's option values can
-- take; a placement allows a subset of them.
local function capabilities_of(selected: Selected): {string}
    local seen: {[string]: boolean} = {}
    for _, raw in pairs(bounds.object(selected.descriptor.options.fields) or {}) do
        local field = bounds.object(raw) or {}
        local declared = bounds.ids(field.capabilities, true)
        if declared then
            for _, capability in ipairs(declared) do seen[capability] = true end
        else
            for _, rights in pairs(bounds.object(field.capabilities) or {}) do
                for _, capability in ipairs(bounds.ids(rights, true) or {}) do seen[capability] = true end
            end
        end
    end
    local result: {string} = {}
    for capability in pairs(seen) do result[#result + 1] = capability end
    table.sort(result)
    return result
end

-- credentials_of names where a credential reaches the CLI, as the binding's
-- credential format declares it: the variables an API key or token goes to,
-- and the login files its home keeps with the files each one initializes.
local function credentials_of(pinned: registry.Snapshot, selected: Selected): (Credentials?, error?)
    local entry, entry_error = resolver.entry(pinned, selected.credential_format_ref)
    if entry_error then return nil, fail(errors.INTERNAL, selected.credential_format_ref .. ": " .. tostring(entry_error)) end
    if not entry then return nil, fail(errors.INTERNAL, selected.credential_format_ref .. " is not readable") end
    local decoded, decode_error = credential_format.decode(entry.data)
    if not decoded then return nil, fail(errors.INTERNAL, selected.credential_format_ref .. ": " .. tostring(decode_error)) end
    local files: {CredentialFile} = {}
    if decoded.file then
        local write_back = false
        for _, raw in ipairs(bounds.array(selected.descriptor.provider_home.files, 16) or {}) do
            local file = bounds.object(raw) or {}
            if file.kind == "login" and file.path == decoded.file.path then write_back = file.write_back == true end
        end
        local initialize: {Initializer} = {}
        for _, item in ipairs(decoded.file.initialize) do initialize[#initialize + 1] = {path = item.path, content = item.content} end
        files[1] = {path = decoded.file.path, content_format = decoded.file.content_format, write_back = write_back, initialize = initialize}
    end
    local variables: {string} = {}
    for _, name in ipairs(decoded.environments) do variables[#variables + 1] = name end
    return {files = files, variables = variables}, nil
end

local function driver_of(pinned: registry.Snapshot, selected: Selected): (Driver?, error?)
    local credentials, credentials_error = credentials_of(pinned, selected)
    if not credentials then return nil, credentials_error end
    local result: Driver = {id = selected.driver_id, title = selected.driver_id, executable = selected.descriptor.executable,
        default_profile = "", profiles = {}, options = options_of(selected), capabilities = capabilities_of(selected),
        unattended = bounds.object(selected.descriptor.options.unattended),
        credentials = credentials, endpoints = {}}
    for _, mapping in ipairs(selected.descriptor.endpoints) do result.endpoints[#result.endpoints + 1] = mapping.protocol end
    if selected.profiles_ref then
        local entry, entry_error = resolver.entry(pinned, selected.profiles_ref)
        if entry_error then return nil, fail(errors.INTERNAL, entry_error) end
        local data = entry and bounds.object(entry.data)
        local decoded, decode_error = profile_codec.decode(data and data.driver)
        if not decoded then return nil, fail(errors.INTERNAL, selected.binding_ref .. " profiles: " .. tostring(decode_error)) end
        result.title = decoded.title
        result.default_profile = decoded.default_profile
        for _, item in ipairs(decoded.profiles) do result.profiles[#result.profiles + 1] = {id = item.id, mode = item.mode} end
    end
    return result, nil
end

-- list returns the activated drivers, ordered by id.
function M.list(): ({Driver}?, error?)
    local pinned, pin_error = snapshot()
    if not pinned then return nil, pin_error end
    local by_id, index_error = index(pinned)
    if not by_id then return nil, index_error end
    local refs: {{id: string, ref: string}} = {}
    for id, ref in pairs(by_id) do refs[#refs + 1] = {id = id, ref = ref} end
    table.sort(refs, function(a: {id: string, ref: string}, b: {id: string, ref: string}): boolean return a.id < b.id end)
    local result: {Driver} = {}
    for _, item in ipairs(refs) do
        local selected, selected_error = selected_in(pinned, item.ref)
        if not selected then return nil, selected_error end
        local driver, driver_error = driver_of(pinned, selected)
        if not driver then return nil, driver_error end
        result[#result + 1] = driver
    end
    return result, nil
end

-- get returns one activated driver.
function M.get(driver_id: string): (Driver?, error?)
    local pinned, pin_error = snapshot()
    if not pinned then return nil, pin_error end
    local selected, find_error = find(pinned, driver_id)
    if not selected then return nil, find_error end
    return driver_of(pinned, selected)
end

-- launch returns what the host runs for one turn: the command, the
-- environment and the files to write under the placement's home. Option
-- values, the unattended preset and MCP gateway configuration are all
-- rendered by the driver; the placement bounds what they may allow.
M.ENDPOINT_PROVIDER_REF = "bee.drivers:endpoint"

-- Endpoint values a mapping reads: base_url, model, and plain_http, set when
-- the host chose a plain http base URL.
type Reach = {mapping: descriptor.EndpointMapping, values: {[string]: unknown}}

local function reach(selected: Selected, value: Endpoint?): (Reach?, error?)
    if value == nil then return nil, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"protocol", "base_url", "model"}) then return nil, fail(errors.INVALID, "endpoint must be {protocol, base_url, model?}") end
    local protocol = bounds.id(raw.protocol)
    local mapping: descriptor.EndpointMapping? = nil
    for _, candidate in ipairs(selected.descriptor.endpoints) do
        if candidate.protocol == protocol then mapping = candidate end
    end
    if not mapping then return nil, fail(errors.INVALID, selected.driver_id .. " cannot reach a " .. tostring(raw.protocol) .. " endpoint") end
    local base_url = bounds.text(raw.base_url, configuration.MAX_ENDPOINT_BYTES)
    local scheme = base_url and base_url:match("^(https?)://[^/?#%s]+[^?#%s]*$")
    if not base_url or not scheme then return nil, fail(errors.INVALID, "endpoint base_url must be an http(s) URL with a host and no query") end
    local model: string? = nil
    if raw.model ~= nil then
        model = bounds.id(raw.model)
        if not model then return nil, fail(errors.INVALID, "endpoint model must be a model identifier") end
    end
    local values: {[string]: unknown} = {base_url = base_url, model = model, plain_http = scheme == "http"}
    for _, field in ipairs(mapping.requires) do
        if values[field] == nil then return nil, fail(errors.INVALID, selected.driver_id .. " needs the endpoint's " .. field) end
    end
    return {mapping = mapping, values = values}, nil
end

-- endpoint_provider builds the provider entry a mapping hands the driver's
-- configure method.
local function endpoint_provider(target: Reach): Object?
    local declared = target.mapping.provider
    if not declared then return nil end
    local data: Object = {}
    for name, value in pairs(declared.data) do data[name] = value end
    for name, field in pairs(declared.fields) do
        local value = target.values[field]
        if value ~= nil and value ~= false then data[name] = value end
    end
    return {kind = "registry.entry", meta = {type = declared.type}, data = data}
end

function M.launch(driver_id: string, request: LaunchRequest): (Launch?, error?)
    local brief = bounds.text(request.brief, bounds.MAX_TEXT_BYTES)
    if not brief then return nil, fail(errors.INVALID, "brief must be bounded text") end
    local home = bounds.text(request.home, 4096)
    if not home or home:sub(1, 1) ~= "/" then return nil, fail(errors.INVALID, "home must be an absolute path") end
    local placed, placement_error = placements.decode(request.placement)
    if placement_error then return nil, fail(errors.INVALID, placement_error) end
    if not placed then return nil, fail(errors.INVALID, "placement is required") end
    local pinned, pin_error = snapshot()
    if not pinned then return nil, pin_error end
    local selected, find_error = find(pinned, driver_id)
    if not selected then return nil, find_error end
    local target, endpoint_error = reach(selected, request.endpoint)
    if endpoint_error then return nil, endpoint_error end

    local values: Object = {}
    for name, value in pairs(request.options or {}) do
        if not provider_field(selected, name) then return nil, fail(errors.INVALID, "option " .. name .. " is not a " .. driver_id .. " option") end
        values[name] = value
    end
    -- Instructions arrive as the request field or the instructions option;
    -- the driver delivers one value through its configuration.
    local instructions = request.instructions
    if values.system_prompt_append ~= nil then
        if instructions ~= nil then return nil, fail(errors.INVALID, "give instructions once: the instructions field or the system_prompt_append option") end
        if type(values.system_prompt_append) ~= "string" then return nil, fail(errors.INVALID, "system_prompt_append must be text") end
        instructions = values.system_prompt_append
        values.system_prompt_append = nil
    end
    if request.unattended == true then
        local merged, unattended_error = effective.unattended(selected.descriptor, values)
        if not merged then return nil, fail(errors.INVALID, tostring(unattended_error)) end
        values = merged
    end

    local prepare: Object = {profile_id = request.profile_id or "batch", brief = brief, resume_ref = request.resume_ref, placement = request.placement}
    for name, value in pairs(values) do prepare[name] = value end
    if request.gateway then
        prepare.gateway_tools = request.gateway.tools
        prepare.gateway_hooks = request.gateway.hooks
    end
    local binding, open_error = contract.open(selected.binding_ref)
    if not binding then return nil, fail(errors.INTERNAL, "open " .. selected.binding_ref .. ": " .. tostring(open_error)) end
    local raw, call_error = binding:prepare(prepare)
    if call_error then return nil, fail(errors.INTERNAL, selected.binding_ref .. " prepare: " .. tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply then return nil, fail(errors.INTERNAL, selected.binding_ref .. " prepare returned no reply") end
    if reply.ok ~= true then return nil, fail(errors.INVALID, tostring(reply.error or "launch refused")) end
    local prepared = bounds.object(reply.launch)
    if not prepared then return nil, fail(errors.INTERNAL, selected.binding_ref .. " prepare returned no launch") end

    local context = request.profile_id == "window" and "window" or request.resume_ref ~= nil and "resume" or "first_turn"
    local provider = target and endpoint_provider(target) or nil
    local delivery, delivery_error = configuration.call(selected.binding_ref, selected.configure_target, {fixture = false, home_directory = home,
        placement = request.placement, option_values = values, context = context, gateway = request.gateway, instructions = instructions,
        provider_ref = provider and M.ENDPOINT_PROVIDER_REF or nil, provider = provider})
    if not delivery then return nil, delivery_error end
    -- The launch home starts empty, so a file composed onto a base the home
    -- would keep composes onto an empty document.
    local files: {DeliveredFile} = {}
    for _, file in ipairs(delivery.files) do
        if file.composition then
            local content, compose_error = composition.compose(file.composition, file.content, "")
            if not content then return nil, fail(errors.INTERNAL, file.path .. ": " .. tostring(compose_error)) end
            local digest, digest_error = hash.sha256(content)
            if not digest then return nil, fail(errors.INTERNAL, file.path .. " digest: " .. tostring(digest_error)) end
            files[#files + 1] = {secret_fields = file.secret_fields, revision = file.revision, path = file.path, content = content,
                digest = digest, provider_ref = file.provider_ref}
        else
            files[#files + 1] = file
        end
    end

    local argv: {string} = {}
    for _, argument in ipairs(delivery.arguments) do argv[#argv + 1] = argument end
    for _, argument in ipairs(bounds.array(prepared.argv, 512) or {}) do argv[#argv + 1] = tostring(argument) end
    local environment: {[string]: string} = {}
    for name, value in pairs(delivery.environment or {}) do environment[name] = value end
    local provider_home = selected.descriptor.provider_home
    local variable, directory = bounds.id(provider_home.variable), bounds.text(provider_home.directory, 128)
    if variable and directory then environment[variable] = home .. "/" .. directory end
    if target then
        for name, field in pairs(target.mapping.environment) do environment[name] = tostring(target.values[field]) end
    end
    for _, raw in ipairs(bounds.array(provider_home.extra_variables, 8) or {}) do
        local extra = bounds.object(raw) or {}
        local extra_variable, extra_directory = bounds.id(extra.variable), bounds.text(extra.directory, 128)
        if extra_variable and extra_directory then environment[extra_variable] = home .. "/" .. extra_directory end
    end
    if prepared.stdin ~= nil and type(prepared.stdin) ~= "string" then
        return nil, fail(errors.INTERNAL, selected.binding_ref .. " prepare returned a non-text stdin")
    end
    return {executable = tostring(prepared.executable), argv = argv, stdin = prepared.stdin :: string?,
        stdin_eof = prepared.stdin_eof == true or nil, environment = environment, files = files,
        readiness = tostring(prepared.readiness)}, nil
end

-- reader folds one CLI output stream into records: feed takes raw output
-- chunks in order, finish settles a stream that ended without a terminal
-- report. Frames that are not JSON come back as problems with their index.
function M.reader(driver_id: string, resumed: boolean?): (Reader?, error?)
    local pinned, pin_error = snapshot()
    if not pinned then return nil, pin_error end
    local selected, find_error = find(pinned, driver_id)
    if not selected then return nil, find_error end
    -- The codec is pinned for the reader's lifetime: a descriptor change
    -- applies to the next stream, never to state this one built.
    local protocol = codec_registry.resolve(selected.descriptor.codec, bounds.object(selected.descriptor.json_paths) or {})
    if not protocol then return nil, fail(errors.INTERNAL, selected.descriptor_ref .. " selects an unsupported codec " .. selected.descriptor.codec) end
    local decoder = stream_json.new(nil)
    local state = protocol.new(resumed == true)
    -- take decodes what the codec reported into typed records.
    local function take(step: Step, observations: {unknown}, terminal: unknown): error?
        for _, raw in ipairs(observations) do
            local decoded, decode_error = observation.decode(raw)
            if not decoded then return fail(errors.INTERNAL, selected.descriptor.codec .. " produced an invalid observation: " .. tostring(decode_error)) end
            step.observations[#step.observations + 1] = decoded
        end
        if terminal ~= nil then
            local decoded, decode_error = driver_types.decode_terminal(terminal)
            if not decoded then return fail(errors.INTERNAL, selected.descriptor.codec .. " produced an invalid terminal report: " .. tostring(decode_error)) end
            step.terminal = decoded
        end
        return nil
    end
    local function fold(step: Step, frame: integer, value: Object): error?
        local folded, normalize_error = protocol.normalize(state, frame, value)
        if not folded then return fail(errors.INVALID, "frame " .. tostring(frame) .. ": " .. tostring(normalize_error)) end
        return take(step, folded.observations, folded.terminal)
    end
    local reader: Reader = {
        feed = function(_self: Reader, chunk: string): (Step?, error?)
            local envelopes, problems, feed_error = stream_json.feed(decoder, chunk)
            if feed_error then return nil, fail(errors.INVALID, feed_error) end
            local step: Step = {observations = {}, problems = {}}
            for _, problem in ipairs(problems) do step.problems[#step.problems + 1] = {index = problem.index, message = problem.message, sample = problem.sample} end
            for _, envelope in ipairs(envelopes) do
                local value = bounds.object(envelope.value)
                if value then
                    local fold_error = fold(step, envelope.index, value)
                    if fold_error then return nil, fold_error end
                else
                    step.problems[#step.problems + 1] = {index = envelope.index, message = "frame is not a JSON object", sample = ""}
                end
            end
            return step, nil
        end,
        finish = function(_self: Reader): (Step?, error?)
            local step: Step = {observations = {}, problems = {}}
            local tail = stream_json.finish(decoder)
            if tail then step.problems[#step.problems + 1] = {index = tail.index, message = tail.message, sample = tail.sample} end
            local folded, finish_error = protocol.finish(state, decoder.index + 1)
            if not folded then return nil, fail(errors.INVALID, tostring(finish_error)) end
            local take_error = take(step, folded.observations, folded.terminal)
            if take_error then return nil, take_error end
            return step, nil
        end,
    }
    return reader, nil
end

return M
