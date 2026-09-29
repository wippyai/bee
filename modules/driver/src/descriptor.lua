-- MIT. Strict decoder and registry reader for declarative external CLI drivers.
local bounds = require("bounds")
local registry = require("registry")
local M = {}
M.TYPE = "bee.driver.cli_descriptor"
M.SCHEMA = "bee.driver.cli-descriptor@1"
M.MAX_TEMPLATE_ITEMS = 128
M.MAX_TEMPLATE_DEPTH = 8
M.CODECS = {"claude-stream-json", "codex-jsonl", "opencode-json-events", "agy-stream-json", "grok-streaming-json", "muse-record-jsonl"}

type Object = {[string]: unknown}
type Descriptor = {
    schema_revision: string,
    provider: string,
    executable: string,
    version_probe: Object,
    login_evidence: Object,
    platform: Object,
    codec: string,
    json_paths: Object,
    argv_templates: Object,
    options: Object,
    flags: Object,
    provider_home: Object,
    configure: string,
}

local function object(value: unknown, label: string): (Object?, string?)
    local decoded = bounds.object(value)
    if not decoded then return nil, label .. " must be an object" end
    return decoded, nil
end

local function sequence(value: unknown, label: string, limit: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be an array" end
    local source = value :: {[unknown]: unknown}
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

local function validate_template(value: unknown, label: string, depth: integer): string?
    if depth > M.MAX_TEMPLATE_DEPTH then return label .. " exceeds the template nesting bound" end
    if type(value) == "string" then
        if value:find("%$%{[^}]+%}") or value:find("%$[A-Za-z_][A-Za-z0-9_]*") then return nil end
        return nil
    end
    if type(value) ~= "table" then return label .. " contains an invalid template node" end
    local item = value :: Object
    local fields = bounds.fields(item, {"field", "format", "if", "if_any", "if_none", "equals", "not_equals", "starts_with", "then", "else", "option", "join"})
    if fields then return label .. ": " .. fields end
    local selected = 0
    for _, name in ipairs({"field", "format", "if", "if_any", "if_none", "option", "join"}) do if item[name] ~= nil then selected = selected + 1 end end
    if selected ~= 1 then return label .. " must select one template operation" end
    if item.field ~= nil then
        if not bounds.id(item.field) or bounds.fields(item, {"field"}) then return label .. " field reference is malformed" end
        return nil
    end
    if item.format ~= nil then
        if type(item.format) ~= "string" or item.format == "" or bounds.fields(item, {"format"}) then return label .. " format is malformed" end
        return nil
    end
    if item.option ~= nil then
        if not bounds.member(item.option, {"permission", "turn_budget"}) or bounds.fields(item, {"option"}) then return label .. " option reference is malformed" end
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

function M.decode(value: unknown): (Descriptor?, string?)
    local item, object_error = object(value, "CLI descriptor")
    if not item then return nil, object_error end
    local extra = bounds.fields(item, {"schema_revision", "provider", "executable", "version_probe", "login_evidence", "platform", "codec", "json_paths", "argv_templates", "options", "flags", "provider_home", "configure"})
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

    local login, login_error = object(item.login_evidence, "CLI descriptor.login_evidence")
    if not login then return nil, login_error end
    if bounds.fields(login, {"path", "command", "variable", "directory"}) then return nil, "CLI descriptor.login_evidence has unknown fields" end
    local login_path, login_command = bounds.text(login.path, 512), bounds.text(login.command, 128)
    if not login_path or not safe_relative(login_path) or not login_command or login_command == "" then return nil, "CLI descriptor.login_evidence is invalid" end
    if login.variable ~= nil and (not bounds.id(login.variable) or not login.variable:match("^[A-Z][A-Z0-9_]*$")) then return nil, "CLI descriptor.login_evidence.variable is invalid" end
    if login.directory ~= nil and (not bounds.text(login.directory, 128) or not safe_relative(login.directory)) then return nil, "CLI descriptor.login_evidence.directory is invalid" end

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
                if type(paths[name]) ~= "string" or (paths[name] :: string) == "" or (paths[name] :: string):find("[%c%z]") then return nil, path_error end
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
        local spec, spec_error = object(raw_spec, "CLI descriptor.options." .. tostring(name))
        if not spec then return nil, spec_error end
        if bounds.fields(spec, {"type", "values", "default", "max", "profiles", "transform", "pattern", "invalid", "unsupported", "forbid_option", "constant"}) then return nil, "CLI descriptor.options." .. tostring(name) .. " has unknown fields" end
        if not bounds.member(spec.type, {"enum", "boolean", "id", "model", "budget", "duration", "ids", "codex_profile"}) then return nil, "CLI descriptor.options." .. tostring(name) .. ".type is invalid" end
        if spec.values ~= nil then
            local values, values_error = sequence(spec.values, "CLI descriptor.options." .. tostring(name) .. ".values", 32)
            if not values or #values == 0 then return nil, values_error or "CLI descriptor option values are empty" end
            for _, candidate in ipairs(values) do if not bounds.text(candidate, 128) then return nil, "CLI descriptor option value is invalid" end end
        end
        if spec.max ~= nil and not bounds.count(spec.max) then return nil, "CLI descriptor option max is invalid" end
        if spec.profiles ~= nil then
            local supported, supported_error = sequence(spec.profiles, "CLI descriptor option profiles", 16)
            if not supported then return nil, supported_error end
            for _, candidate in ipairs(supported) do if not bounds.id(candidate) then return nil, "CLI descriptor option profile is invalid" end end
        end
        if spec.transform ~= nil and not bounds.member(spec.transform, {"presence", "sorted"}) then return nil, "CLI descriptor option transform is invalid" end
        if spec.forbid_option ~= nil and type(spec.forbid_option) ~= "boolean" then return nil, "CLI descriptor option forbid_option must be boolean" end
        if spec.constant ~= nil and not bounds.member(spec.constant, {"MAX_TURNS", "MAX_STEPS", "MAX_CONFIG_PROFILE_BYTES"}) then return nil, "CLI descriptor option constant is invalid" end
        for _, name in ipairs({"pattern", "invalid", "unsupported"}) do
            if spec[name] ~= nil and not bounds.text(spec[name], 256) then return nil, "CLI descriptor option " .. name .. " is invalid" end
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
    end

    local flags, flags_error = object(item.flags, "CLI descriptor.flags")
    if not flags then return nil, flags_error end
    if bounds.fields(flags, {"permission", "turn_budget"}) then return nil, "CLI descriptor.flags has unknown fields" end
    for name, raw_flag in pairs(flags) do
        local flag, flag_error = object(raw_flag, "CLI descriptor.flags." .. tostring(name))
        if not flag then return nil, flag_error end
        if bounds.fields(flag, {"field", "argv", "emit_default"}) then return nil, "CLI descriptor.flags." .. tostring(name) .. " has unknown fields" end
        if not bounds.id(flag.field) or type(flag.emit_default) ~= "boolean" then return nil, "CLI descriptor.flags." .. tostring(name) .. " is malformed" end
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
        if bounds.fields(file, {"source_path", "path", "kind", "optional", "write_back"}) then return nil, "CLI descriptor.provider_home.files item has unknown fields" end
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

    return item :: Descriptor, nil
end

function M.load(ref: string): (Descriptor?, string?)
    local id = bounds.id(ref)
    if not id then return nil, "CLI descriptor reference is invalid" end
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "CLI descriptor registry is unavailable" end
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

return M
