-- MIT. Two retained boots exercise public durable authoring, never store access.
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")
local bounds = require("bounds")

type Object = {[string]: unknown}

local function principal(actor: string): funcs.Executor
    local policies = {
        assert(security.policy("bee.gov.workspace.probe:call_policy")),
        assert(security.policy("bee.gov.workspace.probe:read_policy")),
        assert(security.policy("bee.gov.workspace.probe:write_policy")),
        assert(security.policy("bee.gov.workspace.probe:caller_boundary")),
    }
    return funcs.new():with_actor(security.new_actor(actor)):with_scope(security.new_scope(policies))
end

local function isolated(client: funcs.Executor)
    local raw, err = client:call("bee.gov.workspace.probe:authority_probe")
    assert(not err, tostring(err))
    local probe = bounds.object(raw)
    assert(probe, "missing caller authority probe")
    assert(probe.opened == false, "caller gained direct database access")
    assert(probe.scope_create == false, "caller gained scope creation")
    assert(probe.scope_lookup == false, "caller gained access to the private named scope")
    assert(probe.private_execute == false, "caller gained private execution")
    local reply, backend_error = client:call("bee.gov.binding:workspace_backend_call", {operation = "list", workspace_id = "demo"})
    assert(not backend_error, tostring(backend_error))
    local denied = bounds.object(reply)
    assert(denied and denied.ok == false and denied.code == "DENIED", "direct backend call was admitted")
end

local function call(client: funcs.Executor, request: unknown): Object
    local result, err = client:call("bee.gov.binding:overlay_call", request)
    assert(not err, tostring(err))
    local decoded = bounds.object(result)
    assert(decoded, "malformed authoring result")
    return decoded
end

local function value(result: Object): Object
    assert(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    local decoded = bounds.object(result.value)
    assert(decoded, "missing authoring value")
    return decoded
end

local function main(phase: string?)
    local writer = principal("author-a")
    local foreign = principal("author-b")
    isolated(writer)
    local create = {operation = "create", overlay_id = "demo", expected_revision = 0, idempotency_key = "create"}
    local put = {operation = "put", overlay_id = "demo", expected_revision = 1, idempotency_key = "binary",
        path = "assets/demo.wasm", content_base64 = "AP9hc3NldA=="}
    local freeze = {operation = "freeze", overlay_id = "demo", expected_revision = 2, idempotency_key = "freeze"}

    if phase == "first" then
        assert(call(writer, {operation = "list", overlay_id = "demo"}).code == "NOT_FOUND", "first boot reused a store")
        assert(value(call(writer, create)).revision == 1)
        assert(value(call(writer, put)).revision == 2)
        local frozen = value(call(writer, freeze))
        assert(type(frozen.digest) == "string", "freeze omitted its digest")
        assert(value(call(writer, {operation = "put", overlay_id = "demo", expected_revision = 2,
            idempotency_key = "update", path = "assets/demo.wasm", content = "updated"})).revision == 3)
        local retained = value(call(writer, {operation = "read", overlay_id = "demo", path = "assets/demo.wasm",
            snapshot_digest = frozen.digest}))
        assert(retained.content_base64 == "AP9hc3NldA==" and retained.revision == 2, "frozen binary followed a mutable edit")
        isolated(writer)
        logger:info("GOVERNANCE_WORKSPACE_FIRST_BOOT_PASS")
        return
    end

    assert(phase == "second", "unexpected governance probe phase")
    assert(value(call(writer, {operation = "list", overlay_id = "demo"})).revision == 3, "restart lost workspace revision")
    assert(call(writer, create).replayed == true, "restart lost create receipt")
    assert(call(writer, put).replayed == true, "restart lost binary write receipt")
    local frozen = value(call(writer, freeze))
    assert(call(writer, freeze).replayed == true, "restart lost freeze receipt")
    local retained = value(call(writer, {operation = "read", overlay_id = "demo", path = "assets/demo.wasm",
        snapshot_digest = frozen.digest}))
    assert(retained.content_base64 == "AP9hc3NldA==" and retained.revision == 2, "restart changed frozen binary bytes")
    local denied = call(foreign, {operation = "list", overlay_id = "demo"})
    assert(denied.ok == false and denied.code == "DENIED", "foreign author accessed exact workspace")
    isolated(writer)
    logger:info("GOVERNANCE_WORKSPACE_SECOND_BOOT_PASS")
end

return {main = main}
