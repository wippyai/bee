-- MIT. Typed driver configuration delivery under an empty callee scope.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local funcs = require("funcs")
local security = require("security")
local M = {}
M.MAX_CONFIGURATION_BYTES = 8192
M.MAX_INSTRUCTIONS_BYTES = 4096
M.MAX_DELIVERY_ARGUMENTS = 32
M.MAX_DELIVERY_ARGUMENT_BYTES = 16384
M.MAX_DELIVERY_FILES = 8
M.MAX_DELIVERY_FILE_BYTES = 24576
M.MAX_GATEWAY_TOOLS = 32
M.MAX_GATEWAY_HOOKS = 32
M.MAX_HOME_DIRECTORY_BYTES = 4096
M.GATEWAY_PROVIDER_REF = "bee:gateway_endpoint"
M.INSTRUCTIONS_PROVIDER_REF = "bee:profile_instructions"
type Object = {[string]: unknown}
type Configuration = {revision: string, path: string, content: string, digest: string, provider_ref: string}
type InstructionBuilder = {func_id: string, args: {[string]: unknown}}
type GatewayInput = {endpoint: string, action_id: string, tools: {string}, hooks: {string}, token_environment: string, hook_token_environment: string?}
type Delivery = {arguments: {string}, files: {Configuration}}
type Request = {instructions: string?, instruction_builder: InstructionBuilder?, provider_ref: string?, provider: Object?, gateway: GatewayInput?, home_directory: string?, fixture: boolean}

-- Profile guidance is separate from a turn brief and grants no authority.
function M.instructions(value: unknown): (string?, string?)
    if value == nil then return nil, nil end
    local text = bounds.text(value, M.MAX_INSTRUCTIONS_BYTES)
    if not text or text == "" then return nil, "instructions must be nonempty text up to 4096 bytes" end
    for index = 1, #text do
        local byte = text:byte(index)
        if (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) or byte == 127 then
            return nil, "instructions contain unsupported control bytes"
        end
    end
    return text, nil
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
    local unexpected = bounds.fields(item, {"endpoint", "action_id", "tools", "hooks", "token_environment", "hook_token_environment"})
    if unexpected then return nil, "configuration request.gateway: " .. unexpected end
    local endpoint = bounds.text(item.endpoint, 512)
    if not endpoint or not endpoint:match("^127%.0%.0%.1:%d+$") then return nil, "configuration request.gateway.endpoint must be a loopback host and port" end
    local action_id = bounds.id(item.action_id)
    if not action_id or action_id:find("[/?#%s]") then return nil, "configuration request.gateway.action_id is not a path segment" end
    local declared_tools = bounds.ids(item.tools, true)
    if not declared_tools or #declared_tools == 0 or #declared_tools > M.MAX_GATEWAY_TOOLS then return nil, "configuration request.gateway.tools must name 1 to " .. tostring(M.MAX_GATEWAY_TOOLS) .. " tools" end
    local tools: {string} = {}
    for index, tool in ipairs(declared_tools) do tools[index] = tool end
    local declared_hooks = bounds.ids(item.hooks, true)
    if not declared_hooks or #declared_hooks > M.MAX_GATEWAY_HOOKS then return nil, "configuration request.gateway.hooks exceeds " .. tostring(M.MAX_GATEWAY_HOOKS) .. " items" end
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
    local result: GatewayInput = {endpoint = endpoint, action_id = action_id, tools = tools, hooks = hooks, token_environment = token, hook_token_environment = hook_token}
    return result, nil
end
function M.decode_request(value: unknown): (Request?, string?)
    local request = bounds.object(value)
    if not request then return nil, "configuration request must be an object" end
    local unexpected = bounds.fields(request, {"provider_ref", "provider", "gateway", "home_directory", "fixture", "instructions", "instruction_builder"})
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
    local home_directory: string? = nil
    if request.home_directory ~= nil then
        home_directory = bounds.text(request.home_directory, M.MAX_HOME_DIRECTORY_BYTES)
        if not home_directory or home_directory == "" or home_directory:sub(1, 1) ~= "/" then return nil, "configuration request.home_directory must be an absolute bounded path" end
    end
    return {instructions = instructions, instruction_builder = instruction_builder, provider_ref = provider_ref, provider = provider, gateway = gateway, home_directory = home_directory, fixture = request.fixture :: boolean}, nil
end
function M.decode_file(value: unknown): (Configuration?, string?)
    local item = bounds.object(value)
    if not item then return nil, "configuration must be an object" end
    local unexpected = bounds.fields(item, {"revision", "path", "content", "digest", "provider_ref"})
    if unexpected then return nil, "configuration: " .. unexpected end
    local revision = bounds.id(item.revision)
    if not revision then return nil, "configuration.revision is not an identifier" end
    local path, path_error = bounds.subpath(item.path)
    if path_error then return nil, "configuration.path " .. path_error end
    if not path or path == "" then return nil, "configuration.path must be a nonempty safe relative path" end
    local content = bounds.text(item.content, M.MAX_CONFIGURATION_BYTES)
    if not content or content == "" then return nil, "configuration.content must be bounded nonempty text" end
    local digest = bounds.id(item.digest)
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "configuration.digest must be a lowercase sha256 hex digest" end
    local actual, hash_error = hash.sha256(content)
    if hash_error or not actual then return nil, "configuration.digest could not be measured" end
    if digest ~= actual then return nil, "configuration.digest does not match content" end
    local provider_ref = bounds.id(item.provider_ref)
    if not provider_ref then return nil, "configuration.provider_ref is not an identifier" end
    return {revision = revision, path = path, content = content, digest = digest, provider_ref = provider_ref}, nil
end
local function sequence(value: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local list = value :: {unknown}
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
function M.decode_delivery(value: unknown): (Delivery?, string?)
    local item = bounds.object(value)
    if not item then return nil, "delivery must be an object" end
    local unexpected = bounds.fields(item, {"arguments", "files"})
    if unexpected then return nil, "delivery: " .. unexpected end
    local arguments: {string} = {}
    local argument_bytes = 0
    local raw_arguments, arguments_error = sequence(item.arguments, "delivery.arguments", M.MAX_DELIVERY_ARGUMENTS)
    if not raw_arguments then return nil, arguments_error end
    for index, value in ipairs(raw_arguments) do
        if type(value) ~= "string" then return nil, "delivery.arguments[" .. tostring(index) .. "] must be text" end
        if (value :: string):find("\0", 1, true) then return nil, "delivery.arguments[" .. tostring(index) .. "] must not contain NUL" end
        argument_bytes = argument_bytes + #(value :: string)
        if argument_bytes > M.MAX_DELIVERY_ARGUMENT_BYTES then return nil, "delivery.arguments exceeds " .. tostring(M.MAX_DELIVERY_ARGUMENT_BYTES) .. " bytes" end
        arguments[index] = value :: string
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
    return {arguments = arguments, files = files}, nil
end
function M.decode_reply(value: unknown, selected_provider: string?, gateway: GatewayInput?, instructions: string?): (Delivery?, string?)
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
    for _, file in ipairs(delivery.files) do
        local provider_file = selected_provider ~= nil and file.provider_ref == selected_provider
        local gateway_file = gateway ~= nil and file.provider_ref == M.GATEWAY_PROVIDER_REF
        local instructions_file = instructions ~= nil and file.provider_ref == M.INSTRUCTIONS_PROVIDER_REF and file.content == instructions
        if not provider_file and not gateway_file and not instructions_file then return nil, "driver configure file " .. file.path .. " names an unselected source" end
    end
    return delivery, nil
end
function M.digest(request_value: unknown, target: string): (string?, string?)
    local request, request_error = M.decode_request(request_value)
    if not request then return nil, request_error end
    local selected = bounds.id(target)
    if not selected then return nil, "configuration target is not an identifier" end
    local encoded, encode_error = canonical.encode({target = selected, instructions = request.instructions, instruction_builder = request.instruction_builder, provider_ref = request.provider_ref, provider = request.provider, gateway = request.gateway, fixture = request.fixture})
    if not encoded then return nil, "configuration digest: " .. tostring(encode_error) end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, "configuration digest failed" end
    return digest, nil
end
function M.call(target: string, request_value: unknown): (Delivery?, string?)
    local request, request_error = M.decode_request(request_value)
    if not request then return nil, request_error end
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
        instructions = final_instructions,
        provider_ref = request.provider_ref,
        provider = request.provider,
        gateway = request.gateway,
        home_directory = request.home_directory,
        fixture = request.fixture,
    }
    local raw, call_error = scoped:call(target, driver_request)
    if call_error then return nil, "driver configure: " .. tostring(call_error) end
    return M.decode_reply(raw, request.provider_ref, request.gateway, final_instructions)
end
return M
