-- MIT. Typed driver configuration delivery under an empty callee scope.
local hash = require("hash")
local json = require("json")
local toml = require("toml")
local bounds = require("bounds")
local canonical = require("canonical")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local driver_resolver = require("driver_resolver")
local driver_types = require("types")
local instructions = require("instructions")
local M = {}
M.MAX_CONFIGURATION_BYTES = 8192
M.MAX_INSTRUCTIONS_BYTES = instructions.MAX_BYTES
M.MAX_DELIVERY_ARGUMENTS = 32
M.MAX_DELIVERY_ARGUMENT_BYTES = 16384
M.MAX_DELIVERY_FILES = 8
M.MAX_DELIVERY_FILE_BYTES = 24576
M.MAX_GATEWAY_TOOLS = 32
M.MAX_GATEWAY_HOOKS = 32
M.MAX_HOME_DIRECTORY_BYTES = 4096
M.MAX_ENDPOINT_BYTES = 512
M.GATEWAY_PROVIDER_REF = "bee:gateway_endpoint"
M.LOGIN_PROVIDER_REF = "bee:provider_login"
M.OPTIONS_PROVIDER_REF = "bee:profile_options"
M.INSTRUCTIONS_PROVIDER_REF = "bee:profile_instructions"
type Object = {[string]: unknown}
type SecretField = {path: {string}, environment: string, prefix: string}
type JsonOperation = {kind: "default" | "insert" | "append" | "set", path: {string}}
type Composition = {kind: "copy", base_path: string} | {kind: "toml_insert", base_path: string, path: {string}, append_text: boolean?} | {kind: "json_patch" | "toml_patch", base_path: string, operations: {JsonOperation}}
type Configuration = {secret_fields: {SecretField}?, composition: Composition?, revision: string, path: string, content: string, digest: string, provider_ref: string}
type InstructionBuilder = {func_id: string, args: {[string]: unknown}}
type GatewayInput = {endpoint: string, action_id: string, tools: {string}, hooks: {string}, token_environment: string, hook_token_environment: string?, hook_command: string?}
type Delivery = {environment: {[string]: string}?,arguments: {string}, files: {Configuration}, git_writable_roots_adapter: driver_types.GitWritableRootsAdapter?}
type Request = {option_values: Object?, context: string?,instructions_path: string?, instructions: string?, instruction_builder: InstructionBuilder?, provider_ref: string?, provider: Object?, gateway: GatewayInput?, home_directory: string?, private_home: boolean?, attempt_id: string?, fixture: boolean}

-- Profile guidance is separate from a turn brief and grants no authority.
M.instructions = instructions.decode
function M.endpoint(value: unknown, allow_loopback: boolean, field: string?): (string?, string?)
    local name = field or "endpoint"
    local url = bounds.text(value, M.MAX_ENDPOINT_BYTES)
    if not url or url == "" or url:find("%s") then return nil, name .. " must be one bounded URL" end
    local scheme, host, rest = url:match("^(https?)://([^/]+)(.*)$")
    if not scheme or not host then return nil, name .. " must be an http(s) URL with a host" end
    if rest:find("[?#]") then return nil, name .. " carries no query or fragment" end
    if scheme == "http" then
        if not allow_loopback then
            if name == "base_url" then return nil, "plain http is permitted only for the loopback fixture" end
            return nil, "plain http is permitted only for the 127.0.0.1 loopback fixture"
        end
        if not host:match("^127%.0%.0%.1:%d+$") then
            if name == "base_url" then return nil, "the loopback fixture endpoint must be 127.0.0.1 with a port" end
            return nil, "plain http is permitted only for the 127.0.0.1 loopback fixture"
        end
    end
    return url, nil
end
function M.instruction_builder(value: unknown): (InstructionBuilder?, string?)
    if value == nil then return nil, nil end
    local item = bounds.object(value)
    if not item then return nil, "instruction_builder must be an object" end
    local unexpected = bounds.fields(item, {"func_id", "args"})
    if unexpected then return nil, "instruction_builder: " .. unexpected end
    local func_id = bounds.id(item.func_id)
    if not func_id then return nil, "instruction_builder.func_id must be an identifier" end
    if item.args == nil then return nil, "instruction_builder.args is required" end
    local args = bounds.object(item.args)
    if not args then return nil, "instruction_builder.args must be an object" end
    local encoded, encode_error = canonical.encode(args)
    if not encoded then return nil, "instruction_builder.args is not canonical JSON: " .. tostring(encode_error) end
    if #encoded > M.MAX_INSTRUCTIONS_BYTES then return nil, "instruction_builder.args exceeds " .. tostring(M.MAX_INSTRUCTIONS_BYTES) .. " bytes" end
    return {func_id = func_id, args = args}, nil
end
local function environment_name(value: unknown, label: string): (string?, string?)
    local name = bounds.id(value)
    if not name or not name:match("^[A-Z][A-Z0-9_]*$") then return nil, label .. " must be an environment name" end
    return name, nil
end
local function decode_gateway(value: unknown): (GatewayInput?, string?)
    local item = bounds.object(value)
    if not item then return nil, "configuration request.gateway must be an object" end
    local unexpected = bounds.fields(item, {"endpoint", "action_id", "tools", "hooks", "token_environment", "hook_token_environment", "hook_command"})
    if unexpected then return nil, "configuration request.gateway: " .. unexpected end
    -- Gateway chooses and validates its listener before it constructs this
    -- host-selected configuration input. Driver only carries the bounded
    -- opaque endpoint to a provider's configuration renderer; it does not
    -- own network-address policy or gain a Gateway dependency.
    local endpoint = bounds.text(item.endpoint, 512)
    if not endpoint or endpoint == "" or endpoint:find("%c") then return nil, "configuration request.gateway.endpoint must be bounded text" end
    local action_id = bounds.id(item.action_id)
    if not action_id or action_id:find("[/?#%s]") then return nil, "configuration request.gateway.action_id is not a path segment" end
    local declared_tools = bounds.ids(item.tools, true)
    if not declared_tools or #declared_tools > M.MAX_GATEWAY_TOOLS then return nil, "configuration request.gateway.tools exceeds " .. tostring(M.MAX_GATEWAY_TOOLS) .. " tools or is invalid" end
    local tools: {string} = {}
    for index, tool in ipairs(declared_tools) do tools[index] = tool end
    local declared_hooks = bounds.ids(item.hooks, true)
    if not declared_hooks or #declared_hooks > M.MAX_GATEWAY_HOOKS then return nil, "configuration request.gateway.hooks exceeds " .. tostring(M.MAX_GATEWAY_HOOKS) .. " items" end
    if #declared_tools == 0 and #declared_hooks == 0 then return nil, "configuration request.gateway needs tools or hooks" end
    local hooks: {string} = {}
    for index, hook in ipairs(declared_hooks) do hooks[index] = hook end
    local token, token_error = environment_name(item.token_environment, "configuration request.gateway.token_environment")
    if not token then return nil, token_error end
    local hook_token: string? = nil
    if #hooks > 0 then
        hook_token, token_error = environment_name(item.hook_token_environment, "configuration request.gateway.hook_token_environment")
        if not hook_token then return nil, token_error end
        if hook_token == token then return nil, "configuration request.gateway hook and tool environments must differ" end
    elseif item.hook_token_environment ~= nil then return nil, "configuration request.gateway.hook_token_environment needs hooks" end
    local hook_command: string? = nil
    if item.hook_command ~= nil then
        hook_command = bounds.text(item.hook_command, M.MAX_HOME_DIRECTORY_BYTES)
        if #hooks == 0 or not hook_command or hook_command:sub(1, 1) ~= "/" or hook_command:find("%c") then
            return nil, "configuration request.gateway.hook_command requires hooks and an absolute bounded path"
        end
    end
    local result: GatewayInput = {endpoint = endpoint, action_id = action_id, tools = tools, hooks = hooks, token_environment = token, hook_token_environment = hook_token, hook_command = hook_command}
    return result, nil
end
function M.decode_request(value: unknown): (Request?, string?)
    local request = bounds.object(value)
    if not request then return nil, "configuration request must be an object" end
    local unexpected = bounds.fields(request, {"provider_ref", "provider", "gateway", "home_directory", "private_home", "attempt_id", "fixture", "instructions", "instruction_builder", "option_values", "context"})
    if unexpected then return nil, "configuration request: " .. unexpected end
    if type(request.fixture) ~= "boolean" then return nil, "configuration request.fixture must be a boolean" end
    local instructions, instructions_error = M.instructions(request.instructions)
    if instructions_error then return nil, instructions_error end
    local instruction_builder: InstructionBuilder? = nil
    if request.instruction_builder ~= nil then
        local builder_error: string?
        instruction_builder, builder_error = M.instruction_builder(request.instruction_builder)
        if not instruction_builder then return nil, builder_error end
    end
    local provider_ref: string? = nil
    local provider: Object? = nil
    if request.provider_ref ~= nil then
        provider_ref = bounds.id(request.provider_ref)
        if not provider_ref then return nil, "configuration request.provider_ref is not an identifier" end
        provider = bounds.object(request.provider)
        if not provider then return nil, "configuration request.provider must be an object when provider_ref is set" end
    elseif request.provider ~= nil then return nil, "configuration request.provider needs provider_ref" end
    local gateway: GatewayInput? = nil
    if request.gateway ~= nil then
        local gateway_error: string?
        gateway, gateway_error = decode_gateway(request.gateway)
        if not gateway then return nil, gateway_error end
    end
    if request.private_home ~= nil and type(request.private_home) ~= "boolean" then return nil, "private_home must be boolean" end
    local home_directory: string? = nil
    if request.home_directory ~= nil then
        home_directory = bounds.text(request.home_directory, M.MAX_HOME_DIRECTORY_BYTES)
        if not home_directory or home_directory == "" or home_directory:sub(1, 1) ~= "/" then return nil, "configuration request.home_directory must be an absolute bounded path" end
    end
    local attempt_id: string? = nil
    if request.attempt_id ~= nil then
        attempt_id = bounds.id(request.attempt_id)
        if not attempt_id then return nil, "configuration request.attempt_id is not an identifier" end
    end
    local private_home = request.private_home
    if private_home ~= nil and type(private_home) ~= "boolean" then return nil, "configuration request.private_home must be boolean" end
    local option_values = bounds.object(request.option_values)
    if request.option_values ~= nil and not option_values then return nil, "configuration option_values must be an object" end
    local context = request.context == nil and nil or bounds.member(request.context, {"window", "first_turn", "resume"})
    if request.context ~= nil and not context then return nil, "configuration context is invalid" end
    return {option_values = option_values or {}, context = context, instructions = instructions, instruction_builder = instruction_builder, provider_ref = provider_ref, provider = provider, gateway = gateway, home_directory = home_directory, private_home = private_home, attempt_id = attempt_id, fixture = request.fixture}, nil
end
local function sequence(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local list = value
    local count = 0
    local highest = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, label .. " must be a list" end
        count = count + 1
        if key > highest then highest = key end
    end
    if count ~= highest then return nil, label .. " must not have holes" end
    if count > maximum then return nil, label .. " exceeds " .. tostring(maximum) end
    for index = 1, count do
        if list[index] == nil then return nil, label .. " must not have holes" end
    end
    return list, nil
end
function M.decode_file(value: unknown): (Configuration?, string?)
    local item = bounds.object(value)
    if not item then return nil, "configuration must be an object" end
    local unexpected = bounds.fields(item, {"revision", "path", "content", "digest", "provider_ref", "secret_fields", "composition"})
    if unexpected then return nil, "configuration: " .. unexpected end
    local revision = bounds.id(item.revision)
    if not revision then return nil, "configuration.revision is not an identifier" end
    local path, path_error = bounds.subpath(item.path)
    if path_error then return nil, "configuration.path " .. path_error end
    if not path or path == "" then return nil, "configuration.path must be a nonempty safe relative path" end
    local content = bounds.text(item.content, M.MAX_CONFIGURATION_BYTES)
    local composition_object = bounds.object(item.composition)
    if not content or (content == "" and (not composition_object or composition_object.kind ~= "copy")) then return nil, "configuration.content must be bounded nonempty text" end
    local digest = bounds.id(item.digest)
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "configuration.digest must be a lowercase sha256 hex digest" end
    local actual, hash_error = hash.sha256(content)
    if hash_error or not actual then return nil, "configuration.digest could not be measured" end
    if digest ~= actual then return nil, "configuration.digest does not match content" end
    local provider_ref = bounds.id(item.provider_ref)
    if not provider_ref then return nil, "configuration.provider_ref is not an identifier" end
    local result: Configuration = {revision = revision, path = path, content = content, digest = digest, provider_ref = provider_ref}
    if item.composition ~= nil then
        local composition = bounds.object(item.composition)
        if not composition then return nil, "invalid configuration composition" end
        local base_path, base_error = bounds.subpath(composition.base_path)
        if base_error or not base_path or base_path == "" or base_path == path then
            return nil, "configuration composition base_path must be a distinct safe relative path"
        end
        if composition.kind == "copy" then
            if bounds.fields(composition, {"kind", "base_path"}) or content ~= "" then return nil, "copy composition requires empty content and a base path" end
            result.composition = {kind = "copy", base_path = base_path}
        elseif composition.kind == "toml_insert" then
            if bounds.fields(composition, {"kind", "base_path", "path", "append_text"}) or (composition.append_text ~= nil and type(composition.append_text) ~= "boolean") then return nil, "invalid configuration composition" end
            local raw_path, path_error = sequence(composition.path, "configuration composition path", 8)
            if not raw_path or #raw_path == 0 then return nil, path_error or "configuration composition path is empty" end
            local selected_path: {string} = {}
            for index, key in ipairs(raw_path) do
                local selected = bounds.text(key, 128)
                if not selected or selected == "" then return nil, "configuration composition path key " .. tostring(index) .. " is invalid" end
                selected_path[index] = selected
            end
            result.composition = {kind = "toml_insert", base_path = base_path, path = selected_path, append_text = composition.append_text == true}
        elseif composition.kind == "json_patch" or composition.kind == "toml_patch" then
            if bounds.fields(composition, {"kind", "base_path", "operations"}) then return nil, "invalid configuration composition" end
            local raw_operations, operations_error = sequence(composition.operations, "configuration composition operations", 16)
            if not raw_operations or #raw_operations == 0 then return nil, operations_error or "configuration composition operations are empty" end
            local operations: {JsonOperation} = {}
            local seen: {[string]: boolean} = {}
            for index, raw in ipairs(raw_operations) do
                local operation = bounds.object(raw)
                if not operation or bounds.fields(operation, {"kind", "path"}) then return nil, "invalid configuration composition operation " .. tostring(index) end
                local kind = operation.kind
                if kind ~= "default" and kind ~= "insert" and kind ~= "append" and kind ~= "set" then return nil, "invalid configuration composition operation " .. tostring(index) end
                local raw_path, operation_path_error = sequence(operation.path, "configuration composition operation path", 8)
                if not raw_path or #raw_path == 0 then return nil, operation_path_error or "configuration composition operation path is empty" end
                local operation_path: {string} = {}
                for path_index, key in ipairs(raw_path) do
                    local selected = bounds.text(key, 128)
                    if not selected or selected == "" then return nil, "configuration composition operation path key " .. tostring(path_index) .. " is invalid" end
                    operation_path[path_index] = selected
                end
                local identity = canonical.encode(operation_path)
                if not identity or seen[identity] then return nil, "duplicate configuration composition operation path" end
                for _, previous in ipairs(operations) do
                    local shared = math.min(#previous.path, #operation_path)
                    local prefix = true
                    for path_index = 1, shared do
                        if previous.path[path_index] ~= operation_path[path_index] then prefix = false break end
                    end
                    if prefix then return nil, "overlapping configuration composition operation paths" end
                end
                seen[identity] = true
                operations[index] = {kind = kind, path = operation_path}
            end
            result.composition = {kind = composition.kind, base_path = base_path, operations = operations}
        else
            return nil, "invalid configuration composition"
        end
    end
    if item.secret_fields ~= nil then
        local fields, fields_error = sequence(item.secret_fields, "configuration.secret_fields", 8)
        if not fields or #fields == 0 then return nil, fields_error or "configuration.secret_fields is empty" end
        local selected: {SecretField} = {}
        local seen: {[string]: boolean} = {}
        for _, value in ipairs(fields) do
            local field = bounds.object(value)
            if not field or bounds.fields(field, {"path", "environment", "prefix"}) then return nil, "invalid configuration secret field" end
            local keys = sequence(field.path, "configuration secret path", 8)
            if not keys or #keys == 0 then return nil, "invalid configuration secret path" end
            local path_keys: {string} = {}
            for _, key in ipairs(keys) do
                local text = bounds.text(key, 128)
                if not text or text == "" then return nil, "invalid configuration secret path key" end
                path_keys[#path_keys + 1] = text
            end
            local environment = environment_name(field.environment, "configuration secret environment")
            local prefix = bounds.text(field.prefix, 64)
            if not environment or prefix == nil then return nil, "invalid configuration secret environment or prefix" end
            local identity = canonical.encode(path_keys)
            if not identity or seen[identity] then return nil, "duplicate configuration secret path" end
            seen[identity] = true
            selected[#selected + 1] = {path = path_keys, environment = environment, prefix = prefix}
        end
        result.secret_fields = selected
    end
    return result, nil
end
function M.decode_delivery(value: unknown): (Delivery?, string?)
    local item = bounds.object(value)
    if not item then return nil, "delivery must be an object" end
    local unexpected = bounds.fields(item, {"arguments", "files", "environment"})
    if unexpected then return nil, "delivery: " .. unexpected end
    local environment: {[string]: string}? = nil
    if item.environment ~= nil then
        local values = bounds.object(item.environment)
        if not values then return nil, "delivery.environment must be an object" end
        environment = {}
        local count = 0
        for name, raw in pairs(values) do
            count = count + 1
            local value = bounds.text(raw, 4096)
            if count > 64 or not name:match("^[A-Z][A-Z0-9_]*$") or name == "HOME" or name == "PATH" or name:match("_HOME$") or name:match("^BEE_") or not value or value:find("%z") then return nil, "delivery.environment has an invalid or reserved variable" end
            environment[name] = value
        end
    end
    local arguments: {string} = {}
    local argument_bytes = 0
    local raw_arguments, arguments_error = sequence(item.arguments, "delivery.arguments", M.MAX_DELIVERY_ARGUMENTS)
    if not raw_arguments then return nil, arguments_error end
    for index, value in ipairs(raw_arguments) do
        if type(value) ~= "string" then return nil, "delivery.arguments[" .. tostring(index) .. "] must be text" end
        if (value):find("\0", 1, true) then return nil, "delivery.arguments[" .. tostring(index) .. "] must not contain NUL" end
        argument_bytes = argument_bytes + #(value)
        if argument_bytes > M.MAX_DELIVERY_ARGUMENT_BYTES then return nil, "delivery.arguments exceeds " .. tostring(M.MAX_DELIVERY_ARGUMENT_BYTES) .. " bytes" end
        arguments[index] = value
    end
    local files: {Configuration} = {}
    local paths: {[string]: boolean} = {}
    local file_bytes = 0
    local raw_files, files_error = sequence(item.files, "delivery.files", M.MAX_DELIVERY_FILES)
    if not raw_files then return nil, files_error end
    for index, value in ipairs(raw_files) do
        local file, file_error = M.decode_file(value)
        if not file then return nil, "delivery.files[" .. tostring(index) .. "]: " .. tostring(file_error) end
        if paths[file.path] then return nil, "delivery.files names " .. file.path .. " twice" end
        paths[file.path] = true
        file_bytes = file_bytes + #file.content
        if file_bytes > M.MAX_DELIVERY_FILE_BYTES then return nil, "delivery.files exceeds " .. tostring(M.MAX_DELIVERY_FILE_BYTES) .. " bytes" end
        files[index] = file
    end
    return {environment = environment, arguments = arguments, files = files}, nil
end
-- Native placement appends this private field after validating the selected
-- driver profile. Provider configure replies cannot choose the adapter.
function M.decode_stored_delivery(value: unknown): (Delivery?, string?)
    local item = bounds.object(value)
    if not item then return nil, "delivery must be an object" end
    local unexpected = bounds.fields(item, {"arguments", "files", "environment", "git_writable_roots_adapter"})
    if unexpected then return nil, "delivery: " .. unexpected end
    local adapter: driver_types.GitWritableRootsAdapter? = nil
    if item.git_writable_roots_adapter ~= nil then
        local selected_adapter = driver_types.git_writable_roots_adapter(item.git_writable_roots_adapter)
        if not selected_adapter then return nil, "delivery.git_writable_roots_adapter is not supported" end
        adapter = selected_adapter
    end
    local decoded, decode_error = M.decode_delivery({environment = item.environment, arguments = item.arguments, files = item.files})
    if not decoded then return nil, decode_error end
    local retained: Delivery = {environment = decoded.environment, arguments = decoded.arguments, files = decoded.files, git_writable_roots_adapter = adapter}
    return retained, nil
end
local function prompt_file(file: Configuration, instructions: string): boolean
    if file.secret_fields then return false end
    if file.content == instructions then return true end
    local composition = file.composition
    local parsed: unknown
    if composition and composition.kind == "toml_patch" then parsed = toml.decode(file.content) else parsed = json.decode(file.content) end
    local document = bounds.object(parsed)
    if not document then return false end
    local paths = bounds.array(document.instructions, 1)
    local path = paths and bounds.line(paths[1], 4096)
    if path and path:sub(-30) == "/.bee/system-prompt-append.txt" and not bounds.fields(document, {"$schema", "instructions"}) then return true end
    if not composition or (composition.kind ~= "json_patch" and composition.kind ~= "toml_patch") then return false end
    local matched = false
    for _, operation in ipairs(composition.operations) do
        local current: unknown = document
        for _, key in ipairs(operation.path) do
            local object = bounds.object(current)
            current = object and object[key]
        end
        if operation.kind == "append" and current == instructions then matched = true end
    end
    return matched
end
local function rendered_value(render: Object, value: unknown, values: Object): unknown
    local token = bounds.object(render.value)
    if not token then return nil end
    if token.literal ~= nil then return token.literal end
    if token.field == "provider.system_prompt_files" then return values.system_prompt_files end
    local name = type(token.field) == "string" and token.field:match("^provider%.env%.([A-Z][A-Z0-9_]*)$")
    if name then return (bounds.object(values.env) or {})[name] end
    return value
end
local function declared_environment(name: string, actual: string, fields: Object, values: Object, context: string): boolean
    for field_name, raw in pairs(fields) do
        local field = bounds.object(raw)
        local value = values[field_name]
        if value == nil and field then value = field.default end
        if field and value ~= nil then
            for _, item in ipairs(bounds.array(field.render, 8) or {}) do
                local render = bounds.object(item)
                if render and render.kind == "env" and render.name == name and bounds.member(context, render.contexts) then
                    local expected = rendered_value(render, value, values)
                    local object = bounds.object(expected)
                    if object and object.kind == "literal" then expected = object.value end
                    return (type(expected) == "string" or type(expected) == "number" or type(expected) == "boolean") and actual == tostring(expected)
                end
            end
        end
    end
    return false
end
local function declared_file(file: Configuration, fields: Object, values: Object, context: string): boolean
    if file.secret_fields then return false end
    local rebuilt: Object = {}
    local document: Object? = nil
    local matched = false
    local paths: {[string]: string} = {}
    for name, raw in pairs(fields) do
        local field = bounds.object(raw)
        local value = values[name]
        if value == nil and field then value = field.default end
        if field and value ~= nil then
            for _, item in ipairs(bounds.array(field.render, 8) or {}) do
                local render = bounds.object(item)
                if render and render.kind == "config" and render.file == file.path and bounds.member(context, render.contexts) then
                    local expected = rendered_value(render, value, values)
                    if expected == nil then return false end
                    if render.format == "text" then return file.composition == nil and file.content == expected end
                    local parsed: unknown
                    if render.format == "toml" then parsed = toml.decode(file.content) else parsed = json.decode(file.content) end
                    document = bounds.object(parsed)
                    local keys = bounds.ids(render.path, true)
                    if not document or not keys or #keys == 0 then return false end
                    local actual: unknown = document
                    local parent = rebuilt
                    for index, key in ipairs(keys) do
                        actual = (bounds.object(actual) or {})[key]
                        if index == #keys then parent[key] = actual
                        else
                            if parent[key] == nil then parent[key] = {} end
                            local child = bounds.object(parent[key])
                            if not child then return false end
                            parent = child
                        end
                    end
                    if actual == nil or canonical.encode(actual) ~= canonical.encode(expected) then return false end
                    local identity = canonical.encode(keys)
                    if not identity or paths[identity] then return false end
                    paths[identity] = render.merge == "append" and "append" or "set"
                    matched = true
                end
            end
        end
    end
    if not matched then return false end
    if canonical.encode(document) ~= canonical.encode(rebuilt) then return false end
    if file.composition then
        if file.composition.kind ~= "json_patch" and file.composition.kind ~= "toml_patch" then return false end
        for _, operation in ipairs(file.composition.operations) do
            local identity = canonical.encode(operation.path)
            if not identity or paths[identity] ~= operation.kind then return false end
        end
    end
    return true
end
function M.decode_reply(value: unknown, selected_provider: string?, gateway: GatewayInput?, instructions: string?, private_home: boolean?, option_values: Object?, option_fields: Object?, context: string?, home_directory: string?): (Delivery?, string?)
    local reply = bounds.object(value)
    if not reply then return nil, "driver configure: reply must be an object" end
    local unexpected = bounds.fields(reply, {"ok", "error", "delivery"})
    if unexpected then return nil, "driver configure: " .. unexpected end
    if type(reply.ok) ~= "boolean" then return nil, "driver configure: ok must be a boolean" end
    if reply.ok == false then
        if reply.delivery ~= nil then return nil, "driver configure: refused reply carries delivery" end
        local error_text = bounds.text(reply.error, 1024)
        if not error_text or error_text == "" then return nil, "driver configure: refused reply needs an error" end
        return nil, "driver configure: " .. error_text
    end
    if reply.error ~= nil then return nil, "driver configure: successful reply carries error" end
    local delivery, delivery_error = M.decode_delivery(reply.delivery)
    if not delivery then return nil, "driver configure: " .. tostring(delivery_error) end
    if selected_provider and #delivery.arguments == 0 and #delivery.files == 0 then return nil, "driver configure omitted the selected provider delivery" end
    local selected_values: Object = {}
    for name, value in pairs(option_values or {}) do selected_values[name] = value end
    if instructions then selected_values.system_prompt_append = instructions end
    if instructions and home_directory then
        local prompt = option_fields and bounds.object(option_fields.system_prompt_append)
        for _, item in ipairs(prompt and bounds.array(prompt.render, 8) or {}) do
            local render = bounds.object(item)
            local path = render and bounds.subpath(render.file)
            if render and render.kind == "config" and render.format == "text" and path then selected_values.system_prompt_files = {home_directory .. "/" .. path} end
        end
    end
    for name, value in pairs(delivery.environment or {}) do
        if not option_fields or not declared_environment(name, value, option_fields, selected_values, context or "first_turn") then return nil, "driver configure environment has no matching selected declaration: " .. name end
    end
    for _, file in ipairs(delivery.files) do
        local provider_file = selected_provider ~= nil and file.provider_ref == selected_provider
        local gateway_file = gateway ~= nil and file.provider_ref == M.GATEWAY_PROVIDER_REF
        local instructions_file = instructions ~= nil and file.provider_ref == M.INSTRUCTIONS_PROVIDER_REF and file.content == instructions
        local login_file = private_home == true and file.provider_ref == M.LOGIN_PROVIDER_REF and file.composition ~= nil and file.composition.kind == "copy" and not file.secret_fields
        local option_file = file.provider_ref == M.OPTIONS_PROVIDER_REF and
            ((option_fields ~= nil and declared_file(file, option_fields, selected_values, context or "first_turn"))
                or (option_fields == nil and instructions ~= nil and prompt_file(file, instructions)))
        if not option_file and not provider_file and not gateway_file and not instructions_file and not login_file then return nil, "driver configure file " .. file.path .. " names an unselected source" end
        if file.secret_fields then
            if not gateway_file or not gateway then return nil, "configuration secret fields require the admitted gateway" end
            for _, field in ipairs(file.secret_fields) do
                if field.environment ~= gateway.token_environment and field.environment ~= gateway.hook_token_environment then
                    return nil, "configuration secret field names an unselected credential"
                end
            end
        end
    end
    return delivery, nil
end
function M.digest(request_value: unknown, target: string, configure_renderer: string?): (string?, string?)
    local request, request_error = M.decode_request(request_value)
    if not request then return nil, request_error end
    local selected = bounds.id(target)
    if not selected then return nil, "configuration target is not an identifier" end
    if configure_renderer ~= nil and not bounds.id(configure_renderer) then return nil, "configuration renderer is not an identifier" end
    local descriptor_digest: string? = nil
    local pinned, pin_error = registry.snapshot()
    if pinned and not pin_error then
        local resolved, resolve_error, declaration = driver_resolver.configure_renderer_for_target(pinned, selected)
        if resolve_error then return nil, resolve_error end
        if configure_renderer == nil then configure_renderer = resolved end
        if declaration then
            local encoded, err = canonical.encode(declaration)
            if not encoded then return nil, err end
            descriptor_digest = hash.sha256(encoded)
            if not descriptor_digest then return nil, "configuration descriptor digest failed" end
        end
    end
    local encoded, encode_error = canonical.encode({target = selected, configure_renderer = configure_renderer, descriptor_digest = descriptor_digest,
        option_values = request.option_values, context = request.context, instructions = request.instructions, instruction_builder = request.instruction_builder, provider_ref = request.provider_ref,
        provider = request.provider, gateway = request.gateway, fixture = request.fixture})
    if not encoded then return nil, "configuration digest: " .. tostring(encode_error) end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, "configuration digest failed" end
    return digest, nil
end
function M.call(target: string, request_value: unknown, configure_renderer: string?): (Delivery?, string?)
    local request, request_error = M.decode_request(request_value)
    if not request then return nil, request_error end
    if configure_renderer ~= nil and not bounds.id(configure_renderer) then return nil, "configuration renderer is not an identifier" end
    local option_fields: Object? = nil
    local pinned, pin_error = registry.snapshot()
    if pinned and not pin_error then
        local resolved, resolve_error, selected = driver_resolver.configure_renderer_for_target(pinned, target)
        if resolve_error then return nil, resolve_error end
        if configure_renderer == nil then configure_renderer = resolved end
        if selected then option_fields = bounds.object(selected.options.fields) end
    end
    local scoped, scope_error = funcs.new():with_scope(security.new_scope({}))
    if not scoped then return nil, "configuration scope: " .. tostring(scope_error) end
    local final_instructions = request.instructions
    if request.instruction_builder then
        local builder = request.instruction_builder
        local raw_output, call_error = scoped:call(builder.func_id, builder.args)
        if call_error then return nil, "instruction builder: " .. tostring(call_error) end
        if type(raw_output) ~= "string" then
            return nil, "instruction builder: output must be a plain string"
        end
        if raw_output ~= "" then
            local validated_output, output_error = M.instructions(raw_output)
            if not validated_output then
                return nil, "instruction builder: " .. tostring(output_error)
            end
            local combined = final_instructions and (final_instructions .. "\n\n" .. validated_output) or validated_output
            local combined_validated, combined_error = M.instructions(combined)
            if not combined_validated then
                return nil, "instruction builder: combined " .. tostring(combined_error)
            end
            final_instructions = combined_validated
        end
    end
    local driver_request = {
        option_values = request.option_values, context = request.context,
        configure_renderer = configure_renderer,
        instructions = final_instructions,
        provider_ref = request.provider_ref,
        provider = request.provider,
        gateway = request.gateway,
        home_directory = request.home_directory,
        private_home = request.private_home,
        attempt_id = request.attempt_id,
        fixture = request.fixture,
    }
    local raw, call_error = scoped:call(target, driver_request)
    if call_error then return nil, "driver configure: " .. tostring(call_error) end
    return M.decode_reply(raw, request.provider_ref, request.gateway, final_instructions, request.private_home, request.option_values, option_fields, request.context, request.home_directory)
end
return M
