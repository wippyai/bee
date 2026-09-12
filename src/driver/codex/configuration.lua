-- MIT. The generated Codex provider configuration: the one file the
-- private CODEX_HOME needs for the API-key path. A host-owned provider
-- entry selects the endpoint, model and optional developer instructions; this
-- module decodes it exactly,
-- renders only the reviewed fields as TOML with proper string escaping,
-- and measures the result. No arbitrary TOML, includes, commands or
-- caller-selected destination ever pass through here, and the key itself
-- stays in the credential broker's environment projection.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.REVISION = "bee.codex-config@1"
M.PROVIDER_TYPE = "bee.codex_provider"
M.PROVIDER_SCHEMA = "bee.codex-provider@1"
M.ENV_KEY = "OPENAI_API_KEY"
M.WIRE_API = "responses"
M.PATH = ".codex/config.toml"
M.MAX_URL_BYTES = 512
-- Keep the provider projection aligned with the shared one-file configure
-- boundary. Escaping can expand otherwise-valid instruction text, so this is
-- checked after rendering rather than inferred from the input bound.
M.MAX_CONFIGURATION_BYTES = 8192
-- Instructions are host-owned provider configuration. Keep this below the
-- shared generated-file bound so a gateway section can still be appended.
M.MAX_DEVELOPER_INSTRUCTIONS_BYTES = 4096
M.REASONING_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
type Provider = {ref: string, name: string, base_url: string, model: string, reasoning_effort: string?, developer_instructions: string?, loopback_fixture: boolean, digest: string}
type Projection = {revision: string, path: string, content: string, digest: string, provider_ref: string, provider_digest: string}
local function toml_string(value: string): string
    local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end
local function developer_text(value: unknown): string?
    local declared = bounds.text(value, M.MAX_DEVELOPER_INSTRUCTIONS_BYTES)
    if not declared or declared == "" then return nil end
    -- TOML basic strings permit newline, carriage return and tab only through
    -- escapes. Reject all other control bytes before rendering; otherwise a
    -- NUL/backspace/form-feed would be copied into invalid TOML.
    for index = 1, #declared do
        local byte = declared:byte(index)
        if (byte < 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d) or byte == 0x7f then return nil end
    end
    return declared
end
local function measurable(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
-- The endpoint is a credential destination: https to a named host, or
-- plain http to the loopback address only for an explicit fixture.
local function endpoint(value: unknown, loopback_fixture: boolean): (string?, string?)
    local url = bounds.text(value, M.MAX_URL_BYTES)
    if not url or url == "" or url:find("%s") then return nil, "base_url must be one bounded URL" end
    local scheme, host, rest = url:match("^(https?)://([^/]+)(.*)$")
    if not scheme or not host then return nil, "base_url must be an http(s) URL with a host" end
    if rest:find("[?#]") then return nil, "base_url carries no query or fragment" end
    if scheme == "http" then
        if not loopback_fixture then return nil, "plain http is permitted only for the loopback fixture" end
        if not host:match("^127%.0%.0%.1:%d+$") then return nil, "the loopback fixture endpoint must be 127.0.0.1 with a port" end
    end
    return url, nil
end
function M.decode(ref: string, entry: {[string]: unknown}): (Provider?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.PROVIDER_TYPE then return nil, ref .. " is not a " .. M.PROVIDER_TYPE end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"schema_revision", "name", "base_url", "model", "reasoning_effort", "developer_instructions", "loopback_fixture"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.PROVIDER_SCHEMA then return nil, ref .. ": schema_revision must be " .. M.PROVIDER_SCHEMA end
    local name = bounds.id(data.name)
    if not name or not name:match("^[a-z][a-z0-9_]*$") then return nil, ref .. ": name must be a lowercase identifier" end
    local model = bounds.id(data.model)
    if not model or not model:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") then return nil, ref .. ": model must be a model identifier" end
    local reasoning_effort: string? = nil
    if data.reasoning_effort ~= nil then
        local declared = bounds.member(data.reasoning_effort, M.REASONING_EFFORTS)
        if not declared then return nil, ref .. ": reasoning_effort must be low, medium, high, xhigh or max" end
        reasoning_effort = declared
    end
    local developer_instructions: string? = nil
    if data.developer_instructions ~= nil then
        local declared = developer_text(data.developer_instructions)
        if not declared then return nil, ref .. ": developer_instructions must be bounded nonempty text without unsupported control bytes" end
        developer_instructions = declared
    end
    local loopback = data.loopback_fixture == true
    if data.loopback_fixture ~= nil and type(data.loopback_fixture) ~= "boolean" then return nil, ref .. ": loopback_fixture must be a boolean" end
    local base_url, url_error = endpoint(data.base_url, loopback)
    if not base_url then return nil, ref .. ": " .. tostring(url_error) end
    local digest, digest_error = measurable(data)
    if not digest then return nil, ref .. ": " .. tostring(digest_error) end
    return {ref = ref, name = name, base_url = base_url, model = model, reasoning_effort = reasoning_effort, developer_instructions = developer_instructions, loopback_fixture = loopback, digest = digest}, nil
end
-- render: exactly the reviewed fields, nothing else.
function M.render(provider: Provider, gateway_section: string?): string
    local lines = {
        "# generated by bee " .. M.REVISION .. "; provider " .. provider.ref,
        "model_provider = " .. toml_string(provider.name),
        "model = " .. toml_string(provider.model),
    }
    if provider.reasoning_effort then lines[#lines + 1] = "model_reasoning_effort = " .. toml_string(provider.reasoning_effort) end
    if provider.developer_instructions then lines[#lines + 1] = "developer_instructions = " .. toml_string(provider.developer_instructions) end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[model_providers." .. provider.name .. "]"
    lines[#lines + 1] = "name = " .. toml_string(provider.name)
    lines[#lines + 1] = "base_url = " .. toml_string(provider.base_url)
    lines[#lines + 1] = "env_key = " .. toml_string(M.ENV_KEY)
    lines[#lines + 1] = "wire_api = " .. toml_string(M.WIRE_API)
    lines[#lines + 1] = ""
    local content = table.concat(lines, "\n")
    -- The gateway section is rendered by the gateway library and appended
    -- verbatim, so the one file Codex reads carries both host selections.
    if gateway_section then content = content .. gateway_section end
    return content
end
-- projection: what placement writes into the private home, measured.
function M.projection(provider: Provider, gateway_section: string?): (Projection?, string?)
    local content = M.render(provider, gateway_section)
    if #content > M.MAX_CONFIGURATION_BYTES then
        return nil, "configuration exceeds " .. tostring(M.MAX_CONFIGURATION_BYTES) .. " bytes after TOML escaping"
    end
    local digest, hash_error = hash.sha256(content)
    if hash_error or not digest then return nil, "configuration digest failed" end
    return {revision = M.REVISION, path = M.PATH, content = content, digest = digest, provider_ref = provider.ref, provider_digest = provider.digest}, nil
end
return M
