-- MIT. A deliberately small third-party driver fixture. Its configure method
-- proves placement consumes a binding's generic contract rather than a
-- provider-specific core branch.
local hash = require("hash")

local PROVIDER_REF = "bee.placement.native:fixture_agent_provider"
local REVISION = "bee.fixture-agent-config@1"
local PATH = ".fixture-agent/provider.json"

local function prepare(_: unknown): {[string]: unknown}
    return {ok = true}
end

local function dispatch(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture-agent dispatch is outside this placement proof"}
end

local function normalize(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture-agent normalize is outside this placement proof"}
end

local function configure(value: unknown): {[string]: unknown}
    local configure_protocol = require("configure_protocol")
    local request, request_error = configure_protocol.decode_request(value)
    if not request then return {ok = false, error = request_error or "invalid configuration request"} end
    if request.provider_ref == nil and request.provider == nil and request.gateway == nil and request.fixture == true then
        return {ok = true, delivery = {arguments = {}, files = {}}}
    end
    if request.provider_ref ~= PROVIDER_REF or not request.provider or request.fixture ~= true then
        return {ok = false, error = "fixture-agent needs its selected fixture provider"}
    end
    local provider = request.provider
    local data = provider.data
    if type(data) ~= "table" or (data :: {[string]: unknown}).schema_revision ~= "bee.fixture-agent-provider@1" or (data :: {[string]: unknown}).model ~= "terra" then
        return {ok = false, error = "fixture-agent provider is invalid"}
    end
    -- Deliberately try to mutate the provider copy. The placement test checks
    -- that the funcs.call boundary does not expose the registry table itself.
    (data :: {[string]: unknown}).mutation_probe = "driver-copy"
    local content = '{"provider_ref":"' .. PROVIDER_REF .. '","model":"terra"}\n'
    local digest, digest_error = hash.sha256(content)
    if not digest then return {ok = false, error = tostring(digest_error or "configuration digest failed")} end
    return {ok = true, delivery = {arguments = {}, files = {{revision = REVISION, path = PATH, content = content, digest = digest, provider_ref = PROVIDER_REF}}}}
end

return {prepare = prepare, dispatch = dispatch, normalize = normalize, configure = configure}
