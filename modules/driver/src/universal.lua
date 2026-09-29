-- MIT. One external driver implementation; provider behavior is selected by
-- a strictly decoded registry descriptor.
local bounds = require("bounds")
local canonical = require("canonical")
local descriptor_reader = require("descriptor")
local configuration = require("configuration")
local turn_budget = require("turn_budget")
local types = require("types")
local locate = require("locate")
local codec_registry = require("codec_registry")
local normalizer = require("normalizer")
local M = {}

type Object = {[string]: unknown}
type ProtocolStep = {observations: {Object}, terminal: unknown?}
type Descriptor = {[string]: unknown}
type Request = {[string]: unknown}
type ConfigureRequest = configuration.Request
type ProviderHomeFileKind = "login" | "config" | "state"
type LaunchAPI = {
    decode: (unknown) -> (Request?, string?),
    specification: (Request) -> types.Launch,
    descriptor: Descriptor?,
    PERMISSION_MODES: {string}?,
    APPROVAL_MODES: {string}?,
    MODES: {string}?,
    EFFORTS: {string}?,
    SANDBOXES: {string}?,
    MAX_TURNS: integer?,
    MAX_STEPS: integer?,
    MAX_CONFIG_PROFILE_BYTES: integer?,
}

local function text(value: unknown, field: string, limit: integer?): (string?, string?)
    local selected = bounds.text(value, limit)
    if not selected then return nil, field .. " must be bounded text" end
    return selected, nil
end

local function field_error(spec: Object, field: string, fallback: string): string
    local message = bounds.text(spec.invalid, 256)
    return message or (field .. " " .. fallback)
end

local function decode_field(field: string, spec: Object, value: unknown): (unknown?, string?)
    local kind = spec.type
    if kind == "enum" then
        local selected = bounds.member(value, spec.values :: {string})
        if not selected then return nil, field_error(spec, field, "is not one Bee admits") end
        return selected, nil
    elseif kind == "boolean" then
        if type(value) ~= "boolean" then return nil, field_error(spec, field, "must be a boolean") end
        return value, nil
    elseif kind == "id" then
        if spec.forbid_option == true and type(value) == "string" and (value :: string):sub(1, 1) == "-" then
            return nil, field_error(spec, field, "must not be a command-line option")
        end
        local selected = bounds.id(value)
        if not selected then return nil, field_error(spec, field, "is not an identifier") end
        if spec.forbid_option == true and selected:sub(1, 1) == "-" then
            return nil, field_error(spec, field, "must not be a command-line option")
        end
        return selected, nil
    elseif kind == "model" then
        local selected = bounds.text(value, 128)
        if not selected or selected == "" or not selected:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then
            return nil, field_error(spec, field, "is not one bounded model identifier")
        end
        return selected, nil
    elseif kind == "budget" then
        local selected, budget_error = turn_budget.decode(value, field)
        if not selected then return nil, budget_error or field_error(spec, field, "is invalid") end
        if spec.max ~= nil and selected > (bounds.count(spec.max) or 0) then return nil, field_error(spec, field, "exceeds its admitted limit") end
        return selected, nil
    elseif kind == "duration" then
        local selected = bounds.text(value, 32)
        if not selected or not selected:match("^[1-9][0-9]*[smh]$") then return nil, field_error(spec, field, "must be a positive duration string") end
        return selected, nil
    elseif kind == "codex_profile" then
        local selected = bounds.text(value, 64)
        if not selected or not selected:match("^[A-Za-z0-9_][A-Za-z0-9_-]*$") then return nil, field_error(spec, field, "must be a plain Codex profile name") end
        return selected, nil
    elseif kind == "ids" then
        local selected, ids_error = bounds.ids(value, true)
        if not selected then return nil, field .. ": " .. tostring(ids_error) end
        if type(spec.pattern) == "string" then
            for _, entry in ipairs(selected) do
                if not entry:match(spec.pattern :: string) then return nil, field_error(spec, field, "contains invalid value") end
            end
        end
        if spec.values ~= nil then
            for _, entry in ipairs(selected) do
                if not bounds.member(entry, spec.values :: {string}) then return nil, field_error(spec, field, "contains unsupported value " .. entry) end
            end
        end
        if spec.transform == "presence" then return #selected > 0, nil end
        if spec.transform == "sorted" then table.sort(selected) end
        return selected, nil
    end
    return nil, "CLI descriptor has an unsupported " .. field .. " decoder"
end

local function rule_error(rule: Object, fallback: string): string
    return bounds.text(rule.message, 256) or fallback
end

local function apply_rules(options: Object, request: Request): string?
    local rules = options.rules
    if type(rules) ~= "table" then return nil end
    for _, raw_rule in ipairs(rules :: {unknown}) do
        local rule = bounds.object(raw_rule) or {}
        if rule.kind == "profile_fields" and request.profile_id == rule.profile and type(rule.fields) == "table" then
            for _, raw_field in ipairs(rule.fields :: {unknown}) do
                local field = bounds.id(raw_field)
                local value = field and request[field] or nil
                local supplied = value ~= nil
                if type(value) == "boolean" then supplied = value end
                if type(value) == "string" then supplied = value ~= "" end
                if type(value) == "table" then supplied = #(value :: {unknown}) > 0 end
                if field and supplied then return rule_error(rule, field .. " is not supported for " .. tostring(request.profile_id)) end
            end
        elseif rule.kind == "values" then
            local field = bounds.id(rule.field)
            local allowed = rule.values :: {string}
            local actual = field and request[field] or nil
            if field and actual ~= nil and type(allowed) == "table" then
                if type(actual) == "table" then
                    for _, value in ipairs(actual :: {unknown}) do
                        if not bounds.member(value, allowed) then return rule_error(rule, field .. " contains an unsupported value") end
                    end
                elseif not bounds.member(actual, allowed) then
                    return rule_error(rule, field .. " contains an unsupported value")
                end
            end
        elseif rule.kind == "requires_empty" then
            local field, other = bounds.id(rule.field), bounds.id(rule.other)
            local applies = rule.profile == nil or rule.profile == request.profile_id
            if applies and field and other and request[other] ~= nil and request[field] ~= nil and request[field] ~= "" then
                return rule_error(rule, field .. " must be empty when " .. other .. " is selected")
            end
        elseif rule.kind == "forbid_pair" then
            local field, other = bounds.id(rule.field), bounds.id(rule.other)
            if field and other and request[field] ~= nil and request[other] ~= nil then
                return rule_error(rule, field .. " cannot be combined with " .. other)
            end
        elseif rule.kind == "forbid_nonempty" then
            local field = bounds.id(rule.field)
            local value = field and request[field] or nil
            if type(value) == "table" and #(value :: {unknown}) > 0 then return rule_error(rule, field .. " is unsupported") end
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
    local profile_id = bounds.member(object.profile_id, options.profiles :: {string})
    if not profile_id then return nil, "profile_id is not one Bee admits" end
    local brief = bounds.text(object.brief)
    if not brief or (brief == "" and profile_id ~= "window") then return nil, "brief must be nonempty bounded text" end
    local request: Request = {profile_id = profile_id, brief = brief}
    for name, raw_spec in pairs(declared_fields) do
        local field = tostring(name)
        local spec = bounds.object(raw_spec) or {}
        if object[field] ~= nil then
            local decoded, decode_error = decode_field(field, spec, object[field])
            if decode_error then return nil, decode_error end
            request[field] = decoded
        elseif spec.default ~= nil then
            request[field] = spec.default
        end
        local value = request[field]
        local supplied = value ~= nil
        if type(value) == "boolean" then supplied = value end
        if type(value) == "string" then supplied = value ~= "" end
        if type(value) == "table" then supplied = #(value :: {unknown}) > 0 end
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
        local value = request[field]
        if type(value) == "string" or type(value) == "number" then return tostring(value) end
        return ""
    end))
end

local function as_list(value: unknown): {unknown}
    if type(value) ~= "table" then return {} end
    return value :: {unknown}
end

local function condition(item: Object, request: Request): boolean
    local function present(field: string): boolean
        local value = request[field]
        if type(value) == "table" then return #(value :: {unknown}) > 0 end
        if type(value) == "string" then return value ~= "" end
        return value == true
    end
    if type(item.if_any) == "table" then
        for _, field_value in ipairs(item.if_any :: {unknown}) do
            local field = bounds.id(field_value)
            if field and present(field) then return true end
        end
        return false
    elseif type(item.if_none) == "table" then
        for _, field_value in ipairs(item.if_none :: {unknown}) do
            local field = bounds.id(field_value)
            if field and present(field) then return false end
        end
        return true
    end
    local field = bounds.id(item["if"])
    if not field then return false end
    local value = request[field]
    if item.equals ~= nil then return value == item.equals end
    if item.not_equals ~= nil then return value ~= item.not_equals end
    if item.starts_with ~= nil then return type(value) == "string" and (value :: string):sub(1, #(item.starts_with :: string)) == item.starts_with end
    return present(field)
end

local function render_json(value: unknown, request: Request, depth: integer): (unknown?, string?)
    if depth > 12 then return nil, "stdin JSON template exceeds its nesting bound" end
    if type(value) ~= "table" then return value, nil end
    local object = bounds.object(value)
    if object and object.field ~= nil then
        if bounds.fields(object, {"field"}) then return nil, "stdin JSON field template is malformed" end
        local field = bounds.id(object.field)
        if not field or request[field] == nil then return nil, "stdin JSON template names a missing request field" end
        return request[field] :: unknown?, nil
    end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(value :: {[unknown]: unknown}) do
        local rendered, render_error = render_json(item, request, depth + 1)
        if render_error then return nil, render_error end
        result[key] = rendered
    end
    return result, nil
end

local function render_option(selected: Descriptor, name: string, request: Request): ({string}?, string?)
    local flags = bounds.object(selected.flags) or {}
    local spec = bounds.object(flags[name])
    if not spec then return nil, "CLI descriptor omits the " .. name .. " flag template" end
    local field = bounds.id(spec.field)
    if not field then return nil, "CLI descriptor " .. name .. " flag field is invalid" end
    local value = request[field]
    if value == nil then return {}, nil end
    if name == "permission" and spec.emit_default == false then
        local option_fields = bounds.object((bounds.object(selected.options) or {}).fields) or {}
        local option_spec = bounds.object(option_fields[field]) or {}
        if value == option_spec.default then return {}, nil end
    end
    local rendered, render_error = M.render_argv(spec.argv, request, selected)
    if not rendered then return nil, render_error end
    return rendered, nil
end

function M.render_argv(raw: unknown, request: Request, selected: Descriptor): ({string}?, string?)
    local result: {string} = {}
    for _, node in ipairs(as_list(raw)) do
        if type(node) == "string" then
            result[#result + 1] = node :: string
        else
            local item = bounds.object(node)
            if not item then return nil, "CLI argv template is malformed" end
            if item.field ~= nil then
                local field = bounds.id(item.field)
                local value = field and request[field] or nil
                if type(value) ~= "string" and type(value) ~= "number" then return nil, "CLI argv template field is absent or not scalar" end
                result[#result + 1] = tostring(value)
            elseif item.format ~= nil then
                result[#result + 1] = interpolate(item.format :: string, request)
            elseif item.option ~= nil then
                local expanded, expand_error = render_option(selected, tostring(item.option), request)
                if not expanded then return nil, expand_error end
                for _, arg in ipairs(expanded) do result[#result + 1] = arg end
            elseif item.join ~= nil then
                local join = bounds.object(item.join) or {}
                local field = bounds.id(join.field)
                if not field then return nil, "CLI argv join field is invalid" end
                local exclude: {[string]: boolean} = {}
                for _, entry in ipairs(as_list(join.exclude)) do if type(entry) == "string" then exclude[entry :: string] = true end end
                local parts: {string} = {}
                local seen: {[string]: boolean} = {}
                for _, entry in ipairs(as_list(join.always)) do
                    if type(entry) == "string" and not seen[entry :: string] then
                        seen[entry :: string] = true
                        parts[#parts + 1] = (type(join.prefix) == "string" and join.prefix or "") .. (entry :: string) .. (type(join.suffix) == "string" and join.suffix or "")
                    end
                end
                for _, entry in ipairs(as_list(request[field])) do
                    if type(entry) == "string" and not exclude[entry :: string] then
                        local mapped = (type(join.prefix) == "string" and join.prefix or "") .. (entry :: string) .. (type(join.suffix) == "string" and join.suffix or "")
                        if not seen[mapped] then seen[mapped] = true; parts[#parts + 1] = mapped end
                    end
                end
                result[#result + 1] = table.concat(parts, type(join.separator) == "string" and join.separator or "")
            elseif item["if"] ~= nil or item.if_any ~= nil or item.if_none ~= nil then
                local branch = condition(item, request) and item["then"] or item["else"] or {}
                local expanded, expand_error = M.render_argv(branch, request, selected)
                if not expanded then return nil, expand_error end
                for _, arg in ipairs(expanded) do result[#result + 1] = arg end
            else
                return nil, "CLI argv template uses an unknown operation"
            end
        end
    end
    return result, nil
end

local function provider_home(selected: Descriptor, private: boolean): types.ProviderHome
    local source = bounds.object(selected.provider_home) or {}
    local files: {types.ProviderHomeFile} = {}
    for _, raw_file in ipairs(as_list(source.files)) do
        local file = bounds.object(raw_file) or {}
        local source_path: string? = nil
        if type(file.source_path) == "string" then source_path = file.source_path :: string end
        files[#files + 1] = {source_path = source_path, path = file.path :: string, kind = file.kind :: ProviderHomeFileKind,
            optional = file.optional :: boolean, write_back = file.write_back :: boolean}
    end
    local extras: {types.ProviderHomeEnvironment}? = nil
    if #as_list(source.extra_variables) > 0 then
        extras = {}
        for _, raw_environment in ipairs(as_list(source.extra_variables)) do
            local item = bounds.object(raw_environment) or {}
            extras[#extras + 1] = {variable = item.variable :: string, directory = item.directory :: string}
        end
    end
    local provider = selected.provider :: string
    local variable = bounds.text(source.variable, 128)
    local directory = bounds.text(source.directory, 128)
    if variable and directory then
        return {provider = provider, private = private, variable = variable, directory = directory, extra_variables = extras, files = files}
    end
    return {provider = provider, private = private, variable = nil, directory = nil, extra_variables = extras, files = files}
end

local function build_launch(selected: Descriptor, request: Request): (types.Launch?, string?)
    local templates = bounds.object(selected.argv_templates) or {}
    local template_name = request.profile_id == "window" and "window" or (request.resume_ref ~= nil and "resume" or "first_turn")
    local template = bounds.object(templates[template_name])
    if not template then return nil, "CLI descriptor has no " .. template_name .. " launch template" end
    local argv, argv_error = M.render_argv(template.argv, request, selected)
    if not argv then return nil, argv_error end
    local launch: types.Launch = {executable = selected.executable :: string, argv = argv, environment = {}, readiness = template.readiness :: string}
    local input_written = false
    if template.stdin ~= nil then
        local stdin_node = bounds.object(template.stdin)
        local field = stdin_node and bounds.id(stdin_node.field) or nil
        if field then
            local content = request[field]
            if type(content) ~= "string" then return nil, "CLI stdin template field is not text" end
            launch.stdin = content
            input_written = true
        elseif type(template.stdin) == "string" then
            launch.stdin = interpolate(template.stdin :: string, request)
            input_written = true
        else
            return nil, "CLI stdin template is malformed"
        end
    elseif template.stdin_json ~= nil then
        local should_write = true
        if type(template.stdin_when_any) == "table" then
            should_write = false
            for _, raw_field in ipairs(template.stdin_when_any :: {unknown}) do
                local field = bounds.id(raw_field)
                local value = field and request[field] or nil
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
    if type(template.session_end) == "string" and (template.stdin_json == nil or input_written) then launch.session_end = template.session_end :: string end
    if template.provider_home_private ~= nil then launch.provider_home = provider_home(selected, template.provider_home_private == true) end
    if template.login == true then
        local evidence = bounds.object(selected.login_evidence) or {}
        local variable = type(evidence.variable) == "string" and evidence.variable or "HOME"
        local directory = type(evidence.directory) == "string" and evidence.directory or nil
        local path = evidence.path :: string
        if directory and path:sub(1, #directory + 1) == directory .. "/" then path = path:sub(#directory + 2)
        elseif variable == "HOME" then directory = nil
        else return nil, "login evidence path is outside its provider-home directory" end
        launch.login = {provider = selected.provider, command = evidence.command :: string,
            files = {{variable = variable, default_directory = directory, path = path}}}
    end
    local required_profile = bounds.object((bounds.object(selected.provider_home) or {}).required_profile_file)
    if required_profile then
        local field = bounds.id(required_profile.field)
        local value = field and request[field] or nil
        if type(value) == "string" and (required_profile.window_only ~= true or request.profile_id == "window") then
            local path = interpolate(required_profile.path_template :: string, request)
            launch.required_files = {{variable = required_profile.variable :: string, path = path,
                default_directory = required_profile.default_directory :: string?}}
        end
    end
    return launch, nil
end

function M.launch(ref: string): LaunchAPI
    local function selected(): (Descriptor?, string?)
        local loaded, load_error = descriptor_reader.load(ref)
        if not loaded then return nil, load_error end
        return loaded :: Descriptor, nil
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
        descriptor = nil,
    }
end

function M.prepare(ref: string): (unknown) -> Object
    local launch = M.launch(ref)
    return function(raw: unknown): Object
        local decoded, decode_error = launch.decode(raw)
        if not decoded then return {ok = false, error = decode_error} end
        return {ok = true, launch = launch.specification(decoded)}
    end
end

function M.dispatch(ref: string): (unknown) -> Object
    local launch = M.launch(ref)
    return function(raw: unknown): Object
        local decoded, decode_error = launch.decode(raw)
        if not decoded then return {ok = false, error = decode_error} end
        local request = decoded :: Request
        if not bounds.id(request.resume_ref) then return {ok = false, error = "a dispatched turn needs resume_ref"} end
        return {ok = true, launch = launch.specification(request)}
    end
end

-- The contract's configure boundary is shared. Descriptors select a thin
-- renderer for the CLI's distinct configuration format; decoding, bounds,
-- and refusal shape stay in bee.driver.
function M.configure(ref: string, renderer: (ConfigureRequest) -> Object): (unknown) -> Object
    if not bounds.id(ref) then error("CLI descriptor reference is invalid") end
    return function(raw: unknown): Object
        local request, decode_error = configuration.decode_request(raw)
        if not request then return {ok = false, error = decode_error or "invalid configuration request"} end
        return renderer(request)
    end
end

function M.locate(ref: string): (unknown) -> (types.LocateResult?, string?)
    return function(raw: unknown): (types.LocateResult?, string?)
        local loaded, load_error = descriptor_reader.load(ref)
        if not loaded then return nil, load_error end
        local selected = loaded :: Descriptor
        local evidence = bounds.object(selected.login_evidence) or {}
        local result, result_error = locate.evaluate({provider = selected.provider :: string, executable = selected.executable :: string,
            login_path = evidence.path :: string}, raw)
        return result :: types.LocateResult?, result_error
    end
end

function M.protocol(ref: string): codec_registry.Protocol
    local function selected(): codec_registry.Protocol
        local descriptor, load_error = descriptor_reader.load(ref)
        if not descriptor then error(tostring(load_error or "CLI descriptor is unavailable")) end
        local protocol = codec_registry.resolve(descriptor.codec :: string)
        if not protocol then error("CLI descriptor selects an unsupported codec") end
        return protocol
    end
    -- Bindings load before registry startup. Defer descriptor lookup until a
    -- protocol method or property is used by a running request.
    return setmetatable({}, {__index = function(_, name) return selected()[name] end}) :: codec_registry.Protocol
end

function M.normalize(ref: string): (unknown) -> unknown
    local protocol = M.protocol(ref)
    return normalizer.bind(
        function(resumed: boolean): unknown return protocol.new(resumed) end,
        function(value: unknown): (unknown?, string?) return protocol.decode_state(value) end,
        function(state: unknown, index: integer, envelope: {[string]: unknown}, budget: integer?): (ProtocolStep?, string?)
            return protocol.normalize(state, index, envelope, budget)
        end,
        function(state: unknown, index: integer): (ProtocolStep?, string?) return protocol.finish(state, index) end)
end

return M
