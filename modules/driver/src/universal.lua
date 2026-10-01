-- MIT. One external driver implementation; provider behavior is selected by
-- a strictly decoded registry descriptor.
local bounds = require("bounds")
local canonical = require("canonical")
local descriptor_reader = require("descriptor")
local configuration = require("configuration")
local types = require("types")
local locate = require("locate")
local codec_registry = require("codec_registry")
local M = {}

type Object = {[string]: unknown}
type ProtocolStep = {observations: {Object}, terminal: unknown?}
type Descriptor = descriptor_reader.Descriptor
type Request = {[string]: descriptor_reader.OptionValue?} & {profile_id: string, brief: string}
type ConfigureRequest = configuration.Request
type ConfigureRenderer = (ConfigureRequest) -> Object
type ProviderHomeFileKind = "login" | "config" | "state"
type LaunchAPI = {
    decode: (unknown) -> (Request?, string?),
    specification: (Request) -> types.Launch,
}

local function request_value(request: Request, field: string): descriptor_reader.OptionValue?
    return request[field]
end

local function rule_error(rule: Object, fallback: string): string
    return bounds.text(rule.message, 256) or fallback
end

local function apply_rules(options: Object, request: Request): string?
    local rules = options.rules
    if type(rules) ~= "table" then return nil end
    for _, raw_rule in ipairs(rules) do
        local rule = bounds.object(raw_rule) or {}
        if rule.kind == "profile_fields" and request.profile_id == rule.profile and type(rule.fields) == "table" then
            for _, raw_field in ipairs(rule.fields) do
                local field = bounds.id(raw_field)
                local value: descriptor_reader.OptionValue? = nil
                if field then value = request_value(request, field) end
                local supplied = value ~= nil
                if type(value) == "boolean" then supplied = value end
                if type(value) == "string" then supplied = value ~= "" end
                if type(value) == "table" then supplied = #(value) > 0 end
                if field and supplied then return rule_error(rule, field .. " is not supported for " .. tostring(request.profile_id)) end
            end
        elseif rule.kind == "values" then
            local field = bounds.id(rule.field)
            local allowed = rule.values
            local actual: descriptor_reader.OptionValue? = nil
            if field then actual = request_value(request, field) end
            if field and actual ~= nil and type(allowed) == "table" then
                if type(actual) == "table" then
                    for _, value in ipairs(actual) do
                        if not bounds.member(value, allowed) then return rule_error(rule, field .. " contains an unsupported value") end
                    end
                elseif not bounds.member(actual, allowed) then
                    return rule_error(rule, field .. " contains an unsupported value")
                end
            end
        elseif rule.kind == "requires_empty" then
            local field, other = bounds.id(rule.field), bounds.id(rule.other)
            local applies = rule.profile == nil or rule.profile == request.profile_id
            local value: descriptor_reader.OptionValue? = nil
            local other_value: descriptor_reader.OptionValue? = nil
            if field then value = request_value(request, field) end
            if other then other_value = request_value(request, other) end
            if applies and field and other and other_value ~= nil and value ~= nil and value ~= "" then
                return rule_error(rule, field .. " must be empty when " .. other .. " is selected")
            end
        elseif rule.kind == "forbid_pair" then
            local field, other = bounds.id(rule.field), bounds.id(rule.other)
            if field and other and request_value(request, field) ~= nil and request_value(request, other) ~= nil then
                return rule_error(rule, field .. " cannot be combined with " .. other)
            end
        elseif rule.kind == "forbid_nonempty" then
            local field = bounds.id(rule.field)
            local value: descriptor_reader.OptionValue? = nil
            if field then value = request_value(request, field) end
            if type(value) == "table" and #(value) > 0 then return rule_error(rule, field .. " is unsupported") end
        end
    end
    return nil
end

local function decode_request(selected: Descriptor, raw: unknown): (Request?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "launch request must be an object" end
    local options = bounds.object(selected.options) or {}
    local declared_fields = bounds.object(options.fields) or {}
    local allowed: {string} = {"profile_id", "brief"}
    for name in pairs(declared_fields) do allowed[#allowed + 1] = tostring(name) end
    local extra = bounds.fields(object, allowed)
    if extra then return nil, (bounds.text(options.unknown_prefix, 64) or "") .. extra end
    local profile_id = bounds.member(object.profile_id, assert(bounds.ids(options.profiles, true)))
    if not profile_id then return nil, "profile_id is not one Bee admits" end
    local brief = bounds.text(object.brief)
    if not brief or (brief == "" and profile_id ~= "window") then return nil, "brief must be nonempty bounded text" end
    local request: Request = {profile_id = profile_id, brief = brief}
    for name, raw_spec in pairs(declared_fields) do
        local field = tostring(name)
        local spec = descriptor_reader.runtime_spec(bounds.object(raw_spec) or {})
        if object[field] ~= nil then
            local decoded, decode_error = descriptor_reader.decode_option(field, spec, object[field])
            if decode_error then return nil, decode_error end
            request[field] = decoded
        elseif spec.default ~= nil then
            local decoded, decode_error = descriptor_reader.decode_option(field, spec, spec.default)
            if decode_error then return nil, decode_error end
            request[field] = decoded
        end
        local value = request[field]
        local supplied = value ~= nil
        if type(value) == "boolean" then supplied = value end
        if type(value) == "string" then supplied = value ~= "" end
        if type(value) == "table" then supplied = #(value) > 0 end
        if supplied and type(spec.profiles) == "table" and not bounds.member(profile_id, spec.profiles) then
            return nil, bounds.text(spec.unsupported, 256) or (field .. " is not supported for this profile")
        end
    end
    local rule_error_text = apply_rules(options, request)
    if rule_error_text then return nil, rule_error_text end
    return request, nil
end

local function interpolate(template: string, request: Request): string
    return (template:gsub("{([A-Za-z_][A-Za-z0-9_]*)}", function(field: string): string
        local value = request_value(request, field)
        if type(value) == "string" or type(value) == "number" then return tostring(value) end
        return ""
    end))
end

local function as_list(value: unknown): {unknown}
    if type(value) ~= "table" then return {} end
    return value
end

local function bounded_template_items(value: unknown): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, "CLI argv template must be an array" end
    local source = value
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "CLI argv template must be a dense array" end
        count = count + 1
        if count > descriptor_reader.MAX_TEMPLATE_ITEMS then return nil, "CLI argv template exceeds its item limit" end
    end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, "CLI argv template must be a dense array" end
        result[index] = source[index]
    end
    return result, nil
end

local function condition(item: Object, request: Request): boolean
    local function present(field: string): boolean
        local value = request_value(request, field)
        if type(value) == "table" then return #(value) > 0 end
        if type(value) == "string" then return value ~= "" end
        return value == true
    end
    if type(item.if_any) == "table" then
        for _, field_value in ipairs(item.if_any) do
            local field = bounds.id(field_value)
            if field and present(field) then return true end
        end
        return false
    elseif type(item.if_none) == "table" then
        for _, field_value in ipairs(item.if_none) do
            local field = bounds.id(field_value)
            if field and present(field) then return false end
        end
        return true
    end
    local field = bounds.id(item["if"])
    if not field then return false end
    local value = request_value(request, field)
    if item.equals ~= nil then return value == item.equals end
    if item.not_equals ~= nil then return value ~= item.not_equals end
    if item.starts_with ~= nil then return type(value) == "string" and (value):sub(1, #(item.starts_with)) == item.starts_with end
    return present(field)
end

local function render_json(value: unknown, request: Request, depth: integer): (unknown?, string?)
    if depth > 12 then return nil, "stdin JSON template exceeds its nesting bound" end
    if type(value) ~= "table" then return value, nil end
    local object = bounds.object(value)
    if object and object.field ~= nil then
        if bounds.fields(object, {"field"}) then return nil, "stdin JSON field template is malformed" end
        local field = bounds.id(object.field)
        local selected: descriptor_reader.OptionValue? = nil
        if field then selected = request_value(request, field) end
        if not field or selected == nil then return nil, "stdin JSON template names a missing request field" end
        return selected, nil
    end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(value) do
        local rendered, render_error = render_json(item, request, depth + 1)
        if render_error then return nil, render_error end
        result[key] = rendered
    end
    return result, nil
end

local function render_option(selected: Descriptor, name: string, request: Request, depth: integer): ({string}?, string?)
    local flags = bounds.object(selected.flags) or {}
    local spec = bounds.object(flags[name])
    if not spec then return nil, "CLI descriptor omits the " .. name .. " flag template" end
    local field = bounds.id(spec.field)
    if not field then return nil, "CLI descriptor " .. name .. " flag field is invalid" end
    local value = request_value(request, field)
    if value == nil then return {}, nil end
    if name == "permission" and spec.emit_default == false then
        local option_fields = bounds.object((bounds.object(selected.options) or {}).fields) or {}
        local option_spec = bounds.object(option_fields[field]) or {}
        if value == option_spec.default then return {}, nil end
    end
    local rendered, render_error = M.render_argv(spec.argv, request, selected, depth)
    if not rendered then return nil, render_error end
    return rendered, nil
end

function M.render_argv(raw: unknown, request: Request, selected: Descriptor, depth: integer?): ({string}?, string?)
    local nesting = depth or 0
    if nesting < 0 or nesting > descriptor_reader.MAX_TEMPLATE_DEPTH then return nil, "CLI argv template exceeds its rendering depth bound" end
    local nodes, nodes_error = bounded_template_items(raw)
    if not nodes then return nil, nodes_error end
    local result: {string} = {}
    local function append(argument: string): string?
        if #result >= descriptor_reader.MAX_TEMPLATE_ITEMS then return "CLI argv rendering exceeds its item limit" end
        result[#result + 1] = argument
        return nil
    end
    local function append_many(arguments: {string}): string?
        if #result + #arguments > descriptor_reader.MAX_TEMPLATE_ITEMS then return "CLI argv rendering exceeds its item limit" end
        for _, argument in ipairs(arguments) do result[#result + 1] = argument end
        return nil
    end
    for _, node in ipairs(nodes) do
        if type(node) == "string" then
            local append_error = append(node)
            if append_error then return nil, append_error end
        else
            local item = bounds.object(node)
            if not item then return nil, "CLI argv template is malformed" end
            if item.render ~= nil then
                local name = bounds.id(item.render)
                local fields = bounds.object((bounds.object(selected.options) or {}).fields) or {}
                local declaration = name and bounds.object(fields[name])
                if not declaration then return nil, "OptionSpec render is missing" end
                for _, raw_render in ipairs(as_list(declaration.render)) do
                    local render = bounds.object(raw_render)
                    local contexts = render and bounds.ids(render.contexts, true)
                    if render and render.kind == "argv" and contexts and bounds.member(item.context, contexts) then
                        local expanded, err = M.render_argv(render.tokens, request, selected, nesting + 1)
                        if not expanded then return nil, err end
                        local append_error = append_many(expanded)
                        if append_error then return nil, append_error end
                    end
                end
            elseif item.field ~= nil then
                local field = bounds.id(item.field)
                local value = field and request_value(request, field) or nil
                if type(value) ~= "string" and type(value) ~= "number" then return nil, "CLI argv template field is absent or not scalar" end
                local append_error = append(tostring(value))
                if append_error then return nil, append_error end
            elseif item.format ~= nil then
                local append_error = append(interpolate(item.format, request))
                if append_error then return nil, append_error end
            elseif item.option ~= nil then
                local option = bounds.id(item.option)
                if not option then return nil, "CLI argv template option is malformed" end
                local expanded, expand_error = render_option(selected, option, request, nesting + 1)
                if not expanded then return nil, expand_error end
                local append_error = append_many(expanded)
                if append_error then return nil, append_error end
            elseif item.join ~= nil then
                local join = bounds.object(item.join) or {}
                local field = bounds.id(join.field)
                if not field then return nil, "CLI argv join field is invalid" end
                local exclude: {[string]: boolean} = {}
                for _, entry in ipairs(as_list(join.exclude)) do if type(entry) == "string" then exclude[entry] = true end end
                local parts: {string} = {}
                local seen: {[string]: boolean} = {}
                for _, entry in ipairs(as_list(join.always)) do
                    if type(entry) == "string" and not seen[entry] then
                        seen[entry] = true
                        parts[#parts + 1] = (type(join.prefix) == "string" and join.prefix or "") .. (entry) .. (type(join.suffix) == "string" and join.suffix or "")
                    end
                end
                for _, entry in ipairs(as_list(request_value(request, field))) do
                    if type(entry) == "string" and not exclude[entry] then
                        local mapped = (type(join.prefix) == "string" and join.prefix or "") .. (entry) .. (type(join.suffix) == "string" and join.suffix or "")
                        if not seen[mapped] then seen[mapped] = true; parts[#parts + 1] = mapped end
                    end
                end
                local append_error = append(table.concat(parts, type(join.separator) == "string" and join.separator or ""))
                if append_error then return nil, append_error end
            elseif item["if"] ~= nil or item.if_any ~= nil or item.if_none ~= nil then
                local branch = condition(item, request) and item["then"] or item["else"] or {}
                local expanded, expand_error = M.render_argv(branch, request, selected, nesting + 1)
                if not expanded then return nil, expand_error end
                local append_error = append_many(expanded)
                if append_error then return nil, append_error end
            else
                return nil, "CLI argv template uses an unknown operation"
            end
        end
    end
    return result, nil
end

local function named_profile_file(selected: Descriptor, request: Request): string?
    local home = bounds.object(selected.provider_home) or {}
    local required = bounds.object(home.required_profile_file)
    if not required then return nil end
    local field = bounds.id(required.field)
    local value = nil
    if field then value = request_value(request, field) end
    if type(value) ~= "string" then return nil end
    local path = interpolate(assert(bounds.text(required.path_template, 256)), request)
    local directory = bounds.text(home.directory, 128)
    if directory then path = directory .. "/" .. path end
    return path
end

local function provider_home(selected: Descriptor, private: boolean, request: Request): types.ProviderHome
    local source = bounds.object(selected.provider_home) or {}
    local files: {types.ProviderHomeFile} = {}
    for _, raw_file in ipairs(as_list(source.files)) do
        local file = bounds.object(raw_file) or {}
        local source_path: string? = nil
        if type(file.source_path) == "string" then source_path = file.source_path end
        files[#files + 1] = {source_path = source_path, path = file.path, kind = file.kind,
            optional = file.optional, write_back = file.write_back, container_content = file.container_content, container_omit = file.container_omit}
    end
    if private then
        local path = named_profile_file(selected, request)
        if path then
            files[#files + 1] = {source_path = path, path = path, kind = "config", optional = false, write_back = false}
        end
    end
    local extras: {types.ProviderHomeEnvironment}? = nil
    if #as_list(source.extra_variables) > 0 then
        extras = {}
        for _, raw_environment in ipairs(as_list(source.extra_variables)) do
            local item = bounds.object(raw_environment) or {}
            extras[#extras + 1] = {variable = item.variable, directory = item.directory}
        end
    end
    local provider = selected.provider
    local variable = bounds.text(source.variable, 128)
    local directory = bounds.text(source.directory, 128)
    if variable and directory then
        return {provider = provider, private = private, variable = variable, directory = directory, extra_variables = extras, files = files}
    end
    return {provider = provider, private = private, variable = nil, directory = nil, extra_variables = extras, files = files}
end

local function build_launch(selected: Descriptor, request: Request): (types.Launch?, string?)
    local templates = bounds.object(selected.argv_templates) or {}
    local template_name = request.profile_id == "window" and "window" or (request_value(request, "resume_ref") ~= nil and "resume" or "first_turn")
    local template = bounds.object(templates[template_name])
    if not template then return nil, "CLI descriptor has no " .. template_name .. " launch template" end
    local argv, argv_error = M.render_argv(template.argv, request, selected)
    if not argv then return nil, argv_error end
    local launch: types.Launch = {executable = selected.executable, argv = argv, environment = {}, readiness = assert(bounds.id(template.readiness))}
    local input_written = false
    if template.stdin ~= nil then
        local stdin_node = bounds.object(template.stdin)
        local field = stdin_node and bounds.id(stdin_node.field) or nil
        if field then
            local content = request_value(request, field)
            if type(content) ~= "string" then return nil, "CLI stdin template field is not text" end
            launch.stdin = content
            input_written = true
        elseif type(template.stdin) == "string" then
            launch.stdin = interpolate(template.stdin, request)
            input_written = true
        else
            return nil, "CLI stdin template is malformed"
        end
    elseif template.stdin_json ~= nil then
        local should_write = true
        if type(template.stdin_when_any) == "table" then
            should_write = false
            for _, raw_field in ipairs(template.stdin_when_any) do
                local field = bounds.id(raw_field)
                local value: descriptor_reader.OptionValue? = nil
                if field then value = request_value(request, field) end
                if value == true then should_write = true end
            end
        end
        if should_write then
        local content, content_error = render_json(template.stdin_json, request, 0)
        if not content then return nil, content_error end
        local encoded, encode_error = canonical.encode(content)
        if not encoded then return nil, "encode the launch input: " .. tostring(encode_error) end
        launch.stdin = encoded .. "\n"
        input_written = true
        end
    end
    if template.stdin_eof == true then launch.stdin_eof = true end
    if type(template.session_end) == "string" and (template.stdin_json == nil or input_written) then launch.session_end = template.session_end end
    if template.provider_home_private ~= nil then launch.provider_home = provider_home(selected, template.provider_home_private == true, request) end
    if template.login == true then
        local evidence = selected.login_evidence
        local files: {types.RequiredFile} = {}
        for _, alternative in ipairs(evidence.any_of) do
            if alternative.kind == "file_exists" then
                for _, full_path in ipairs(alternative.paths) do
                    local path = full_path
                    if alternative.directory then path = path:sub(#alternative.directory + 2) end
                    files[#files + 1] = {variable = alternative.variable or "HOME", default_directory = alternative.directory, path = path}
                end
            end
        end
        launch.login = {provider = selected.provider, command = evidence.command, files = files, any_of = evidence.any_of}
    end
    local required_profile = bounds.object((bounds.object(selected.provider_home) or {}).required_profile_file)
    local profile_field = required_profile and bounds.id(required_profile.field) or nil
    if required_profile and profile_field and type(request_value(request, profile_field)) == "string"
        and required_profile.window_only == true and request.profile_id == "window" then
        local path = interpolate(assert(bounds.text(required_profile.path_template, 256)), request)
        launch.required_files = {{variable = required_profile.variable, path = path,
            default_directory = required_profile.default_directory}}
    end
    return launch, nil
end

local function launch_reply(ref: string, raw: unknown, dispatch: boolean): Object
    local descriptor, load_error = descriptor_reader.load(ref)
    if not descriptor then return {ok = false, error = load_error or "CLI descriptor is unavailable"} end
    local decoded, decode_error = decode_request(descriptor, raw)
    if not decoded then return {ok = false, error = decode_error or "launch request is invalid"} end
    if dispatch and not bounds.id(request_value(decoded, "resume_ref")) then return {ok = false, error = "a dispatched turn needs resume_ref"} end
    local launch, launch_error = build_launch(descriptor, decoded)
    if not launch then return {ok = false, error = launch_error or "CLI launch template is invalid"} end
    return {ok = true, launch = launch}
end

function M.launch(ref: string): LaunchAPI
    local function selected(): (Descriptor?, string?)
        local loaded, load_error = descriptor_reader.load(ref)
        if not loaded then return nil, load_error end
        return loaded, nil
    end
    return {
        decode = function(value: unknown): (Request?, string?)
            local descriptor, load_error = selected()
            if not descriptor then return nil, load_error or "CLI descriptor is unavailable" end
            return decode_request(descriptor, value)
        end,
        specification = function(request: Request): types.Launch
            local descriptor, load_error = selected()
            if not descriptor then error(tostring(load_error)) end
            local launch, launch_error = build_launch(descriptor, request)
            if not launch then error(tostring(launch_error)) end
            return launch
        end,
    }
end

function M.prepare(ref: string): (unknown) -> Object
    return function(raw: unknown): Object return launch_reply(ref, raw, false) end
end

function M.dispatch(ref: string): (unknown) -> Object
    return function(raw: unknown): Object return launch_reply(ref, raw, true) end
end

-- The contract's configure boundary decodes once and dispatches through the
-- descriptor's renderer id. Renderers contain only the CLI-specific format
-- operation; decoding, bounds, and refusal shape stay in bee.driver.
function M.configure(default_renderer: string, renderers: {[string]: ConfigureRenderer}, descriptor_ref: string): (unknown) -> Object
    if not bounds.id(default_renderer) or renderers[default_renderer] == nil then error("default configure renderer is unsupported") end
    return function(raw: unknown): Object
        local object = bounds.object(raw)
        if not object then return {ok = false, error = "configuration request must be an object"} end
        local selected: string? = default_renderer
        if object.configure_renderer ~= nil then
            selected = bounds.id(object.configure_renderer)
        end
        local renderer: ConfigureRenderer? = nil
        if selected then renderer = renderers[selected] end
        if not renderer then return {ok = false, error = "CLI descriptor selects an unsupported configure renderer"} end
        local config_request: {[string]: unknown} = {}
        for key, value in pairs(object) do
            if key ~= "configure_renderer" then config_request[key] = value end
        end
        local request, decode_error = configuration.decode_request(config_request)
        if not request then return {ok = false, error = decode_error or "invalid configuration request"} end
        local descriptor, descriptor_error = descriptor_reader.load(descriptor_ref)
        if not descriptor then return {ok = false, error = descriptor_error or "Configuration descriptor is unavailable"} end
        local prompt_file: configuration.Configuration? = nil
        local prompt_arguments: {string} = {}
        if request.instructions then
            local fields = bounds.object((bounds.object(descriptor.options) or {}).fields) or {}
            local declaration = bounds.object(fields.system_prompt_append)
            local renders = declaration and as_list(declaration.render) or {}
            for _, raw_render in ipairs(renders) do
                local render = bounds.object(raw_render)
                if render and render.kind == "config" and render.format == "text" then request.instructions_path = bounds.subpath(render.file) end
            end
            if not request.instructions_path then return {ok = false, error = "System prompt append has no declared private-home file"} end
            local file, file_error = configuration.instructions_file(request.instructions_path, request.instructions)
            if not file then return {ok = false, error = file_error} end
            prompt_file = file
            if not request.home_directory then return {ok = false, error = "System prompt append requires the owner-derived private home"} end
            local prompt: Request = {profile_id = "batch", brief = "", system_prompt_append = request.instructions,
                system_prompt_file = request.home_directory .. "/" .. file.path}
            for _, raw_render in ipairs(renders) do
                local render = bounds.object(raw_render)
                if render and render.kind == "argv" then
                    local tokens, render_error = M.render_argv(render.tokens, prompt, descriptor)
                    if not tokens then return {ok = false, error = render_error} end
                    for _, token in ipairs(tokens) do prompt_arguments[#prompt_arguments + 1] = token end
                end
            end
        end
        local reply = renderer(request)
        if reply.ok ~= true then return reply end
        local delivery, delivery_error = configuration.decode_delivery(reply.delivery)
        if not delivery then return {ok = false, error = delivery_error} end
        if prompt_file then delivery.files[#delivery.files + 1] = prompt_file end
        for _, argument in ipairs(prompt_arguments) do delivery.arguments[#delivery.arguments + 1] = argument end
        return {ok = true, delivery = delivery}
    end
end

function M.locate(ref: string): (unknown) -> (types.LocateResult?, string?)
    return function(raw: unknown): (types.LocateResult?, string?)
        local loaded, load_error = descriptor_reader.load(ref)
        if not loaded then return nil, load_error end
        local selected = loaded
        local result, result_error = locate.evaluate({provider = selected.provider, executable = selected.executable,
            login_evidence = selected.login_evidence}, raw)
        return result, result_error
    end
end

type DeferredProtocol = {
    revision: () -> string, max_answer_bytes: () -> integer,
    new: (boolean) -> unknown, decode_state: (unknown) -> (unknown?, string?),
    normalize: (unknown, integer, Object, integer?) -> (ProtocolStep?, string?),
    finish: (unknown, integer) -> (ProtocolStep?, string?),
}
function M.protocol(ref: string): DeferredProtocol
    local function selected(): codec_registry.Protocol
        local descriptor, load_error = descriptor_reader.load(ref)
        if not descriptor then error(tostring(load_error or "CLI descriptor is unavailable")) end
        local json_paths = bounds.object(descriptor.json_paths) or {}
        local protocol = codec_registry.resolve(descriptor.codec, json_paths)
        if not protocol then error("CLI descriptor selects an unsupported codec") end
        return protocol
    end
    -- Bindings load before registry startup. Defer descriptor lookup until a
    -- protocol method or property is used by a running request.
    local protocol: DeferredProtocol = {
        revision = function(): string return selected().PROTOCOL_REVISION end,
        max_answer_bytes = function(): integer return selected().MAX_ANSWER_BYTES end,
        new = function(resumed: boolean): unknown return selected().new(resumed) end,
        decode_state = function(raw: unknown): (unknown?, string?) return selected().decode_state(raw) end,
        normalize = function(state: unknown, index: integer, envelope: Object, budget: integer?): (ProtocolStep?, string?)
            return selected().normalize(state, index, envelope)
        end,
        finish = function(state: unknown, index: integer): (ProtocolStep?, string?) return selected().finish(state, index) end,
    }
    return setmetatable(protocol, {__index = function(_self: unknown, name: string): unknown return selected()[name] end})
end

function M.normalize(ref: string): (unknown) -> unknown
    return function(request: unknown): unknown
        local descriptor, load_error = descriptor_reader.load(ref)
        if not descriptor then error(tostring(load_error or "CLI descriptor is unavailable")) end
        local normalize = codec_registry.bind(descriptor.codec, descriptor.json_paths)
        if not normalize then error("CLI descriptor selects an unsupported codec") end
        return normalize(request)
    end
end

return M
