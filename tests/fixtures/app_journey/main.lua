-- MIT. Carry one real application from authoring through approval to an
-- applied, admitted registry entry, using the production governance/delivery
-- chain: author into a governed workspace, freeze, publish, discover, stage,
-- preflight, review, select, approve, consume and apply. Source and
-- destination are the same node, the same simplification the governance unit
-- suites use; the chain of calls is the one a distributed delivery drives.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local json = require("json")
local uuid = require("uuid")
local logger = require("logger")
local bounds = require("bounds")
local artifact = require("artifact")
local materializer = require("materializer")
local preflight = require("preflight")
local catalog = require("catalog")

type Object = {[string]: unknown}

local SOURCE_WORKSPACE = "app-journey-source"
local COMPONENT = "bee.app_journey_demo/app"
local OVERLAY_OWNER = "bee.app_journey_probe:activation_overlay"
local APPROVAL_POLICY = "local-app-journey"
local VERSION = "1.0.0"
local DEFINITION_ID = "bee.app_journey_demo:app"
local APP_TITLE = "App Journey"
local RETRY_EFFECT = "app-journey-second-effect"

local APP_SOURCE = [[local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local count = 0
    if launch.resume_state ~= "" then
        local state: unknown = json.decode(launch.resume_state)
        if type(state) ~= "table" or type(state.count) ~= "number" then error("Invalid counter checkpoint") end
        count = math.floor(state.count)
    end
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local saved = -1
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        canvas:put(1, 1, "APP JOURNEY DELIVERED", width)
        canvas:put(1, 2, "Count: " .. tostring(count), width)
        canvas:put(1, 3, "Saved: " .. tostring(saved), width)
        assert(output:present(canvas:rows()))
    end
    local function checkpoint()
        assert(client.checkpoint(launch, json.encode({count = count})))
    end
    paint(); client.ready(launch); checkpoint()
    while true do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == receipts then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.error_code == "" then
                saved = count; paint()
            end
        elseif event.value.type == "close" then checkpoint()
        elseif event.value.type == "resize" then width, height = event.value.width, event.value.height; paint()
        elseif event.value.type == "key" and event.value.action ~= "release" then count = count + 1; paint(); checkpoint() end
    end
    output:close(); tty.stop()
end
return {main = main}
]]

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected object value") end
    return decoded
end

-- The reply's value carries fault detail as well as success detail: a
-- REVALIDATE fault reports the current authority incarnation there.
local function reply_of(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    return object(result)
end

local function call_api(target: string, request: unknown): Object
    local reply = reply_of(target, request)
    if reply.ok ~= true then
        error(target .. " returned error: " .. tostring(reply.code) .. ": " .. tostring(reply.message or json.encode(reply.error)))
    end
    local value = bounds.object(reply.value)
    if not value then error(target .. " missing value") end
    return value
end

local function fault_code(reply: Object): string
    local fault = bounds.object(reply.error)
    return tostring(fault and fault.code or reply.code)
end

local function digest_of(value: unknown, label: string): string
    local measured = bounds.id(value)
    if not measured then error(label .. " is not a digest") end
    return measured
end

local function admitted_title(): string?
    for _, item in ipairs(catalog.read().items) do
        if item.definition_id == DEFINITION_ID then return item.title end
    end
    return nil
end

local function configure_host(workspace_id: string, local_node: string)
    local pub_entry = assert(registry.get("bee.governance:publication_profiles"))
    local pub_data = object(pub_entry.data)
    pub_data.profiles = {{workspace_id = workspace_id, source_workspace = SOURCE_WORKSPACE,
        component = COMPONENT, overlay_owner = OVERLAY_OWNER}}
    pub_entry.data = pub_data

    local act_entry = assert(registry.get("bee.governance:activation_profiles"))
    local act_data = object(act_entry.data)
    act_data.profiles = {{workspace_id = workspace_id, source_node = local_node, source_workspace = SOURCE_WORKSPACE,
        component = COMPONENT, resolver = "overlay", overlay_owner = OVERLAY_OWNER, approval_policy = APPROVAL_POLICY,
        parameters = {}, allow = {packages = {COMPONENT}, namespaces = {"bee.app_journey_demo"},
            kinds = {"process.lua"}, databases = {}, grants = {}, modules = {"tty", "process", "channel", "json"}}}}
    act_entry.data = act_data

    local policy_entry = assert(registry.get("bee.approvals:approver_policies"))
    local policy_data = object(policy_entry.data)
    local policies = policy_data.policies :: {unknown}
    policies[#policies + 1] = {name = APPROVAL_POLICY, approvers = {"bee.app_journey.operator"}, max_ttl_ms = 60000}
    policy_data.policies = policies
    policy_entry.data = policy_data

    local changes = registry.snapshot():changes()
    assert(changes:update(pub_entry))
    assert(changes:update(act_entry))
    assert(changes:update(policy_entry))
    local applied, apply_error = changes:apply()
    if not applied then error("apply host delivery profiles: " .. tostring(apply_error)) end
end

local function main()
    if registry.get(DEFINITION_ID) then error("candidate must be absent before governed activation") end
    -- Admission is already bound by the host, and that binding alone admits
    -- nothing: the effective catalog carries no descriptor until the reviewed
    -- definition exists.
    if admitted_title() then error("admission binding admitted an application that does not exist") end

    local entries = {{id = DEFINITION_ID, kind = "process.lua", data = {source = APP_SOURCE, method = "main",
        modules = {"tty", "process", "channel", "json"}, imports = {client = "bee.application:client"}},
        meta = {type = "bee.application", application = {api_version = 1, lifetime = "view", revision = "1",
            title = APP_TITLE, instance_policy = "multiple", resume_schema = "app-journey.v1",
            restart_policy = "automatic"}}}}
    local measured, measure_error = artifact.create(entries)
    if not measured then error("measure app entries: " .. tostring(measure_error)) end
    local artifact_digest = digest_of(measured.digest, "authored artifact digest")

    -- Author into a governed workspace and freeze it, exactly as a person
    -- editing the source tree would.
    local create_res = call_api("bee.governance:workspace_call", {operation = "create",
        workspace_id = SOURCE_WORKSPACE, expected_revision = 0, idempotency_key = "create-" .. SOURCE_WORKSPACE})
    if create_res.revision ~= 1 then error("workspace create revision expected 1") end
    local put_res = call_api("bee.governance:workspace_call", {operation = "put", workspace_id = SOURCE_WORKSPACE,
        expected_revision = 1, idempotency_key = "put-entries-" .. SOURCE_WORKSPACE, path = "entries.json",
        content = json.encode(measured.entries)})
    if put_res.revision ~= 2 then error("workspace put revision expected 2") end
    local freeze_res = call_api("bee.governance:workspace_call", {operation = "freeze",
        workspace_id = SOURCE_WORKSPACE, expected_revision = 2, idempotency_key = "freeze-" .. SOURCE_WORKSPACE})
    local snapshot_digest = digest_of(freeze_res.digest, "frozen workspace digest")

    local workspace_id = tostring(uuid.v7())
    local local_node = assert(system.node.id())
    configure_host(workspace_id, local_node)

    local pub_res = call_api("bee.governance:publication_call", {operation = "prepare", workspace_id = workspace_id,
        component = COMPONENT, version = VERSION, snapshot_digest = snapshot_digest})
    local descriptor = object(pub_res.descriptor)
    local manifest = object(descriptor.manifest)
    if manifest.artifact_digest ~= artifact_digest then
        error("descriptor artifact digest does not match the authored artifact")
    end

    local available = call_api("bee.governance:destination_call", {operation = "available", workspace_id = workspace_id})
    local found = false
    for _, raw in ipairs(available.versions :: {unknown}) do
        local item = object(raw)
        if item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then error("prepared descriptor was not discoverable by the destination") end

    local stage_res = call_api("bee.governance:destination_call", {operation = "stage", workspace_id = workspace_id,
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. workspace_id})
    if stage_res.status ~= "staged" or stage_res.selected == true then error("staged plan is not staged-and-unselected") end

    -- The staged plan is the review surface: its exact artifact bytes and the
    -- destination's own preflight report, verified against its digest.
    local staged = call_api("bee.governance:destination_call", {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION})
    local plan_digest = digest_of(staged.plan_digest, "staged plan digest")
    if staged.artifact_digest ~= artifact_digest then error("staged plan carries another artifact digest") end
    local report, report_error = preflight.decode_report(staged.preflight_bytes, staged.preflight_digest)
    if not report then error("staged preflight report: " .. tostring(report_error)) end
    if report.ready ~= true or #report.diagnostics > 0 then
        error("staged plan preflight is not ready: " .. json.encode(report.diagnostics))
    end
    if #report.pending_migrations > 0 then error("staged plan preflight reports pending migrations") end

    local review_res = call_api("bee.governance:destination_call", {operation = "review", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION,
        expected_revision = staged.revision, idempotency_key = "review-" .. workspace_id,
        review_status = "accepted", review_reason = "app journey acceptance review"})
    if review_res.review_status ~= "accepted" then error("plan was not reviewed accepted") end

    local select_res = call_api("bee.governance:destination_call", {operation = "select", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION,
        expected_revision = review_res.revision, idempotency_key = "select-" .. workspace_id})
    if select_res.selected ~= true then error("plan was not selected") end

    local intent_id, receipt_key = "intent-" .. workspace_id, "receipt-" .. workspace_id
    local prepared = call_api("bee.governance:destination_call", {operation = "prepare", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION,
        intent_id = intent_id, receipt_key = receipt_key})
    if prepared.phase ~= "approval_bound" then error("prepared activation phase expected approval_bound") end
    local approval_id = bounds.id(prepared.approval_id)
    local proposal_digest = digest_of(prepared.approval_proposal_digest, "approval proposal digest")
    if not approval_id then error("prepare omitted the approval identity") end

    -- The decision is bound to this one proposal. The approvals owner refuses
    -- a decision offered against any other digest, so a decision carried over
    -- from other evidence cannot authorize this activation.
    local misdirected = reply_of("bee.approvals:decide", {approval_id = approval_id, expected_revision = 1,
        decision = "approved", proposal_digest = artifact_digest})
    if misdirected.ok == true then error("a decision on another proposal digest was accepted") end

    local pending = call_api("bee.governance:destination_call", {operation = "step", workspace_id = workspace_id,
        intent_id = intent_id, receipt_key = receipt_key})
    if pending.phase == "settled" or registry.get(DEFINITION_ID) then
        error("unapproved candidate was applied")
    end

    -- The person deciding is the same operator identity in this fixture;
    -- the decision itself is the real bee.approvals:decide call.
    call_api("bee.approvals:decide", {approval_id = approval_id, expected_revision = 1,
        decision = "approved", proposal_digest = proposal_digest})

    local stepped: Object = prepared
    for _ = 1, 8 do
        stepped = call_api("bee.governance:destination_call", {operation = "step", workspace_id = workspace_id,
            intent_id = intent_id, receipt_key = receipt_key})
        if stepped.phase == "settled" then break end
    end
    if stepped.phase ~= "settled" or stepped.outcome ~= "applied" then
        error("activation did not settle applied; phase=" .. tostring(stepped.phase) .. " outcome=" .. tostring(stepped.outcome))
    end

    -- The settled record is the fence's evidence: the composed base this
    -- overlay landed on is the one the owner reviewed and approved.
    local status = call_api("bee.governance:destination_call", {operation = "status",
        workspace_id = workspace_id, intent_id = intent_id})
    if status.plan_digest ~= plan_digest then error("settled activation records another plan digest") end
    -- The proposal the owner decided binds this authorization digest, which
    -- the activation store measures over the exact plan digest, plan revision
    -- and artifact, resolution and preflight digests.
    digest_of(status.authorization_digest, "activation authorization digest")
    if status.approval_proposal_digest ~= proposal_digest then error("settled activation bound another proposal") end
    -- The owner re-preflights locally before apply and keeps that report as
    -- durable evidence, with the transient registry revision normalized away;
    -- it is a second report over the same candidate, not the source's.
    local local_report, local_report_error = preflight.decode_report(status.preflight_bytes, status.preflight_digest)
    if not local_report then error("activation preflight report: " .. tostring(local_report_error)) end
    if local_report.ready ~= true or #local_report.diagnostics > 0 then
        error("activation preflight is not ready: " .. json.encode(local_report.diagnostics))
    end
    digest_of(status.resolution_digest, "activation resolution digest")
    -- The overlay slot is the activation owner's own receipt: it names the
    -- host-configured overlay owner and the intent that observed the apply.
    if status.overlay_owner ~= OVERLAY_OWNER then error("settled activation names another overlay owner") end
    if status.observed_intent_id ~= intent_id then error("overlay slot was not observed by this activation") end
    if status.observed_outcome ~= "applied" then error("overlay slot records outcome " .. tostring(status.observed_outcome)) end
    if status.consumed_proposal_digest ~= proposal_digest then error("settled activation consumed another proposal") end
    if status.observed_artifact_digest ~= artifact_digest then error("applied overlay observed another artifact") end
    if status.outcome ~= "applied" then error("settled activation outcome is " .. tostring(status.outcome)) end
    local incarnation = status.approval_owner_incarnation
    if type(incarnation) ~= "number" then error("settled activation recorded no approval incarnation") end

    -- One decision authorizes one effect. The activation owner already
    -- consumed it; no second effect may claim the same decision.
    local second = reply_of("bee.approvals:consume", {approval_id = approval_id, proposal_digest = proposal_digest,
        owner_incarnation = math.floor(incarnation :: number), effect_key = RETRY_EFFECT})
    if second.ok == true then error("a second effect consumed the same decision") end
    if fault_code(second) ~= "CONFLICT" then
        error("second consume refused with " .. fault_code(second) .. " instead of CONFLICT")
    end

    local app_entry = registry.get(DEFINITION_ID)
    if not app_entry then error("resulting registry entry " .. DEFINITION_ID .. " is missing") end
    if object(app_entry.data).source ~= APP_SOURCE then error("applied app source does not match the authored bytes") end
    local matches, match_error = materializer.matches(OVERLAY_OWNER, measured.entries)
    if matches ~= true then error("applied overlay differs from the reviewed artifact: " .. tostring(match_error)) end

    -- Overlay authority is the activation owner's alone. This caller drove
    -- the whole governed chain and still cannot materialize an overlay.
    local forced, force_error = materializer.reconcile("bee.app_journey_probe:forbidden_overlay", measured.entries)
    if forced then error("a caller outside the activation owner materialized an overlay") end
    if not force_error then error("the refused overlay write reported no reason") end

    -- The same effective catalog the application broker reads now carries the
    -- approved definition, so the host admits it.
    local title = admitted_title()
    if title ~= APP_TITLE then error("effective catalog does not admit the applied application") end

    logger:info("APP_JOURNEY_DELIVERED", {artifact_digest = artifact_digest, snapshot_digest = snapshot_digest,
        plan_digest = plan_digest, preflight_digest = staged.preflight_digest, proposal_digest = proposal_digest,
        workspace_id = workspace_id, admitted_title = title, overlay_owner = tostring(status.overlay_owner),
        refused_overlay_write = tostring(force_error)})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("APP_JOURNEY_FAILED", {error = tostring(err)})
        error(err)
    end
end}
