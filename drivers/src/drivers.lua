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

type Object = {[string]: unknown}
type Mount = {resource: string, target: string, access: "read" | "write"}
type Placement = {kind: "native" | "container", mounts: {Mount}, network: string, allows: {string}}
type Gateway = {endpoint: string, action_id: string, tools: {string}, hooks: {string}, token_environment: string,
    hook_token_environment: string?, hook_command: string?}
type Option = {name: string, label: string, description: string, section: string, group: string, order: number,
    type: string, values: {unknown}?, schema: Object?, default: unknown, profiles: {string}?}
type Profile = {id: string, mode: string}
type Credentials = {files: {{path: string, write_back: boolean}}, variables: {string}}
type Driver = {id: string, title: string, default_profile: string, profiles: {Profile}, options: {Option},
    capabilities: {string}, unattended: boolean, credentials: Credentials}
type LaunchRequest = {brief: string, placement: Placement, home: string, profile_id: string?, resume_ref: string?,
    options: Object?, unattended: boolean?, gateway: Gateway?, instructions: string?}
type SecretField = {path: {string}, environment: string, prefix: string}
type File = {path: string, content: string, secret_fields: {SecretField}?, composition: Object?}
type Launch = {executable: string, argv: {string}, stdin: string?, stdin_eof: boolean?, environment: {[string]: string},
    files: {File}, readiness: string}
type Problem = {index: integer, message: string}
type Step = {observations: {Object}, terminal: Object?, problems: {Problem}}
type Reader = {feed: (Reader, string) -> (Step?, error?), finish: (Reader) -> (Step?, error?)}
type Selected = {binding_ref: string, driver_id: string, profiles_ref: string?, descriptor: descriptor.Descriptor, descriptor_ref: string}

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
    if not binding or binding.kind ~= "contract.binding" or not meta or meta.type ~= "harness.driver" or not driver_id or not descriptor_ref then
        return nil, fail(errors.INTERNAL, "activated binding " .. ref .. " is not a declarative driver")
    end
    local loaded, load_error = descriptor.load_from(pinned, descriptor_ref)
    if not loaded then return nil, fail(errors.INTERNAL, ref .. " descriptor: " .. tostring(load_error)) end
    return {binding_ref = ref, driver_id = driver_id, profiles_ref = bounds.id(meta.profiles_ref), descriptor = loaded, descriptor_ref = descriptor_ref}, nil
end

local function activated_refs(pinned: registry.Snapshot): ({string}?, error?)
    local active, active_error = resolver.active(pinned)
    if not active then return nil, fail(errors.INTERNAL, tostring(active_error)) end
    local refs: {string} = {}
    for ref in pairs(active) do refs[#refs + 1] = ref end
    table.sort(refs)
    return refs, nil
end

local function activated(pinned: registry.Snapshot): ({Selected}?, error?)
    local refs, refs_error = activated_refs(pinned)
    if not refs then return nil, refs_error end
    local result: {Selected} = {}
    for _, ref in ipairs(refs) do
        local selected, selected_error = selected_in(pinned, ref)
        if not selected then return nil, selected_error end
        result[#result + 1] = selected
    end
    return result, nil
end

-- find decodes only the descriptor of the binding that declares driver_id.
local function find(pinned: registry.Snapshot, driver_id: string): (Selected?, error?)
    local refs, refs_error = activated_refs(pinned)
    if not refs then return nil, refs_error end
    for _, ref in ipairs(refs) do
        local binding, binding_error = resolver.entry(pinned, ref)
        if binding_error then return nil, fail(errors.INTERNAL, binding_error) end
        local meta = binding and bounds.object(binding.meta)
        if meta and meta.driver_id == driver_id then return selected_in(pinned, ref) end
    end
    return nil, fail(errors.NOT_FOUND, "driver " .. driver_id .. " is not activated")
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

local function credentials_of(selected: Selected): Credentials
    local files: {{path: string, write_back: boolean}} = {}
    for _, raw in ipairs(bounds.array(selected.descriptor.provider_home.files, 16) or {}) do
        local file = bounds.object(raw) or {}
        local path = bounds.text(file.path, 512)
        if file.kind == "login" and path then files[#files + 1] = {path = path, write_back = file.write_back == true} end
    end
    local variables: {string} = {}
    for _, evidence in ipairs(selected.descriptor.login_evidence.any_of or {}) do
        if evidence.kind == "env_present" then
            for _, name in ipairs(evidence.names) do variables[#variables + 1] = name end
        end
    end
    return {files = files, variables = variables}
end

local function driver_of(pinned: registry.Snapshot, selected: Selected): (Driver?, error?)
    local result: Driver = {id = selected.driver_id, title = selected.driver_id, default_profile = "", profiles = {},
        options = options_of(selected), capabilities = capabilities_of(selected), unattended = bounds.object(selected.descriptor.options.unattended) ~= nil,
        credentials = credentials_of(selected)}
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
    local drivers, drivers_error = activated(pinned)
    if not drivers then return nil, drivers_error end
    local result: {Driver} = {}
    for _, selected in ipairs(drivers) do
        local driver, driver_error = driver_of(pinned, selected)
        if not driver then return nil, driver_error end
        result[#result + 1] = driver
    end
    table.sort(result, function(a: Driver, b: Driver): boolean return a.id < b.id end)
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

local function delivered_files(files: {Object}): {File}
    local result: {File} = {}
    for _, file in ipairs(files) do
        result[#result + 1] = {path = tostring(file.path), content = tostring(file.content),
            secret_fields = file.secret_fields :: {SecretField}?, composition = bounds.object(file.composition)}
    end
    return result
end

-- launch returns what the host runs for one turn: the command, the
-- environment and the files to write under the placement's home. Option
-- values, the unattended preset and MCP gateway configuration are all
-- rendered by the driver; the placement bounds what they may allow.
function M.launch(driver_id: string, request: LaunchRequest): (Launch?, error?)
    local brief = bounds.text(request.brief, bounds.MAX_TEXT_BYTES)
    if not brief then return nil, fail(errors.INVALID, "brief must be bounded text") end
    local home = bounds.text(request.home, 4096)
    if not home or home:sub(1, 1) ~= "/" then return nil, fail(errors.INVALID, "home must be an absolute path") end
    if request.placement == nil then return nil, fail(errors.INVALID, "placement is required") end
    local pinned, pin_error = snapshot()
    if not pinned then return nil, pin_error end
    local selected, find_error = find(pinned, driver_id)
    if not selected then return nil, find_error end

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

    local target, target_error = resolver.configure(pinned, selected.binding_ref)
    if not target then return nil, fail(errors.INTERNAL, tostring(target_error)) end
    local context = request.profile_id == "window" and "window" or request.resume_ref ~= nil and "resume" or "first_turn"
    local delivery, delivery_error = configuration.call(selected.binding_ref, target, {fixture = false, home_directory = home,
        placement = request.placement, option_values = values, context = context, gateway = request.gateway, instructions = instructions})
    if not delivery then return nil, fail(errors.INVALID, tostring(delivery_error)) end

    local argv: {string} = {}
    for _, argument in ipairs(delivery.arguments) do argv[#argv + 1] = argument end
    for _, argument in ipairs(bounds.array(prepared.argv, 512) or {}) do argv[#argv + 1] = tostring(argument) end
    local environment: {[string]: string} = {}
    for name, value in pairs(delivery.environment or {}) do environment[name] = value end
    local provider_home = selected.descriptor.provider_home
    local variable, directory = bounds.id(provider_home.variable), bounds.text(provider_home.directory, 128)
    if variable and directory then environment[variable] = home .. "/" .. directory end
    for _, raw in ipairs(bounds.array(provider_home.extra_variables, 8) or {}) do
        local extra = bounds.object(raw) or {}
        local extra_variable, extra_directory = bounds.id(extra.variable), bounds.text(extra.directory, 128)
        if extra_variable and extra_directory then environment[extra_variable] = home .. "/" .. extra_directory end
    end
    if prepared.stdin ~= nil and type(prepared.stdin) ~= "string" then
        return nil, fail(errors.INTERNAL, selected.binding_ref .. " prepare returned a non-text stdin")
    end
    return {executable = tostring(prepared.executable), argv = argv, stdin = prepared.stdin :: string?,
        stdin_eof = prepared.stdin_eof == true or nil, environment = environment, files = delivered_files(delivery.files),
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
    local function fold(step: Step, index: integer, value: Object): error?
        local folded, normalize_error = protocol.normalize(state, index, value)
        if not folded then return fail(errors.INVALID, "frame " .. tostring(index) .. ": " .. tostring(normalize_error)) end
        for _, observation in ipairs(folded.observations) do step.observations[#step.observations + 1] = observation end
        if folded.terminal ~= nil then step.terminal = bounds.object(folded.terminal) end
        return nil
    end
    local reader: Reader = {
        feed = function(_self: Reader, chunk: string): (Step?, error?)
            local envelopes, problems, feed_error = stream_json.feed(decoder, chunk)
            if feed_error then return nil, fail(errors.INVALID, feed_error) end
            local step: Step = {observations = {}, problems = {}}
            for _, problem in ipairs(problems) do step.problems[#step.problems + 1] = {index = problem.index, message = problem.message} end
            for _, envelope in ipairs(envelopes) do
                local value = bounds.object(envelope.value)
                if value then
                    local fold_error = fold(step, envelope.index, value)
                    if fold_error then return nil, fold_error end
                else
                    step.problems[#step.problems + 1] = {index = envelope.index, message = "frame is not a JSON object"}
                end
            end
            return step, nil
        end,
        finish = function(_self: Reader): (Step?, error?)
            local step: Step = {observations = {}, problems = {}}
            local tail = stream_json.finish(decoder)
            if tail then step.problems[#step.problems + 1] = {index = tail.index, message = tail.message} end
            local folded, finish_error = protocol.finish(state, decoder.index + 1)
            if not folded then return nil, fail(errors.INVALID, tostring(finish_error)) end
            for _, observation in ipairs(folded.observations) do step.observations[#step.observations + 1] = observation end
            if folded.terminal ~= nil then step.terminal = bounds.object(folded.terminal) end
            return step, nil
        end,
    }
    return reader, nil
end

return M
