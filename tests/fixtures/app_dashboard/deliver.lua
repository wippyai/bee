-- MIT. Author the reference dashboard as an agent would: one entries.json
-- carrying the exact inline sources of the bundled System Monitor under a
-- package namespace of its own, frozen, published, staged and preflighted
-- through the governed chain, then requested for delivery. Review,
-- approval, application and opening remain the person's steps in the UI.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local env = require("env")
local json = require("json")
local logger = require("logger")
local bounds = require("bounds")
local artifact = require("artifact")
local preflight = require("preflight")

type Object = {[string]: unknown}

local NAMESPACE = "bee.monitor_demo"
local COMPONENT = NAMESPACE .. "/dashboard"
local SOURCE_WORKSPACE = "app-dashboard-source"
local OVERLAY_OWNER = "bee.app_dashboard_probe:overlay"
local APPROVAL_POLICY = "local-app-dashboard"
local VERSION = "1.0.0"
local TITLE = "Delivered Monitor"
local MODULES = {"tty", "process", "channel", "time", "uuid"}

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

-- The bundled entry's inline source and declarations, with imports into the
-- bundled namespace redirected to the package's own entries.
local function authored(id: string, name: string): Object
    local entry = registry.get(id)
    if not entry then error("bundled reference " .. id .. " is missing") end
    local data = object(entry.data)
    local source = bounds.text(data.source, 262144)
    if not source or not source:find("require(", 1, true) then error(id .. " carries no inline source") end
    local imports: {[string]: string} = {}
    for alias, target in pairs(object(data.imports)) do
        local value = tostring(target)
        if value:sub(1, #"bee.monitor:") == "bee.monitor:" then value = NAMESPACE .. ":" .. value:sub(#"bee.monitor:" + 1) end
        imports[tostring(alias)] = value
    end
    local authored_data: Object = {source = source, imports = imports}
    if data.method ~= nil then authored_data.method = data.method end
    if data.modules ~= nil then authored_data.modules = data.modules end
    return {id = NAMESPACE .. ":" .. name, kind = entry.kind, data = authored_data}
end

local function configure_host(workspace_id: string, local_node: string)
    local pub_entry = assert(registry.get("bee:governance_publication_profiles"))
    local pub_data = object(pub_entry.data)
    pub_data.profiles = {{workspace_id = workspace_id, source_workspace = SOURCE_WORKSPACE,
        component = COMPONENT, overlay_owner = OVERLAY_OWNER}}
    pub_entry.data = pub_data

    local act_entry = assert(registry.get("bee:governance_activation_profiles"))
    local act_data = object(act_entry.data)
    act_data.profiles = {{workspace_id = workspace_id, source_node = local_node,
        source_workspace = SOURCE_WORKSPACE, component = COMPONENT, resolver = "overlay",
        overlay_owner = OVERLAY_OWNER, approval_policy = APPROVAL_POLICY, parameters = {},
        allow = {packages = {COMPONENT}, namespaces = {NAMESPACE}, kinds = {"process.lua", "library.lua"},
            databases = {}, grants = {}, modules = MODULES}}}
    act_entry.data = act_data

    local policy_entry = assert(registry.get("bee:approver_policies"))
    local policy_data = object(policy_entry.data)
    local policies = policy_data.policies :: {unknown}
    policies[#policies + 1] = {name = APPROVAL_POLICY,
        approvers = {"bee.app_dashboard.operator", {definition_id = "bee.inbox:app"}}, max_ttl_ms = 60000}
    policy_data.policies = policies
    policy_entry.data = policy_data

    local changes = registry.snapshot():changes()
    assert(changes:update(pub_entry))
    assert(changes:update(act_entry))
    assert(changes:update(policy_entry))
    local applied, apply_error = changes:apply()
    if not applied then error("apply dashboard host profiles: " .. tostring(apply_error)) end
end

local function main()
    local app = authored("bee.monitor:app", "app")
    app.meta = {type = "bee.application", application = {api_version = 1, lifetime = "view",
        revision = "1", title = TITLE, instance_policy = "singleton"}}
    local entries = {app, authored("bee.monitor:view", "view")}
    local entries_json, encode_error = json.encode(entries)
    if not entries_json then error("encode entries: " .. tostring(encode_error)) end
    local measured, measure_error = artifact.create(entries)
    if not measured then error("the dashboard is not a measurable artifact: " .. tostring(measure_error)) end

    local create_res = call_api("bee.governance.binding:overlay_call", {operation = "create",
        overlay_id = SOURCE_WORKSPACE, expected_revision = 0, idempotency_key = "create-" .. SOURCE_WORKSPACE})
    if create_res.revision ~= 1 then error("workspace create revision expected 1") end
    local put_res = call_api("bee.governance.binding:overlay_call", {operation = "put", overlay_id = SOURCE_WORKSPACE,
        expected_revision = 1, idempotency_key = "put-entries-" .. SOURCE_WORKSPACE,
        path = "entries.json", content = entries_json})
    if put_res.revision ~= 2 then error("workspace put revision expected 2") end
    local freeze_res = call_api("bee.governance.binding:overlay_call", {operation = "freeze",
        overlay_id = SOURCE_WORKSPACE, expected_revision = 2, idempotency_key = "freeze-" .. SOURCE_WORKSPACE})
    local snapshot_digest = digest_of(freeze_res.digest, "dashboard frozen digest")

    local workspace_id = bounds.id(env.get("bee.app_dashboard_probe:destination_workspace"))
    if not workspace_id then error("destination workspace identity is unavailable") end
    local local_node = assert(system.node.id())
    configure_host(workspace_id, local_node)

    local prepared = call_api("bee.governance.binding:publication_call", {operation = "prepare",
        workspace_id = workspace_id, component = COMPONENT, version = VERSION, snapshot_digest = snapshot_digest})
    local descriptor = object(prepared.descriptor)
    local manifest = object(descriptor.manifest)
    if manifest.artifact_digest ~= measured.digest then error("the dashboard published another artifact than it measured") end

    local staged_reply = call_api("bee.governance.binding:destination_call", {operation = "stage",
        workspace_id = workspace_id, source_owner = descriptor.owner_id, feed = descriptor.feed,
        version_key = descriptor.key, descriptor_digest = descriptor.digest,
        idempotency_key = "stage-" .. SOURCE_WORKSPACE})
    if staged_reply.status ~= "staged" then error("the dashboard did not stage") end

    local staged = call_api("bee.governance.binding:destination_call", {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION})
    local report, report_error = preflight.decode_report(staged.preflight_bytes, staged.preflight_digest)
    if not report then error("dashboard preflight report: " .. tostring(report_error)) end
    if report.ready ~= true or #report.diagnostics > 0 then
        error("the dashboard is not ready at preflight: " .. json.encode(report.diagnostics))
    end

    local delivered = call_api("bee.governance.binding:delivery_call", {operation = "request",
        workspace_id = workspace_id, source_overlay_id = SOURCE_WORKSPACE, version = VERSION,
        snapshot_digest = snapshot_digest})
    if delivered.ready ~= true then error("delivery did not report a ready destination: " .. json.encode(delivered.diagnostics)) end
    if delivered.plan_digest ~= staged.plan_digest then error("delivery reported another staged plan") end
    logger:info("APP_DASHBOARD_DELIVERED", {ready = true, title = TITLE, definition_id = NAMESPACE .. ":app",
        entries = #entries, snapshot_digest = snapshot_digest, artifact_digest = measured.digest,
        plan_digest = digest_of(staged.plan_digest, "dashboard staged plan digest"),
        workspace = SOURCE_WORKSPACE, version = VERSION, approval_policy = APPROVAL_POLICY})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("APP_DASHBOARD_FAILED", {error = tostring(err)})
        error(err)
    end
end}
