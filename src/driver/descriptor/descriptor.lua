-- MIT. Strict decoder and registry reader for declarative external CLI drivers.
local bounds = require("bounds")
local registry = require("registry")
local login_evidence = require("login_evidence")
local schema_values = require("schema_values")
local M = {}
type PermissionAnswer = {transport: string, adapter_ref: string?, reason: string?}
type Capabilities = {permission_answers: {[string]: PermissionAnswer}}
local function capabilities(value: unknown): (Capabilities?, string?)
    if value == nil then return {permission_answers = {}}, nil end
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"permission_answers"}) then return nil, "CLI descriptor.capabilities is malformed" end
    local answers = bounds.object(object.permission_answers)
    if not answers or bounds.fields(answers, {"window", "first_turn", "resume"}) then return nil, "CLI descriptor permission_answers contexts are malformed" end
    local result: {[string]: PermissionAnswer} = {}
    for _, context in ipairs({"window", "first_turn", "resume"}) do
        local item = bounds.object(answers[context])
        if not item or bounds.fields(item, {"transport", "adapter_ref", "reason"}) then return nil, "permission_answers." .. context .. " is malformed" end
        local transport = bounds.member(item.transport, {"stdio", "hook_http", "hook_mcp", "provider"})
        local adapter_ref = item.adapter_ref == nil and nil or bounds.id(item.adapter_ref)
        local reason = item.reason == nil and nil or bounds.text(item.reason, 1024)
        if not transport or (transport == "provider" and (not reason or adapter_ref ~= nil))
            or (transport ~= "provider" and not adapter_ref) or (item.reason ~= nil and not reason) then return nil, "permission_answers." .. context .. " needs an adapter or an unsupported reason" end
        result[context] = {transport = transport, adapter_ref = adapter_ref, reason = reason}
    end
    return {permission_answers = result}, nil
end
M.TYPE = "bee.driver.cli_descriptor"
M.SCHEMA = "bee.driver.cli-descriptor@4"
M.MAX_TEMPLATE_ITEMS = 128
M.MAX_TEMPLATE_DEPTH = 8
M.CODECS = {"claude-stream-json", "codex-jsonl", "opencode-json-events", "agy-stream-json", "grok-streaming-json", "muse-record-jsonl"}

type Object = {[string]: unknown}
type OptionValue = string | number | boolean | {[string]: unknown} | {unknown}
type Descriptor = {
    schema_revision: string,
    provider: string,
    executable: string,
    version_probe: Object,
    login_evidence: login_evidence.Declaration,
    platform: Object,
    codec: string,
    json_paths: Object,
    argv_templates: Object,
    options: Object,
    flags: Object,
    provider_home: Object,
    configure: string,
    capabilities: Capabilities?,
}

local function object(value: unknown, label: string): (Object?, string?)
    local decoded = bounds.object(value)
    if not decoded then return nil, label .. " must be an object" end
    return decoded, nil
end

local function sequence(value: unknown, label: string, limit: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be an array" end
    local source = value
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, label .. " must be a dense array" end
        count = count + 1
        if count > limit then return nil, label .. " exceeds its item limit" end
    end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense array" end
        result[index] = source[index]
    end
    return result, nil
end

local function safe_relative(path: string): boolean
    if path == "" or path:sub(1, 1) == "/" or path:find("[%z\\\\]") then return false end
    for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
    return true
end

local function field_error(spec: Object, field: string, fallback: string): string
    local message = bounds.text(spec.invalid, 256)
    return message or (field .. " " .. fallback)
end

function M.runtime_spec(spec: Object): Object
    local schema = bounds.object(spec.value_schema)
    if not schema then return spec end
    local result: Object = {}
    for _, name in ipairs({"default", "profiles", "transform", "pattern", "invalid", "unsupported", "forbid_option"}) do result[name] = spec[name] end
    if schema.enum ~= nil then result.type = "enum"; result.values = schema.enum
    elseif schema.type == "boolean" then result.type = "boolean"
    elseif schema.type == "array" and spec.transform ~= nil then result.type = "ids"; result.values = (bounds.object(schema.items) or {}).enum
    elseif schema.type == "array" then result.type = "json"; result.schema = schema
    elseif schema.type == "object" or schema.type == "number" or schema.type == "integer" then result.type = "json"; result.schema = schema
    else result.type = schema.format or "text"; result.max = schema.maxLength end
    return result
end

function M.decode_option(field: string, declaration: Object, value: unknown): (OptionValue?, string?)
    local spec = M.runtime_spec(declaration)
    if spec.type == "json" then
        return schema_values.decode(spec.schema, value, field)
    elseif spec.type == "text" then
        local text = bounds.text(value, bounds.count(spec.max) or 4096)
        if not text or text:find("%z") then return nil, field .. " must be bounded text" end
        return text, nil
    elseif spec.type == "enum" then
        local values = type(spec.values) == "table" and spec.values or {}
        local selected = bounds.member(value, values)
        if not selected then return nil, field_error(spec, field, "is not one Bee admits") end
        return selected, nil
    elseif spec.type == "boolean" then
        if type(value) ~= "boolean" then return nil, field_error(spec, field, "must be a boolean") end
        return value, nil
    elseif spec.type == "id" then
        if spec.forbid_option == true and type(value) == "string" and (value):sub(1, 1) == "-" then
            return nil, field_error(spec, field, "must not be a command-line option")
        end
        local selected = bounds.id(value)
        if not selected then return nil, field_error(spec, field, "is not an identifier") end
        return selected, nil
    elseif spec.type == "model" then
        local selected = bounds.text(value, 128)
        if not selected or selected == "" or not selected:match("^[A-Za-z0-9][A-Za-z0-9._:/%-]*$") then
            return nil, field_error(spec, field, "is not one bounded model identifier")
        end
        return selected, nil
    elseif spec.type == "duration" then
        local selected = bounds.text(value, 32)
        if not selected or not selected:match("^[1-9][0-9]*[smh]$") then return nil, field_error(spec, field, "must be a positive duration string") end
        return selected, nil
    elseif spec.type == "codex_profile" then
        local selected = bounds.text(value, 64)
        if not selected or not selected:match("^[A-Za-z0-9_][A-Za-z0-9_-]*$") then return nil, field_error(spec, field, "must be a plain Codex profile name") end
        return selected, nil
    elseif spec.type == "ids" then
        local selected, ids_error = bounds.ids(value, true)
        if not selected then return nil, field .. ": " .. tostring(ids_error) end
        if type(spec.pattern) == "string" then
            for _, entry in ipairs(selected) do
                if not entry:match(spec.pattern) then return nil, field_error(spec, field, "contains invalid value") end
            end
        end
        if type(spec.values) == "table" then
            for _, entry in ipairs(selected) do
                if not bounds.member(entry, spec.values) then return nil, field_error(spec, field, "contains unsupported value " .. entry) end
            end
        end
        if spec.transform == "presence" then return #selected > 0, nil end
        if spec.transform == "sorted" then table.sort(selected) end
        return selected, nil
    end
    return nil, "CLI descriptor has an unsupported " .. field .. " decoder"
end

local function validate_template(value: unknown, label: string, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the template nesting bound" end
    if type(value) == "string" then return nil end
    if type(value) ~= "table" then return label .. " contains an invalid template node" end
    local item = value
    local fields = bounds.fields(item, {"field", "format", "if", "if_any", "if_none", "equals", "not_equals", "starts_with", "then", "else", "option", "join", "render", "context"})
    if fields then return label .. ": " .. fields end
    local selected = 0
    for _, name in ipairs({"field", "format", "if", "if_any", "if_none", "option", "join", "render"}) do if item[name] ~= nil then selected = selected + 1 end end
    if selected ~= 1 then return label .. " must select one template operation" end
    if item.render ~= nil then
        if not bounds.id(item.render) or not bounds.member(item.context, {"window", "first_turn", "resume"}) or bounds.fields(item, {"render", "context"}) then return label .. " render reference is invalid" end
        return nil
    end
    if item.field ~= nil then
        if not bounds.id(item.field) or bounds.fields(item, {"field"}) then return label .. " field reference is malformed" end
        return nil
    end
    if item.format ~= nil then
        if type(item.format) ~= "string" or item.format == "" or bounds.fields(item, {"format"}) then return label .. " format is malformed" end
        return nil
    end
    if item.option ~= nil then
        if item.option ~= "permission" or bounds.fields(item, {"option"}) then return label .. " option reference is malformed" end
        return nil
    end
    if item.join ~= nil then
        local join, join_error = object(item.join, label .. " join")
        if not join then return join_error end
        local extra = bounds.fields(join, {"field", "separator", "prefix", "suffix", "always", "exclude"})
        if extra then return label .. " join: " .. extra end
        if not bounds.id(join.field) or type(join.separator) ~= "string" then return label .. " join is malformed" end
        for _, name in ipairs({"always", "exclude"}) do
            if join[name] ~= nil then
                local values, values_error = sequence(join[name], label .. " join." .. name, 32)
                if not values then return values_error end
                for _, entry in ipairs(values) do if not bounds.text(entry, 128) then return label .. " join." .. name .. " contains invalid text" end end
            end
        end
        for _, name in ipairs({"prefix", "suffix"}) do
            if join[name] ~= nil and type(join[name]) ~= "string" then return label .. " join." .. name .. " must be text" end
        end
        return nil
    end
    if item["if"] == nil then
        local condition_fields = item.if_any or item.if_none
        local names, names_error = sequence(condition_fields, label .. " condition fields", 16)
        if not names or #names == 0 then return names_error or (label .. " condition fields are empty") end
        for _, name in ipairs(names) do if not bounds.id(name) then return label .. " condition field is invalid" end end
    elseif not bounds.id(item["if"]) then return label .. " condition field is invalid" end
    if item.starts_with ~= nil and type(item.starts_with) ~= "string" then return label .. " starts_with must be text" end
    local branches = 0
    for _, name in ipairs({"equals", "not_equals", "starts_with"}) do if item[name] ~= nil then branches = branches + 1 end end
    if item.not_equals ~= nil and item.equals ~= nil or branches > 1 then return label .. " has conflicting condition operators" end
    local then_items, then_error = sequence(item["then"], label .. ".then", M.MAX_TEMPLATE_ITEMS)
    if not then_items then return then_error end
    if item["else"] ~= nil then
        local else_items, else_error = sequence(item["else"], label .. ".else", M.MAX_TEMPLATE_ITEMS)
        if not else_items then return else_error end
        for index, child in ipairs(else_items) do
            local child_error = validate_template(child, label .. ".else[" .. tostring(index) .. "]", depth + 1)
            if child_error then return child_error end
        end
    end
    for index, child in ipairs(then_items) do
        local child_error = validate_template(child, label .. ".then[" .. tostring(index) .. "]", depth + 1)
        if child_error then return child_error end
    end
    return nil
end

local function validate_template_record(value: unknown, label: string): string?
    local item, object_error = object(value, label)
    if not item then return object_error end
    local extra = bounds.fields(item, {"argv", "stdin", "stdin_json", "stdin_when_any", "stdin_eof", "session_end", "readiness", "provider_home_private", "login"})
    if extra then return label .. ": " .. extra end
    local argv, argv_error = sequence(item.argv, label .. ".argv", M.MAX_TEMPLATE_ITEMS)
    if not argv then return argv_error end
    for index, token in ipairs(argv) do
        local token_error = validate_template(token, label .. ".argv[" .. tostring(index) .. "]", 0)
        if token_error then return token_error end
    end
    if item.stdin ~= nil then
        local stdin_error = validate_template(item.stdin, label .. ".stdin", 0)
        if stdin_error then return stdin_error end
    end
    if item.stdin_json ~= nil and type(item.stdin_json) ~= "table" then return label .. ".stdin_json must be an object or array" end
    if item.stdin_when_any ~= nil then
        local conditions, condition_error = sequence(item.stdin_when_any, label .. ".stdin_when_any", 8)
        if not conditions or #conditions == 0 then return condition_error or (label .. ".stdin_when_any is empty") end
        for _, field in ipairs(conditions) do if not bounds.id(field) then return label .. ".stdin_when_any has an invalid field" end end
    end
    if item.stdin_eof ~= nil and type(item.stdin_eof) ~= "boolean" then return label .. ".stdin_eof must be boolean" end
    if item.provider_home_private ~= nil and type(item.provider_home_private) ~= "boolean" then return label .. ".provider_home_private must be boolean" end
    if item.login ~= nil and type(item.login) ~= "boolean" then return label .. ".login must be boolean" end
    for _, name in ipairs({"session_end", "readiness"}) do
        if item[name] ~= nil and not bounds.text(item[name], 128) then return label .. "." .. name .. " must be bounded text" end
    end
    return nil
end

local function check_reference(value: unknown, fields: Object, label: string): string?
    local name = bounds.id(value)
    if not name then return label .. " is not an identifier" end
    local short = name:match("^provider%.options%.(.+)$") or name:match("^provider%.(.+)$") or name
    if fields[short] ~= true then return label .. " names undeclared field " .. name end
    return nil
end

local function check_format_references(value: string, fields: Object, label: string): string?
    for name in value:gmatch("{([^{}]+)}") do
        local reference_error = check_reference(name, fields, label .. " placeholder")
        if reference_error then return reference_error end
    end
    local unparsed = value:gsub("{[A-Za-z_][A-Za-z0-9_]*}", "")
    if unparsed:find("[{}]") then return label .. " contains a malformed field placeholder" end
    return nil
end

local function validate_template_references(value: unknown, label: string, fields: Object, flags: Object, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the reference nesting bound" end
    if type(value) ~= "table" then return nil end
    local item = bounds.object(value)
    if not item then
        local values, values_error = sequence(value, label, M.MAX_TEMPLATE_ITEMS)
        if not values then return values_error end
        for index, child in ipairs(values) do
            local child_error = validate_template_references(child, label .. "[" .. tostring(index) .. "]", fields, flags, depth + 1)
            if child_error then return child_error end
        end
        return nil
    end
    if item.render ~= nil then
        local reference_error = check_reference(item.render, fields, label .. ".render")
        if reference_error then return reference_error end
    end
    if item.field ~= nil then
        local reference_error = check_reference(item.field, fields, label .. ".field")
        if reference_error then return reference_error end
    end
    if item["if"] ~= nil then
        local reference_error = check_reference(item["if"], fields, label .. ".if")
        if reference_error then return reference_error end
    end
    for _, name in ipairs({"if_any", "if_none"}) do
        if item[name] ~= nil then
            local names, names_error = sequence(item[name], label .. "." .. name, 16)
            if not names then return names_error end
            for _, candidate in ipairs(names) do
                local reference_error = check_reference(candidate, fields, label .. "." .. name)
                if reference_error then return reference_error end
            end
        end
    end
    if item.format ~= nil then
        local format = bounds.text(item.format, 256)
        if not format then return label .. ".format is invalid" end
        local format_error = check_format_references(format, fields, label .. ".format")
        if format_error then return format_error end
    end
    if item.option ~= nil then
        local option = bounds.id(item.option)
        if not option or flags[option] == nil then return label .. ".option names an undeclared flag" end
    end
    if item.join ~= nil then
        local join = bounds.object(item.join)
        if not join then return label .. ".join is malformed" end
        local join_error = check_reference(join.field, fields, label .. ".join.field")
        if join_error then return join_error end
    end
    for _, name in ipairs({"then", "else"}) do
        if item[name] ~= nil then
            local branch_error = validate_template_references(item[name], label .. "." .. name, fields, flags, depth + 1)
            if branch_error then return branch_error end
        end
    end
    return nil
end

local function validate_json_references(value: unknown, label: string, fields: Object, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the JSON template nesting bound" end
    if type(value) ~= "table" then return nil end
    local item = bounds.object(value)
    if item and item.field ~= nil then
        if bounds.fields(item, {"field"}) then return label .. " field template is malformed" end
        return check_reference(item.field, fields, label .. ".field")
    end
    for key, child in pairs(value) do
        local child_error = validate_json_references(child, label .. "." .. tostring(key), fields, depth + 1)
        if child_error then return child_error end
    end
    return nil
end

local function flag_options(value: unknown, output: {[string]: boolean}, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH or type(value) ~= "table" then return nil end
    local item = bounds.object(value)
    if item then
        if item.option ~= nil then
            local option = bounds.id(item.option)
            if not option then return "CLI descriptor flag option reference is malformed" end
            output[option] = true
        end
        for _, name in ipairs({"then", "else"}) do
            if item[name] ~= nil then
                local branch_error = flag_options(item[name], output, depth + 1)
                if branch_error then return branch_error end
            end
        end
    else
        for _, child in ipairs(value) do
            local child_error = flag_options(child, output, depth + 1)
            if child_error then return child_error end
        end
    end
    return nil
end

local function validate_flag_graph(flags: Object): string?
    local visiting: {[string]: boolean} = {}
    local visited: {[string]: boolean} = {}
    local function visit(name: string): string?
        if visiting[name] then return "CLI descriptor flag dependency cycle includes " .. name end
        if visited[name] then return nil end
        visiting[name] = true
        local flag = bounds.object(flags[name]) or {}
        local dependencies: {[string]: boolean} = {}
        local collect_error = flag_options(flag.argv, dependencies, 0)
        if collect_error then return collect_error end
        for dependency in pairs(dependencies) do
            if flags[dependency] == nil then return "CLI descriptor flag " .. name .. " references an undeclared flag " .. dependency end
            local dependency_error = visit(dependency)
            if dependency_error then return dependency_error end
        end
        visiting[name] = nil
        visited[name] = true
        return nil
    end
    for name in pairs(flags) do
        local cycle_error = visit(name)
        if cycle_error then return cycle_error end
    end
    return nil
end

function M.decode(value: unknown): (Descriptor?, string?)
    local item, object_error = object(value, "CLI descriptor")
    if not item then return nil, object_error end
    local extra = bounds.fields(item, {"schema_revision", "provider", "executable", "version_probe", "login_evidence", "platform", "codec", "json_paths", "argv_templates", "options", "flags", "provider_home", "configure", "capabilities"})
    if extra then return nil, "CLI descriptor: " .. extra end
    if item.schema_revision ~= M.SCHEMA then return nil, "CLI descriptor schema_revision is unsupported" end
    local provider, executable, codec, configure = bounds.id(item.provider), bounds.id(item.executable), bounds.member(item.codec, M.CODECS), bounds.id(item.configure)
    if not provider or not executable or not codec or not configure then return nil, "CLI descriptor identity is invalid" end

    local probe, probe_error = object(item.version_probe, "CLI descriptor.version_probe")
    if not probe then return nil, probe_error end
    if bounds.fields(probe, {"argv", "pattern"}) then return nil, "CLI descriptor.version_probe has unknown fields" end
    local probe_argv, argv_error = sequence(probe.argv, "CLI descriptor.version_probe.argv", 8)
    if not probe_argv or #probe_argv == 0 then return nil, argv_error or "CLI descriptor.version_probe.argv is empty" end
    for _, arg in ipairs(probe_argv) do if not bounds.text(arg, 128) then return nil, "CLI descriptor.version_probe.argv contains invalid text" end end
    if probe.pattern ~= nil and (not bounds.text(probe.pattern, 128) or probe.pattern == "") then return nil, "CLI descriptor.version_probe.pattern is invalid" end

    local login, login_error = login_evidence.decode(item.login_evidence)
    if not login then return nil, "CLI descriptor.login_evidence: " .. tostring(login_error) end

    local platform, platform_error = object(item.platform, "CLI descriptor.platform")
    if not platform then return nil, platform_error end
    if bounds.fields(platform, {"os", "arch"}) then return nil, "CLI descriptor.platform has unknown fields" end
    for _, name in ipairs({"os", "arch"}) do
        local values, values_error = sequence(platform[name], "CLI descriptor.platform." .. name, 16)
        if not values or #values == 0 then return nil, values_error or ("CLI descriptor.platform." .. name .. " is empty") end
        for _, candidate in ipairs(values) do if not bounds.id(candidate) then return nil, "CLI descriptor.platform." .. name .. " contains an invalid value" end end
    end

    local paths, paths_error = object(item.json_paths, "CLI descriptor.json_paths")
    if not paths then return nil, paths_error end
    if bounds.fields(paths, {"resume_id", "result_text", "errors", "usage"}) then return nil, "CLI descriptor.json_paths has unknown fields" end
    for _, name in ipairs({"resume_id", "result_text", "errors", "usage"}) do
        if paths[name] ~= nil then
            local path, path_error = sequence(paths[name], "CLI descriptor.json_paths." .. name, 12)
            if not path then
                if type(paths[name]) ~= "string" or (paths[name]) == "" or (paths[name]):find("[%c%z]") then return nil, path_error end
            else
                if #path == 0 then return nil, "CLI descriptor.json_paths." .. name .. " is empty" end
                for _, segment in ipairs(path) do if not bounds.id(segment) then return nil, "CLI descriptor.json_paths." .. name .. " contains an invalid path segment" end end
            end
        end
    end

    local templates, templates_error = object(item.argv_templates, "CLI descriptor.argv_templates")
    if not templates then return nil, templates_error end
    if bounds.fields(templates, {"window", "first_turn", "resume"}) then return nil, "CLI descriptor.argv_templates has unknown fields" end
    for _, name in ipairs({"window", "first_turn", "resume"}) do
        local template_error = validate_template_record(templates[name], "CLI descriptor.argv_templates." .. name)
        if template_error then return nil, template_error end
    end

    local options, options_error = object(item.options, "CLI descriptor.options")
    if not options then return nil, options_error end
    if bounds.fields(options, {"profiles", "fields", "rules", "unknown_prefix"}) then return nil, "CLI descriptor.options has unknown fields" end
    if options.unknown_prefix ~= nil and not bounds.text(options.unknown_prefix, 64) then return nil, "CLI descriptor.options.unknown_prefix is invalid" end
    local profiles, profiles_error = sequence(options.profiles, "CLI descriptor.options.profiles", 16)
    if not profiles or #profiles == 0 then return nil, profiles_error or "CLI descriptor.options.profiles is empty" end
    for _, profile in ipairs(profiles) do if not bounds.id(profile) then return nil, "CLI descriptor.options.profiles contains an invalid profile" end end
    local fields, fields_error = object(options.fields, "CLI descriptor.options.fields")
    if not fields then return nil, fields_error end
    for name, raw_spec in pairs(fields) do
        if not bounds.id(name) then return nil, "CLI descriptor.options has an invalid field name" end
        if name == "profile_id" or name == "brief" then return nil, "CLI descriptor.options has a reserved field name" end
        local declaration, spec_error = object(raw_spec, "CLI descriptor.options." .. tostring(name))
        if not declaration then return nil, spec_error end
        if declaration.path ~= nil then
            if bounds.fields(declaration, {"path", "value_schema", "default", "label", "description", "section", "order", "contexts", "support", "render", "profiles", "transform", "pattern", "invalid", "unsupported", "forbid_option", "id", "group", "security_class", "capabilities", "ceiling", "dependencies", "conflicts", "trust", "config_aliases", "person_values", "consent_message"}) then return nil, "OptionSpec has unknown fields" end
            if declaration.id ~= name or not bounds.member(declaration.group, {"model/provider", "behavior", "access/trust", "tools/integrations", "advanced"})
                or not bounds.member(declaration.security_class, {"free", "person-only", "host-ceiling"}) then return nil, "OptionSpec identity and security classification are required" end
            for _, key in ipairs({"dependencies", "conflicts", "ceiling"}) do
                if declaration[key] ~= nil and not bounds.ids(declaration[key], true) then return nil, "OptionSpec " .. key .. " must be identifiers" end
            end
            if declaration.consent_message ~= nil and (not bounds.text(declaration.consent_message, 512) or declaration.person_values == nil) then
                return nil, "OptionSpec consent_message requires person_values and bounded text"
            end
            if declaration.person_values ~= nil then
                local values = bounds.array(declaration.person_values, 64)
                if not values or declaration.security_class ~= "host-ceiling" then return nil, "OptionSpec person_values requires a host ceiling and typed values" end
                for _, value in ipairs(values) do
                    if type(value) ~= "string" and type(value) ~= "boolean" and type(value) ~= "number" then return nil, "OptionSpec person_values must be scalars" end
                    local _, invalid = M.decode_option(name, declaration, value)
                    if invalid then return nil, invalid end
                end
            end
            if declaration.capabilities ~= nil then
                local modes = bounds.object(declaration.capabilities)
                if not modes then return nil, "OptionSpec capabilities must be a map" end
                for _, rights in pairs(modes) do if not bounds.ids(rights, true) then return nil, "OptionSpec capabilities must contain rights" end end
            end
            if declaration.config_aliases ~= nil then
                local aliases = bounds.array(declaration.config_aliases, 8)
                if not aliases then return nil, "OptionSpec config aliases must be an array" end
                for _, raw in ipairs(aliases) do
                    local alias = bounds.object(raw)
                    if not alias or bounds.fields(alias, {"format", "path"}) or not bounds.member(alias.format, {"json", "toml"}) or not bounds.ids(alias.path, true) then return nil, "OptionSpec config alias is invalid" end
                end
            end
            if declaration.trust ~= nil then
                local trust = bounds.object(declaration.trust)
                if not trust or bounds.fields(trust, {"file", "format", "key", "value", "flag", "repository_root", "unsupported", "project_config"}) then return nil, "OptionSpec trust mapping is malformed" end
                if trust.project_config ~= nil then
                    local paths = bounds.ids(trust.project_config, true)
                    if not paths then return nil, "Trust project configuration paths are invalid" end
                    for _, path in ipairs(paths) do if not safe_relative(path) then return nil, "Trust project configuration path escapes workdir" end end
                end
                if declaration.security_class ~= "person-only" or declaration.default ~= "ask" then return nil, "Folder trust requires person consent and defaults to ask" end
                if trust.unsupported ~= true then
                    if trust.flag ~= nil then
                        if not bounds.line(trust.flag, 128) or trust.file ~= nil then return nil, "Trust flag mapping is invalid" end
                    else
                        local file = bounds.text(trust.file, 256)
                        if not file or not safe_relative(file) or not bounds.member(trust.format, {"json", "toml"}) or not bounds.id(trust.key)
                            or (type(trust.value) ~= "string" and type(trust.value) ~= "boolean") then return nil, "Trust configuration mapping is invalid" end
                    end
                end
            end
            local path = bounds.line(declaration.path, 128)
            if not path or (path ~= "provider." .. name and path ~= "provider.options." .. name) then return nil, "OptionSpec path must name its canonical provider field" end
            local schema = bounds.object(declaration.value_schema)
            if not schema or bounds.fields(schema, {"type", "enum", "format", "items", "maxItems", "maxLength", "maxProperties", "properties", "additionalProperties", "required", "minimum", "maximum"}) or not bounds.member(schema.type, {"string", "boolean", "array", "object", "number", "integer"}) then return nil, "OptionSpec value_schema is invalid" end
            if not bounds.line(declaration.label, 80) or not bounds.line(declaration.description, 512) or not bounds.member(declaration.section, {"basic", "advanced"}) or not bounds.count(declaration.order) then return nil, "OptionSpec form declaration is invalid" end
            local contexts = bounds.ids(declaration.contexts, true)
            if not contexts or #contexts == 0 then return nil, "OptionSpec contexts are invalid" end
            for _, context in ipairs(contexts) do if not bounds.member(context, {"window", "first_turn", "resume"}) then return nil, "OptionSpec context is invalid" end end
            local support = bounds.object(declaration.support)
            if not support or bounds.fields(support, {"version_range", "help_probe", "config_schema_ref"}) then return nil, "OptionSpec support is invalid" end
            if support.version_range ~= nil then
                local version = bounds.line(support.version_range, 32)
                if not version or not version:match("^>=[0-9]+%.[0-9]+%.[0-9]+$") then return nil, "OptionSpec version_range is invalid" end
            end
            if support.config_schema_ref ~= nil and not bounds.id(support.config_schema_ref) then return nil, "OptionSpec config schema reference is invalid" end
            if support.help_probe ~= nil then
                local help = bounds.object(support.help_probe)
                local args = help and sequence(help.argv, "OptionSpec help argv", 8)
                local flag = help and bounds.line(help.flag, 128)
                if not help or bounds.fields(help, {"argv", "flag"}) or not args or #args == 0 or not flag or flag:sub(1, 1) ~= "-" then return nil, "OptionSpec help probe is invalid" end
                for _, arg in ipairs(args) do if not bounds.line(arg, 128) then return nil, "OptionSpec help argument is invalid" end end
            end
            local renders, renders_error = sequence(declaration.render, "OptionSpec render", 8)
            if not renders then return nil, renders_error end
            for _, raw_render in ipairs(renders) do
                local render = bounds.object(raw_render)
                if not render or not bounds.member(render.kind, {"argv", "config", "env"}) then return nil, "OptionSpec render is invalid" end
                local render_contexts = bounds.ids(render.contexts, true)
                if not render_contexts or #render_contexts == 0 then return nil, "OptionSpec render contexts are invalid" end
                for _, context in ipairs(render_contexts) do if not bounds.member(context, contexts) then return nil, "OptionSpec render context is undeclared" end end
                if render.kind == "argv" then
                    if bounds.fields(render, {"kind", "contexts", "tokens"}) then return nil, "OptionSpec argv render has unknown fields" end
                    local tokens, token_error = sequence(render.tokens, "OptionSpec tokens", M.MAX_TEMPLATE_ITEMS)
                    if not tokens then return nil, token_error end
                    for _, token in ipairs(tokens) do local err = validate_template(token, "OptionSpec token", 0); if err then return nil, err end end
                elseif render.kind == "config" then
                    if bounds.fields(render, {"kind", "contexts", "file", "format", "path", "merge", "value"}) then return nil, "OptionSpec config render has unknown fields" end
                    local key_path = sequence(render.path, "OptionSpec configuration path", 12)
                    local value = bounds.object(render.value)
                    if not key_path or not value or bounds.fields(value, {"field", "literal"}) or (value.literal == nil and value.field ~= declaration.path and value.field ~= "provider.system_prompt_files") or (value.literal ~= nil and (type(value.literal) ~= "string" or value.field ~= nil)) then return nil, "OptionSpec config value must name its canonical field" end
                    for _, key in ipairs(key_path) do if not bounds.id(key) then return nil, "OptionSpec config path is invalid" end end
                    local file = bounds.line(render.file, 512)
                    if not file or not safe_relative(file) or not bounds.member(render.format, {"json", "toml", "text"}) or not bounds.member(render.merge, {"set", "append"}) then return nil, "OptionSpec config render is invalid" end
                else
                    if bounds.fields(render, {"kind", "contexts", "name", "value"}) then return nil, "OptionSpec environment render has unknown fields" end
                    local name = bounds.line(render.name, 128)
                    local value = bounds.object(render.value)
                    if not name or not name:match("^[A-Z][A-Z0-9_]*$") or name == "HOME" or name == "PATH" or name:match("^BEE_") or name:match("_HOME$") or not value or bounds.fields(value, {"field", "literal"}) or (value.literal ~= nil and (type(value.literal) ~= "string" or value.field ~= nil)) or (value.literal == nil and value.field ~= declaration.path and value.field ~= "provider.env." .. name) then return nil, "OptionSpec environment render is invalid" end
                end
            end
        elseif bounds.fields(declaration, {"type", "values", "default", "max", "profiles", "transform", "pattern", "invalid", "unsupported", "forbid_option"}) then return nil, "Runtime option has unknown fields" end
        local spec = M.runtime_spec(declaration)
        if not bounds.member(spec.type, {"enum", "boolean", "id", "model", "duration", "ids", "codex_profile", "text", "json"}) then return nil, "CLI descriptor.options." .. tostring(name) .. ".type is invalid" end
        if spec.type == "enum" and spec.values == nil then return nil, "CLI descriptor.options." .. tostring(name) .. ".values is required for an enum" end
        if spec.values ~= nil then
            local values, values_error = sequence(spec.values, "CLI descriptor.options." .. tostring(name) .. ".values", 32)
            if not values or #values == 0 then return nil, values_error or "CLI descriptor option values are empty" end
            for _, candidate in ipairs(values) do if not bounds.text(candidate, 128) then return nil, "CLI descriptor option value is invalid" end end
        end
        if spec.max ~= nil and not bounds.count(spec.max) then return nil, "CLI descriptor option max is invalid" end
        if spec.profiles ~= nil then
            local supported, supported_error = sequence(spec.profiles, "CLI descriptor option profiles", 16)
            if not supported then return nil, supported_error end
            for _, candidate in ipairs(supported) do
                if not bounds.id(candidate) or not bounds.member(candidate, profiles) then return nil, "CLI descriptor option profile is invalid" end
            end
        end
        if spec.transform ~= nil and not bounds.member(spec.transform, {"presence", "sorted"}) then return nil, "CLI descriptor option transform is invalid" end
        if spec.forbid_option ~= nil and type(spec.forbid_option) ~= "boolean" then return nil, "CLI descriptor option forbid_option must be boolean" end
        for _, name in ipairs({"pattern", "invalid", "unsupported"}) do
            if spec[name] ~= nil and not bounds.text(spec[name], 256) then return nil, "CLI descriptor option " .. name .. " is invalid" end
        end
        if spec.default ~= nil then
            local _, default_error = M.decode_option(tostring(name), spec, spec.default)
            if default_error then return nil, "CLI descriptor.options." .. tostring(name) .. ".default: " .. default_error end
            if declaration.capabilities ~= nil then
                local modes = bounds.object(declaration.capabilities) or {}
                local rights = bounds.ids(modes[tostring(spec.default)], true)
                local ceiling = bounds.ids(declaration.ceiling, true)
                if not rights or not ceiling then return nil, "OptionSpec default capabilities are undeclared" end
                for _, right in ipairs(rights) do if not bounds.member(right, ceiling) then return nil, "OptionSpec default exceeds its ceiling" end end
            end
        end
    end
    for name, raw in pairs(fields) do
        local field = bounds.object(raw) or {}
        for _, kind in ipairs({"dependencies", "conflicts"}) do
            for _, target in ipairs(bounds.ids(field[kind], true) or {}) do
                if target == name or fields[target] == nil then return nil, "OptionSpec " .. kind .. " must name another declared option" end
            end
        end
    end
    local rules, rules_error = sequence(options.rules or {}, "CLI descriptor.options.rules", 32)
    if not rules then return nil, rules_error end
    for index, raw_rule in ipairs(rules) do
        local rule, rule_error = object(raw_rule, "CLI descriptor.options.rules[" .. tostring(index) .. "]")
        if not rule then return nil, rule_error end
        if bounds.fields(rule, {"kind", "field", "fields", "profile", "values", "message", "other"}) then return nil, "CLI descriptor option rule has unknown fields" end
        if not bounds.member(rule.kind, {"profile_fields", "values", "requires_empty", "forbid_pair", "forbid_nonempty"}) then return nil, "CLI descriptor option rule kind is invalid" end
        if rule.message ~= nil and not bounds.text(rule.message, 256) then return nil, "CLI descriptor option rule message is invalid" end
        if rule.profile ~= nil and not bounds.member(rule.profile, profiles) then return nil, "CLI descriptor option rule profile is undeclared" end
        if rule.kind == "profile_fields" then
            local rule_fields, rule_fields_error = sequence(rule.fields, "CLI descriptor profile_fields.fields", 32)
            if not rule_fields or #rule_fields == 0 then return nil, rule_fields_error or "CLI descriptor profile_fields.fields is empty" end
            for _, field in ipairs(rule_fields) do
                if not bounds.id(field) or fields[field] == nil then return nil, "CLI descriptor profile_fields names an undeclared option" end
            end
        elseif rule.kind == "values" then
            if not bounds.id(rule.field) or fields[rule.field] == nil then return nil, "CLI descriptor values rule names an undeclared option" end
            local rule_values, rule_values_error = sequence(rule.values, "CLI descriptor values rule.values", 32)
            if not rule_values or #rule_values == 0 then return nil, rule_values_error or "CLI descriptor values rule is empty" end
            for _, value in ipairs(rule_values) do if not bounds.text(value, 128) then return nil, "CLI descriptor values rule has an invalid value" end end
        elseif rule.kind == "requires_empty" or rule.kind == "forbid_pair" then
            local field = bounds.id(rule.field)
            if not field or (field ~= "brief" and fields[field] == nil) or not bounds.id(rule.other) or fields[rule.other] == nil then
                return nil, "CLI descriptor option rule names an undeclared option"
            end
        elseif rule.kind == "forbid_nonempty" and (not bounds.id(rule.field) or fields[rule.field] == nil) then
            return nil, "CLI descriptor option rule names an undeclared option"
        end
    end

    local flags, flags_error = object(item.flags, "CLI descriptor.flags")
    if not flags then return nil, flags_error end
    if bounds.fields(flags, {"permission"}) then return nil, "CLI descriptor.flags has unknown fields" end
    for name, raw_flag in pairs(flags) do
        local flag, flag_error = object(raw_flag, "CLI descriptor.flags." .. tostring(name))
        if not flag then return nil, flag_error end
        if bounds.fields(flag, {"field", "argv", "emit_default"}) then return nil, "CLI descriptor.flags." .. tostring(name) .. " has unknown fields" end
        if not bounds.id(flag.field) or fields[flag.field] == nil or type(flag.emit_default) ~= "boolean" then return nil, "CLI descriptor.flags." .. tostring(name) .. " is malformed or names an undeclared option" end
        local flag_argv, flag_argv_error = sequence(flag.argv, "CLI descriptor.flags." .. tostring(name) .. ".argv", 8)
        if not flag_argv or #flag_argv == 0 then return nil, flag_argv_error or "CLI descriptor flag argv is empty" end
        for index, token in ipairs(flag_argv) do
            local token_error = validate_template(token, "CLI descriptor.flags." .. tostring(name) .. ".argv[" .. tostring(index) .. "]", 0)
            if token_error then return nil, token_error end
        end
    end

    local home, home_error = object(item.provider_home, "CLI descriptor.provider_home")
    if not home then return nil, home_error end
    if bounds.fields(home, {"variable", "directory", "extra_variables", "files", "required_profile_file"}) then return nil, "CLI descriptor.provider_home has unknown fields" end
    if home.variable ~= nil and not bounds.id(home.variable) then return nil, "CLI descriptor.provider_home.variable is invalid" end
    if home.directory ~= nil and (not bounds.text(home.directory, 128) or not safe_relative(home.directory)) then return nil, "CLI descriptor.provider_home.directory is invalid" end
    local extra_variables, extra_error = sequence(home.extra_variables or {}, "CLI descriptor.provider_home.extra_variables", 8)
    if not extra_variables then return nil, extra_error end
    for _, raw_environment in ipairs(extra_variables) do
        local environment, environment_error = object(raw_environment, "CLI descriptor.provider_home.extra_variables item")
        if not environment then return nil, environment_error end
        if bounds.fields(environment, {"variable", "directory"}) or not bounds.id(environment.variable)
            or not bounds.text(environment.directory, 128) or not safe_relative(environment.directory) then return nil, "CLI descriptor.provider_home.extra_variables item is invalid" end
    end
    local home_files, files_error = sequence(home.files, "CLI descriptor.provider_home.files", 16)
    if not home_files then return nil, files_error end
    for _, raw_file in ipairs(home_files) do
        local file, file_error = object(raw_file, "CLI descriptor.provider_home.files item")
        if not file then return nil, file_error end
        if bounds.fields(file, {"source_path", "path", "kind", "optional", "write_back", "container_content", "container_omit"}) then return nil, "CLI descriptor.provider_home.files item has unknown fields" end
        if file.container_omit ~= nil and (file.kind ~= "config" or not bounds.ids(file.container_omit, true) or #(bounds.ids(file.container_omit, true) or {}) > 16) then return nil, "container_omit requires config keys" end
        if file.container_content ~= nil and (file.kind ~= "config" or not bounds.text(file.container_content, 8192)) then return nil, "container_content requires bounded config text" end
        if file.source_path ~= nil and (not bounds.text(file.source_path, 512) or not safe_relative(file.source_path)) then return nil, "CLI descriptor.provider_home source path is invalid" end
        if not bounds.text(file.path, 512) or not safe_relative(file.path) or not bounds.member(file.kind, {"login", "config", "state"})
            or type(file.optional) ~= "boolean" or type(file.write_back) ~= "boolean" then return nil, "CLI descriptor.provider_home file is invalid" end
    end
    if home.required_profile_file ~= nil then
        local profile_file, profile_error = object(home.required_profile_file, "CLI descriptor.provider_home.required_profile_file")
        if not profile_file then return nil, profile_error end
        if bounds.fields(profile_file, {"field", "variable", "path_template", "default_directory", "window_only"})
            or not bounds.id(profile_file.field) or not bounds.id(profile_file.variable)
            or not bounds.text(profile_file.path_template, 256) or not safe_relative(profile_file.path_template)
            or (profile_file.default_directory ~= nil and (not bounds.text(profile_file.default_directory, 128) or not safe_relative(profile_file.default_directory)))
            or type(profile_file.window_only) ~= "boolean" then return nil, "CLI descriptor provider-home profile file is invalid" end
    end

    local declared_fields: Object = {profile_id = true, brief = true, system_prompt_file = true}
    for name in pairs(fields) do declared_fields[name] = true end
    local visiting: {[string]: boolean} = {}
    local visited: {[string]: boolean} = {}
    local function visit_render(name: string): string?
        if visiting[name] then return "OptionSpec render dependency cycle includes " .. name end
        if visited[name] then return nil end
        visiting[name] = true
        local declaration = bounds.object(fields[name]) or {}
        local renders = type(declaration.render) == "table" and declaration.render or {}
        local function visit_tokens(value: unknown): string?
            if type(value) ~= "table" then return nil end
            local item = bounds.object(value)
            if item and item.render ~= nil then
                local target = bounds.id(item.render)
                if not target or fields[target] == nil then return "OptionSpec render reference is undeclared" end
                return visit_render(target)
            end
            for _, child in pairs(value) do
                local err = visit_tokens(child)
                if err then return err end
            end
            return nil
        end
        for _, raw_render in ipairs(renders) do
            local render = bounds.object(raw_render)
            if render and render.kind == "argv" then
                local reference_error = validate_template_references(render.tokens, "OptionSpec argv", declared_fields, flags, 0)
                if reference_error then return reference_error end
                local cycle_error = visit_tokens(render.tokens)
                if cycle_error then return cycle_error end
            end
        end
        visiting[name] = nil; visited[name] = true
        return nil
    end
    for name in pairs(fields) do
        local render_error = visit_render(name)
        if render_error then return nil, render_error end
    end

    for _, name in ipairs({"window", "first_turn", "resume"}) do
        local template = bounds.object(templates[name]) or {}
        local template_error = validate_template_references(template.argv, "CLI descriptor.argv_templates." .. name .. ".argv", declared_fields, flags, 0)
        if template_error then return nil, template_error end
        if template.stdin ~= nil then
            template_error = validate_template_references(template.stdin, "CLI descriptor.argv_templates." .. name .. ".stdin", declared_fields, flags, 0)
            if template_error then return nil, template_error end
        end
        if template.stdin_json ~= nil then
            template_error = validate_json_references(template.stdin_json, "CLI descriptor.argv_templates." .. name .. ".stdin_json", declared_fields, 0)
            if template_error then return nil, template_error end
        end
        if template.stdin_when_any ~= nil then
            local conditions, condition_error = sequence(template.stdin_when_any, "CLI descriptor.argv_templates." .. name .. ".stdin_when_any", 8)
            if not conditions then return nil, condition_error end
            for _, field in ipairs(conditions) do
                local reference_error = check_reference(field, declared_fields, "CLI descriptor.argv_templates." .. name .. ".stdin_when_any")
                if reference_error then return nil, reference_error end
            end
        end
    end
    for name, raw_flag in pairs(flags) do
        local flag = bounds.object(raw_flag) or {}
        local reference_error = check_reference(flag.field, declared_fields, "CLI descriptor.flags." .. tostring(name) .. ".field")
        if reference_error then return nil, reference_error end
        local flag_error = validate_template_references(flag.argv, "CLI descriptor.flags." .. tostring(name) .. ".argv", declared_fields, flags, 0)
        if flag_error then return nil, flag_error end
    end
    local cycle_error = validate_flag_graph(flags)
    if cycle_error then return nil, cycle_error end
    if home.required_profile_file ~= nil then
        local profile_file = bounds.object(home.required_profile_file) or {}
        local reference_error = check_reference(profile_file.field, declared_fields, "CLI descriptor.provider_home.required_profile_file.field")
        if reference_error then return nil, reference_error end
        local path_template = bounds.text(profile_file.path_template, 256) or ""
        local template_error = check_format_references(path_template, declared_fields, "CLI descriptor.provider_home.required_profile_file.path_template")
        if template_error then return nil, template_error end
    end

    local declared, capability_error = capabilities(item.capabilities)
    if not declared then return nil, capability_error end
    return {schema_revision = M.SCHEMA, provider = provider, executable = executable, version_probe = probe,
        login_evidence = login, platform = platform, codec = codec, json_paths = paths, argv_templates = templates,
        options = options, flags = flags, provider_home = home, configure = configure, capabilities = declared}, nil
end

function M.permission_answer(item: Descriptor, context: string): PermissionAnswer
    local declared = item.capabilities
    if declared then
        local selected: PermissionAnswer? = declared.permission_answers[context]
        if selected then return selected end
    end
    return {transport = "provider", reason = "No permission answer transport is declared for " .. context}
end

function M.find_provider(pinned: registry.Snapshot, provider: string): (Descriptor?, string?)
    local found, find_error = pinned:find({["meta.type"] = M.TYPE})
    if find_error or not found then return nil, "CLI descriptors are unavailable" end
    local match: Descriptor? = nil
    for _, raw in ipairs(found) do
        local entry = bounds.object(raw)
        local meta = entry and bounds.object(entry.meta) or nil
        if entry and entry.kind == "registry.entry" and meta and meta.type == M.TYPE then
            local decoded, decode_error = M.decode(entry.data)
            if not decoded then return nil, tostring(decode_error or "CLI descriptor is invalid") end
            if decoded.provider == provider then
                if match then return nil, "multiple CLI descriptors name driver " .. provider end
                match = decoded
            end
        end
    end
    return match, nil
end

function M.load_from(pinned: registry.Snapshot, ref: string): (Descriptor?, string?)
    local id = bounds.id(ref)
    if not id then return nil, "CLI descriptor reference is invalid" end
    local raw, get_error = pinned:get(id)
    if get_error or not raw then return nil, "CLI descriptor " .. id .. " is unavailable" end
    local entry = bounds.object(raw)
    if not entry or entry.kind ~= "registry.entry" or bounds.id(entry.id) ~= id then return nil, "CLI descriptor registry entry is malformed" end
    local meta = bounds.object(entry.meta)
    if not meta or meta.type ~= M.TYPE then return nil, "registry entry is not a CLI descriptor" end
    local decoded, decode_error = M.decode(entry.data)
    if not decoded then return nil, id .. ": " .. tostring(decode_error) end
    return decoded, nil
end

function M.load(ref: string): (Descriptor?, string?)
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "CLI descriptor registry is unavailable" end
    return M.load_from(pinned, ref)
end

return M
