-- MIT. Author the guide's own example through the real governed chain and
-- require a ready destination preflight. This is what keeps the guide's
-- example from rotting: it is the same value a person reads through the MCP
-- overlay tool, published and staged the same way tests/fixtures/app_journey
-- authors an application.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local env = require("env")
local json = require("json")
local logger = require("logger")
local bounds = require("bounds")
local guide = require("guide")
local artifact = require("artifact")
local preflight = require("preflight")

type Object = {[string]: unknown}

local COMPONENT = guide.NAMESPACE .. "/app"
local SOURCE_WORKSPACE = "app-journey-guide"
local OVERLAY_OWNER = "bee.app_journey_probe:guide_overlay"
local APPROVAL_POLICY = "local-app-journey-guide"

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected object value") end
    return decoded
end

local function call_api(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    local answer = object(result)
    if answer.ok ~= true then
        local fault = bounds.object(answer.error)
        error(target .. " returned error: " .. tostring(fault and fault.code or answer.code)
            .. ": " .. tostring(fault and fault.message or answer.message))
    end
    return object(answer.value)
end

local function digest_of(value: unknown, label: string): string
    local measured = bounds.id(value)
    if not measured or #measured ~= 64 then error(label .. " is not a digest") end
    return measured
end

local function configure_host(workspace_id: string, local_node: string)
    local pub_entry = assert(registry.get("bee.governance:publication_profiles"))
    local pub_data = object(pub_entry.data)
    pub_data.profiles = {{workspace_id = workspace_id, source_workspace = SOURCE_WORKSPACE,
        component = COMPONENT, overlay_owner = OVERLAY_OWNER}}
    pub_entry.data = pub_data

    local act_entry = assert(registry.get("bee.governance:activation_profiles"))
    local act_data = object(act_entry.data)
    act_data.profiles = {{workspace_id = workspace_id, source_node = local_node,
        source_workspace = SOURCE_WORKSPACE, component = COMPONENT, resolver = "overlay",
        overlay_owner = OVERLAY_OWNER, approval_policy = APPROVAL_POLICY, parameters = {},
        allow = {packages = {COMPONENT}, namespaces = {guide.NAMESPACE}, kinds = {"process.lua"},
            databases = {}, grants = {}, modules = {"tty", "process", "channel", "json"}}}}
    act_entry.data = act_data

    local policy_entry = assert(registry.get("bee:approver_policies"))
    local policy_data = object(policy_entry.data)
    local policies = policy_data.policies :: {unknown}
    policies[#policies + 1] = {name = APPROVAL_POLICY,
        approvers = {"bee.app_journey.operator", {definition_id = "bee.inbox:app"}}, max_ttl_ms = 60000}
    policy_data.policies = policies
    policy_entry.data = policy_data

    local changes = registry.snapshot():changes()
    assert(changes:update(pub_entry))
    assert(changes:update(act_entry))
    assert(changes:update(policy_entry))
    local applied, apply_error = changes:apply()
    if not applied then error("apply guide host profiles: " .. tostring(apply_error)) end
end

local function main()
    -- The guide is the product surface an agent reads over MCP. Read it here
    -- through the same facade, not from this fixture.
    local published = call_api("bee.governance:overlay_call", {operation = "guide"})
    local document = bounds.text(published.document, 65536)
    if not document or not document:find(guide.ENTRIES_PATH, 1, true) then
        error("the guide document does not name " .. guide.ENTRIES_PATH)
    end
    local example = object(published.example)
    local entries_json = bounds.text(example.entries_json, 65536)
    if not entries_json then error("the guide example carries no entries JSON") end
    local decoded, decode_error = json.decode(entries_json)
    if decode_error then error("the guide example is not JSON: " .. tostring(decode_error)) end
    local measured, measure_error = artifact.create(decoded)
    if not measured then error("the guide example is not a measurable artifact: " .. tostring(measure_error)) end
    if measured.entries[1].id ~= guide.DEFINITION_ID or measured.entries[1].kind ~= "process.lua" then
        error("the guide example is not the expected single process.lua entry")
    end

    local create_res = call_api("bee.governance:overlay_call", {operation = "create",
        overlay_id = SOURCE_WORKSPACE, expected_revision = 0, idempotency_key = "create-" .. SOURCE_WORKSPACE})
    if create_res.revision ~= 1 then error("workspace create revision expected 1") end
    local put_res = call_api("bee.governance:overlay_call", {operation = "put", overlay_id = SOURCE_WORKSPACE,
        expected_revision = 1, idempotency_key = "put-entries-" .. SOURCE_WORKSPACE,
        path = guide.ENTRIES_PATH, content = entries_json})
    if put_res.revision ~= 2 then error("workspace put revision expected 2") end
    local freeze_res = call_api("bee.governance:overlay_call", {operation = "freeze",
        overlay_id = SOURCE_WORKSPACE, expected_revision = 2, idempotency_key = "freeze-" .. SOURCE_WORKSPACE})
    local snapshot_digest = digest_of(freeze_res.digest, "guide example frozen digest")

    local workspace_id = bounds.id(env.get("bee.app_journey_probe:destination_workspace"))
    if not workspace_id then error("destination workspace identity is unavailable") end
    local local_node = assert(system.node.id())
    configure_host(workspace_id, local_node)

    local prepared = call_api("bee.governance:publication_call", {operation = "prepare",
        workspace_id = workspace_id, component = COMPONENT, version = guide.VERSION,
        snapshot_digest = snapshot_digest})
    local descriptor = object(prepared.descriptor)
    local manifest = object(descriptor.manifest)
    if manifest.artifact_digest ~= measured.digest then
        error("the guide example published another artifact than it measured")
    end

    local staged_reply = call_api("bee.governance:destination_call", {operation = "stage",
        workspace_id = workspace_id, source_owner = descriptor.owner_id, feed = descriptor.feed,
        version_key = descriptor.key, descriptor_digest = descriptor.digest,
        idempotency_key = "stage-" .. SOURCE_WORKSPACE})
    if staged_reply.status ~= "staged" then error("the guide example did not stage") end

    local staged = call_api("bee.governance:destination_call", {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = guide.VERSION})
    local report, report_error = preflight.decode_report(staged.preflight_bytes, staged.preflight_digest)
    if not report then error("guide example preflight report: " .. tostring(report_error)) end
    if report.ready ~= true or #report.diagnostics > 0 then
        error("the guide example is not ready at preflight: " .. json.encode(report.diagnostics))
    end
    if #report.pending_migrations > 0 then error("the guide example carries pending migrations") end

    -- The product delivery tool an authoring agent holds: request delivery of
    -- the frozen artifact, learn the destination's verdict and the human steps.
    local delivered = call_api("bee.governance:delivery_call", {operation = "request",
        workspace_id = workspace_id, source_overlay_id = SOURCE_WORKSPACE, version = guide.VERSION,
        snapshot_digest = snapshot_digest})
    if delivered.ready ~= true then
        error("the product delivery tool did not report a ready destination: " .. json.encode(delivered.diagnostics))
    end
    if delivered.plan_digest ~= staged.plan_digest then
        error("the product delivery tool reported another staged plan")
    end
    local steps = delivered.human_steps :: {unknown}
    if type(steps) ~= "table" or #steps ~= 6 then
        error("the product delivery tool did not name the human steps")
    end
    local where = object(delivered.human_steps_where)
    if where.review ~= "Overlays" or where.approve ~= "Approvals" or where.open ~= "start menu" then
        error("the product delivery tool did not name where the human acts")
    end
    -- Delivery status reads the staged plan back by identity.
    local status_res = call_api("bee.governance:delivery_call", {operation = "status",
        workspace_id = workspace_id, source_overlay_id = SOURCE_WORKSPACE, version = guide.VERSION,
        source_node = local_node})
    if status_res.plan_digest ~= staged.plan_digest or status_res.selected == true then
        error("delivery status did not read the staged, unselected plan")
    end
    -- The delivery tool cannot review, select, approve or apply: those are the
    -- person's and the activation owner's. It reports no overlay authority.
    logger:info("APP_JOURNEY_GUIDE", {ready = true, delivered = true, human_steps = #steps,
        definition_id = guide.DEFINITION_ID, title = guide.TITLE,
        guide_revision = published.revision, snapshot_digest = snapshot_digest, artifact_digest = measured.digest,
        plan_digest = digest_of(staged.plan_digest, "guide staged plan digest"),
        example_matches = true})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("APP_JOURNEY_GUIDE_FAILED", {error = tostring(err)})
        error(err)
    end
end}
