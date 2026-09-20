-- MIT. Real two-runtime generic binary and application-version replication over
-- the native Hive route. Receipt of v2 never selects it over v1.
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local io = require("io")
local system = require("system")
local types = require("types")
local client = require("client")
local funcs = require("funcs")
local registry = require("registry")
local hash = require("hash")
local base64 = require("base64")
local json = require("json")
local sender = require("sender")
local replicas = require("replicas")
local version = require("version")
local artifact = require("artifact")
local delivery = require("delivery")
local destination = require("destination")
local plan_store = require("plan_store")
local materializer = require("materializer")
local overlay_resolver = require("overlay_resolver")
local publisher = require("publisher")
local sync = require("sync")

local CONTENT = string.rep(string.char(0, 1, 127, 128, 255) .. "Bee replica payload\0", 6000)
local VERSION_KEY = "binary-v1"
local WORKER_KEY = "binary-worker-v1"
local MISMATCH_KEY = "binary-wrong-source"
local ACTIVATION_OVERLAY = "bee.replica_probe:activation_overlay"
-- This package does not exist on Hub. Its two versions are exact private
-- authoring artifacts and differ only in immutable source bytes.
local PACKAGE = "private/bee-demo"
local PACKAGE_V1 = "1.0.0"
local PACKAGE_V2 = "2.0.0"
local PRIVATE_ARTIFACTS: {[string]: artifact.Artifact} = {}
local AGENT_WORKSPACE = "agent-app-source"
local AGENT_PACKAGE = "bee.agent_app_demo/app"
local AGENT_VERSION = "2.0.0"
local AGENT_DEFINITION = "bee.agent_app_demo:app"
local AGENT_OVERLAY = "bee.replica_probe:activation_overlay"
local function object(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("expected object") end
    return value :: {[string]: unknown}
end
type AgentScenario = {workspace_id: string, artifact_digest: string}
local function agent_scenario(): AgentScenario?
    local entry = registry.get("bee.replica_probe:agent_scenario")
    if not entry then error("agent-artifact scenario entry is unavailable") end
    local data = object(entry.data)
    local workspace_id, artifact_digest = data.workspace_id, data.artifact_digest
    if workspace_id == "" and artifact_digest == "" then return nil end
    if type(workspace_id) ~= "string" or type(artifact_digest) ~= "string" then
        error("agent-artifact scenario is malformed")
    end
    local selected_workspace = workspace_id :: string
    local selected_digest = artifact_digest :: string
    if not selected_workspace:match("^[0-9a-f]+$") or #selected_workspace ~= 32
        or not selected_digest:match("^[0-9a-f]+$") or #selected_digest ~= 64 then error("agent-artifact scenario is malformed") end
    return {workspace_id = selected_workspace, artifact_digest = selected_digest}
end
local function exact_agent_artifact(scenario: AgentScenario): artifact.Artifact
    local entry = registry.get("bee.replica_probe:agent_artifact")
    if not entry then error("source agent artifact entry is unavailable") end
    local encoded = object(entry.data).encoded
    if type(encoded) ~= "string" or encoded == "" then error("source agent artifact bytes are unavailable") end
    local raw, decode_error = base64.decode(encoded)
    if not raw then error(tostring(decode_error or "decode source agent artifact")) end
    local parsed, parse_error = json.decode(raw)
    if parse_error then error("decode source agent artifact JSON: " .. tostring(parse_error)) end
    local document = object(parsed)
    local updated = object(document.updated)
    if updated.artifact_digest ~= scenario.artifact_digest then
        error("source agent artifact does not carry updated.artifact_digest")
    end
    local exact, exact_error = artifact.create(document.entries)
    if not exact then error(tostring(exact_error)) end
    if exact.digest ~= scenario.artifact_digest then
        error("production artifact.create did not reproduce updated.artifact_digest")
    end
    if #exact.entries ~= 1 then error("updated agent artifact must contain exactly one application") end
    local definition = object(exact.entries[1])
    local data, meta = object(definition.data), object(definition.meta)
    local application = object(meta.application)
    if definition.id ~= AGENT_DEFINITION or definition.kind ~= "process.lua" or type(data.source) ~= "string"
        or meta.type ~= "bee.application" or application.title ~= "Agent App" or application.revision ~= "2" then
        error("updated agent artifact is not the retained Agent App v2 definition")
    end
    return exact
end
local function descriptor(owner: string, key: string, content: string): version.Descriptor
    local content_digest, digest_error = hash.sha256(content)
    if not content_digest then error(tostring(digest_error)) end
    local item, create_error = version.create(owner, "replica-feed", key, "binary", "v1", content_digest,
        "test.binary", #content, {schema = "test.binary@1", bytes = #content})
    if not item then error(tostring(create_error)) end
    return item
end
local function map_subject(subject: string, enabled: boolean)
    local entry = registry.get("bee.hive.supervisor:principal_mappings")
    if not entry then error("principal mapping entry unavailable") end
    local mappings: {{[string]: unknown}} = {}
    if enabled then mappings[1] = {issuer = "node-1", subject_id = subject, policies = {"bee.replica_probe:replica_policy"}} end
    entry.data = {mappings = mappings}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, apply_error = changes:apply()
    if not applied then error(tostring(apply_error)) end
end
local function send(remote: string, item: version.Descriptor, content: string, cursor: integer?): {[string]: unknown}
    local result = sender.send(remote, item, content, {source_cursor = cursor or 1, timeout = "5s"})
    return result :: {[string]: unknown}
end
local function must(result: {[string]: unknown}, operation: string): {[string]: unknown}
    if result.ok ~= true then error(operation .. ": " .. tostring(result.code) .. ": " .. tostring(result.message)) end
    return object(result.value)
end
local function configure_exports()
    local entry = assert(registry.get("bee.sync:exports"))
    entry.data = {exports = {
        {feed = delivery.FEED, content_kinds = {delivery.CONTENT_KIND}},
        {feed = "replica-feed", content_kinds = {"test.binary"}},
    }}
    local changes = registry.snapshot():changes()
    assert(changes:update(entry)); assert(changes:apply())
end
local function publish_binary()
    local item = descriptor("node-1", WORKER_KEY, CONTENT)
    local replica_store = assert(replicas.open("bee.sync:db"))
    local begun = replicas.begin(replica_store, item, 0)
    must(begun :: {[string]: unknown}, "begin generic binary publication")
    local offset = 0
    while offset < #CONTENT do
        local ending = math.min(#CONTENT, offset + (replicas.MAX_CHUNK_BYTES :: integer))
        local encoded = assert(base64.encode(CONTENT:sub(offset + 1, ending)))
        must(replicas.put(replica_store, {source_owner = item.owner_id, feed = item.feed,
            version_key = item.key, descriptor_digest = item.digest}, offset, encoded) :: {[string]: unknown},
            "write generic binary publication")
        offset = ending
    end
    must(replicas.finish(replica_store, {source_owner = item.owner_id, feed = item.feed,
        version_key = item.key, descriptor_digest = item.digest}) :: {[string]: unknown},
        "finish generic binary publication")
    assert(replicas.close(replica_store))
    local feed = assert(sync.open({resource = "bee.sync:db", owner = "node-1"}))
    must(sync.append(feed, {feed = item.feed, event_id = item.digest,
        idempotency_key = item.digest, event_type = "test.binary.published", payload = item,
        projection_key = item.key, projection_value = item, expected_revision = 0}) :: {[string]: unknown},
        "append generic binary publication")
    assert(sync.close(feed))
end
local function private_artifact(selected_version: string): artifact.Artifact
    local cached = PRIVATE_ARTIFACTS[selected_version]
    if cached then return cached end
    local exact, exact_error = artifact.create({{id = "private.bee_demo:main", kind = "function.lua",
        data = {source = "return {main = function() return '" .. selected_version .. "' end}", method = "main"}}})
    if not exact then error(tostring(exact_error)) end
    PRIVATE_ARTIFACTS[selected_version] = exact
    return exact
end
local function application(selected_version: string): delivery.Delivery
    local exact = private_artifact(selected_version)
    local result, result_error = delivery.create({schema_revision = delivery.SCHEMA,
        source_node = "node-1", source_workspace = "shared/application", component = PACKAGE,
        version = selected_version, artifact = {bytes = exact.bytes, digest = exact.digest}})
    if not result then error(tostring(result_error)) end
    return result
end
local function application_descriptor(item: delivery.Delivery): version.Descriptor
    local result, err = delivery.descriptor(item)
    if not result then error(tostring(err)) end
    return result
end
local function governance_plans(): plan_store.Store
    local result, err = plan_store.open("bee.governance:db", "node-0", "workspace-node-0")
    if not result then error(tostring(err)) end
    return result
end
type HostPolicy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: unknown},
    migration_barrier: boolean}
local function stage_resolver(): destination.Resolver
    local policy_digest = assert(hash.sha256("replica-probe-destination-policy"))
    local resolved = overlay_resolver.new({overlay_owner = ACTIVATION_OVERLAY,
        root = function(raw: unknown): ({component: string, version: string}?, string?)
            local spec = object(raw)
            if spec.owner_node ~= "node-0" or spec.workspace_id ~= "workspace-node-0"
                or spec.source_node ~= "node-1" or spec.source_workspace ~= "shared/application"
                or type(spec.version) ~= "string" then
                return nil, "replica does not match the destination activation profile"
            end
            return {component = PACKAGE, version = spec.version}, nil
        end,
        policy = function(raw: unknown, _captured: unknown, _preview: unknown): (HostPolicy?, string?)
            local spec = object(raw)
            if spec.owner_node ~= "node-0" then return nil, "destination policy belongs to another node" end
            return {node_id = "node-0", policy_digest = policy_digest,
                packages = {[PACKAGE] = true}, namespaces = {["private.bee_demo"] = true},
                kinds = {["function.lua"] = true}, databases = {}, grants = {}, modules = {},
                applied = {}, migration_barrier = false}, nil
        end})
    return resolved :: destination.Resolver
end
local function required(result: {[string]: unknown}, operation: string): {[string]: unknown}
    if result.ok ~= true then error(operation .. ": " .. tostring(result.code) .. ": " .. tostring(result.message)) end
    return object(result.value)
end
local function destination_call(request: {[string]: unknown}, operation: string): {[string]: unknown}
    local raw, call_error = funcs.new():call("bee.governance:destination_call", request)
    if call_error then error(operation .. ": " .. tostring(call_error)) end
    return required(object(raw), operation)
end
local function configure_destination()
    local profiles = assert(registry.get("bee.governance:activation_profiles"))
    local configured_profiles = type(profiles.data) == "table" and object(profiles.data).profiles or nil
    local approvals = assert(registry.get("bee.approvals:approver_policies"))
    local configured_approvals = type(approvals.data) == "table" and object(approvals.data).policies or nil
    if type(configured_profiles) == "table" and #configured_profiles > 0
        and type(configured_approvals) == "table" and #configured_approvals > 0 then return end
    profiles.data = {profiles = {{workspace_id = "workspace-node-0", source_node = "node-1",
        source_workspace = "shared/application", component = PACKAGE, resolver = "overlay", overlay_owner = ACTIVATION_OVERLAY,
        approval_policy = "local-install", parameters = {}, allow = {
            packages = {PACKAGE}, namespaces = {"private.bee_demo"}, kinds = {"function.lua"},
            databases = {}, grants = {}, modules = {},
        }}}}
    approvals.data = {policies = {{name = "local-install", approvers = {"bee.replica_probe"}, max_ttl_ms = 60000}}}
    local changes = registry.snapshot():changes()
    assert(changes:update(profiles)); assert(changes:update(approvals)); assert(changes:apply())
end
local function configure_agent_destination(scenario: AgentScenario)
    -- The destination identity comes from a prior ordinary desktop boot. The
    -- source artifact cannot choose a workspace, an admission binding, or an
    -- activation policy. Trusted fixture setup installs this policy in source
    -- so the same ordinary desktop composition can recover it after the
    -- headless coordinator exits.
    local profiles = assert(registry.get("bee.governance:activation_profiles"))
    local approvals = assert(registry.get("bee.approvals:approver_policies"))
    local admission = assert(registry.get("bee:application_admission"))
    local configured_profiles = object(profiles.data).profiles
    if type(configured_profiles) ~= "table" or #configured_profiles ~= 1 then
        error("agent destination activation profile is unavailable")
    end
    local profile = object(configured_profiles[1])
    if profile.workspace_id ~= scenario.workspace_id or profile.source_node ~= "node-1"
        or profile.source_workspace ~= AGENT_WORKSPACE or profile.component ~= AGENT_PACKAGE
        or profile.resolver ~= "overlay" or profile.overlay_owner ~= AGENT_OVERLAY
        or profile.approval_policy ~= "local-agent-app-hive" then
        error("agent destination activation profile is not the trusted local policy")
    end
    local configured_approvals = object(approvals.data).policies
    if type(configured_approvals) ~= "table" or #configured_approvals ~= 1
        or object(configured_approvals[1]).name ~= "local-agent-app-hive" then
        error("agent destination approval policy is unavailable")
    end
    local admission_data = object(admission.data)
    local bindings = admission_data.bindings
    if type(bindings) ~= "table" then error("application admission bindings are unavailable") end
    local admitted = false
    for _, raw in ipairs(bindings :: {unknown}) do
        local binding = object(raw)
        if binding.definition_id == AGENT_DEFINITION then admitted = true end
    end
    if not admitted then error("Agent App is not admitted by the trusted destination policy") end
end
local function agent_available(scenario: AgentScenario): {[string]: unknown}?
    local result = destination_call({operation = "available", workspace_id = scenario.workspace_id},
        "list agent artifact through public destination call")
    local versions = result.versions
    if type(versions) ~= "table" then error("available agent artifacts are malformed") end
    for _, raw in ipairs(versions :: {unknown}) do
        local descriptor = object(raw)
        local manifest = object(descriptor.manifest)
        if descriptor.owner_id == "node-1" and descriptor.feed == delivery.FEED and descriptor.object_id == AGENT_PACKAGE
            and descriptor.version_id == AGENT_VERSION and manifest.source_workspace == AGENT_WORKSPACE
            and manifest.artifact_digest == scenario.artifact_digest then
            return descriptor
        end
    end
    return nil
end
local function exact_agent_overlay(scenario: AgentScenario, evidence: {[string]: unknown}): boolean
    if evidence.artifact_digest ~= scenario.artifact_digest then error("activation observed another agent artifact digest") end
    local entries, decode_error = artifact.decode(evidence.artifact_bytes, evidence.artifact_digest)
    if not entries then error(tostring(decode_error)) end
    local matches, match_error = materializer.matches(AGENT_OVERLAY, entries)
    if matches == nil then error(tostring(match_error)) end
    return matches
end
local function activate_agent_artifact(scenario: AgentScenario): {[string]: unknown}
    local identity: {[string]: unknown} = {workspace_id = scenario.workspace_id, source_node = "node-1",
        source_workspace = AGENT_WORKSPACE, version = AGENT_VERSION}
    local current = destination_call({operation = "get", workspace_id = identity.workspace_id,
        source_node = identity.source_node, source_workspace = identity.source_workspace, version = identity.version},
        "read staged agent artifact")
    current = destination_call({operation = "review", workspace_id = identity.workspace_id,
        source_node = identity.source_node, source_workspace = identity.source_workspace, version = identity.version,
        expected_revision = current.revision, idempotency_key = "agent-artifact-review", review_status = "accepted",
        review_reason = "destination reviewed retained Agent App v2"}, "review retained agent artifact")
    current = destination_call({operation = "select", workspace_id = identity.workspace_id,
        source_node = identity.source_node, source_workspace = identity.source_workspace, version = identity.version,
        expected_revision = current.revision, idempotency_key = "agent-artifact-select"}, "select retained agent artifact")
    if current.selected ~= true then error("destination did not select the retained agent artifact") end
    local prepared = destination_call({operation = "prepare", workspace_id = identity.workspace_id,
        source_node = identity.source_node, source_workspace = identity.source_workspace, version = identity.version,
        intent_id = "agent-artifact-activation", receipt_key = "agent-artifact-activation"},
        "prepare retained agent artifact")
    if prepared.phase ~= "approval_bound" then error("retained agent artifact did not bind a production approval") end
    local decided_raw, decide_error = funcs.new():call("bee.approvals:decide", {approval_id = prepared.approval_id,
        expected_revision = 1, decision = "approved", proposal_digest = prepared.approval_proposal_digest})
    if decide_error then error("decide retained agent artifact approval: " .. tostring(decide_error)) end
    required(object(decided_raw), "decide retained agent artifact approval")
    local settled: {[string]: unknown} = {}
    for _ = 1, 8 do
        settled = destination_call({operation = "step", workspace_id = identity.workspace_id,
            intent_id = "agent-artifact-activation", receipt_key = "agent-artifact-activation"},
            "apply retained agent artifact")
        if settled.phase == "settled" then break end
    end
    if settled.phase ~= "settled" or settled.outcome ~= "applied" or not exact_agent_overlay(scenario, settled) then
        error("retained agent artifact was not applied exactly")
    end
    return settled
end
local exact_application_overlay: (({[string]: unknown}) -> boolean)
local function application_runs(selected_version: string): boolean
    local result, call_error = funcs.new():call("private.bee_demo:main", {})
    return call_error == nil and result == selected_version
end
local function exact_application_runs(selected_version: string): boolean
    if not application_runs(selected_version) then
        error("activated private application did not return " .. selected_version)
    end
    return true
end
local function activate_version(selected_version: string, intent_id: string, receipt: string): {[string]: unknown}
    local identity: {[string]: unknown} = {workspace_id = "workspace-node-0", source_node = "node-1",
        source_workspace = "shared/application", version = selected_version}
    local current = destination_call({operation = "get", workspace_id = identity.workspace_id,
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = identity.version}, "read version before activation")
    if current.review_status ~= "accepted" then
        current = destination_call({operation = "review", workspace_id = identity.workspace_id,
            source_node = identity.source_node, source_workspace = identity.source_workspace,
            version = identity.version, expected_revision = current.revision,
            idempotency_key = receipt .. "-review", review_status = "accepted",
            review_reason = "destination reviewed explicit version"}, "review version")
    end
    if current.selected ~= true then
        current = destination_call({operation = "select", workspace_id = identity.workspace_id,
            source_node = identity.source_node, source_workspace = identity.source_workspace,
            version = identity.version, expected_revision = current.revision,
            idempotency_key = receipt .. "-select"}, "select version")
    end
    local prepared = destination_call({operation = "prepare", workspace_id = identity.workspace_id,
        source_node = identity.source_node, source_workspace = identity.source_workspace,
        version = identity.version, intent_id = intent_id, receipt_key = receipt}, "prepare version")
    local decided_raw, decide_error = funcs.new():call("bee.approvals:decide", {approval_id = prepared.approval_id,
        expected_revision = 1, decision = "approved", proposal_digest = prepared.approval_proposal_digest})
    if decide_error then error("decide version approval: " .. tostring(decide_error)) end
    required(object(decided_raw), "decide version approval")
    local value = prepared
    for _ = 1, 8 do
        value = destination_call({operation = "step", workspace_id = identity.workspace_id,
            intent_id = intent_id, receipt_key = receipt}, "activate version")
        if value.phase == "settled" then break end
    end
    if value.phase ~= "settled" or value.outcome ~= "applied" or value.version ~= selected_version
        or not exact_application_overlay(value) then error("explicit version activation did not apply exactly") end
    return value
end
exact_application_overlay = function(evidence: {[string]: unknown}): boolean
    local entries, decode_error = artifact.decode(evidence.artifact_bytes, evidence.artifact_digest)
    if not entries then error(tostring(decode_error)) end
    local matches, match_error = materializer.matches(ACTIVATION_OVERLAY, entries)
    if matches == nil then error(tostring(match_error)) end
    return matches
end
local function stop(pid: string)
    assert(process.cancel(pid))
    local events = assert(process.events())
    local deadline = time.after("5s")
    local selected = channel.select({events:case_receive(), deadline:case_receive()})
    if not selected.ok or selected.channel == deadline then error("supervisor did not stop") end
    local event = selected.value
    if event.kind ~= process.event.EXIT or tostring(event.from) ~= pid then error("wrong supervisor stop event") end
end
local function main(remote: string)
    local local_node = assert(system.node.id())
    local agent = agent_scenario()
    if local_node == "node-0" then
        if agent then configure_agent_destination(agent) else configure_destination() end
    else configure_exports() end
    local policies = {}
	for _, name in ipairs({"bee:hive_supervisor_policy", "bee:hive_catalog_policy", "bee:hive_exposure_policy", "bee:hive_policy_exposure_policy",
        "bee:hive_dispatch_policy", "bee.replica_probe:names_policy", "bee.replica_probe:execute_policy"}) do
        local policy, policy_error = security.policy(name)
        if not policy then error("load supervisor policy " .. name .. ": " .. tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local function start(): string
        local pid = tostring(assert(process.with_options({}):with_scope(security.new_scope(policies))
            :spawn_monitored("bee.hive.supervisor:main", types.SUPERVISOR_HOST, {configured_nodes = {remote}})))
        local deadline = time.now():add("60s")
        while time.now():before(deadline) do
            if client.supervisor() == pid then return pid end
            time.sleep("10ms")
        end
        error("supervisor did not register its local name")
    end
    local supervisor = start()
    assert(io.print("BEE_HIVE_SUPERVISOR ready " .. tostring(assert(system.node.addr()))))
    while true do
        local command = tostring(assert(io.readline()))
        if command == "identity" then
            assert(io.print("BEE_HIVE_SUPERVISOR identity " .. tostring(process.pid())))
        elseif command:match("^enroll ") then
            map_subject(command:sub(8), true)
            assert(io.print("BEE_HIVE_SUPERVISOR enrolled"))
        elseif command == "revoke" then
            map_subject(remote, false)
            assert(io.print("BEE_HIVE_SUPERVISOR revoked"))
        elseif command == "probe" then
            local mesh, open_error = client.open()
            if not mesh then error(tostring(open_error)) end
            local deadline = time.now():add("60s")
            local reply: types.Reply? = nil
            while time.now():before(deadline) do
                reply = mesh:call({node_id = remote, service_id = "bee.hive.telemetry"},
                    {operation_ref = "bee.hive.telemetry:presence"}, {}, {timeout = "1s"})
                if reply.ok then break end
                time.sleep("100ms")
            end
            mesh:close()
            if not reply then error("remote supervisor never established: no reply") end
            if not reply.ok then
                local peer, lookup_error = process.registry.lookup(types.SUPERVISOR_NAME .. "/" .. remote)
                error("remote supervisor never established: " .. tostring(reply.error.code) .. ": " .. tostring(reply.error.message)
                    .. "; registry=" .. tostring(peer) .. ": " .. tostring(lookup_error))
            end
            local value = object(reply.value)
            if value.node_id ~= remote then error("telemetry executed on wrong node") end
            assert(io.print("BEE_HIVE_SUPERVISOR probe_passed"))
        elseif command == "replica-unmapped" then
            local item = descriptor("node-1", VERSION_KEY, CONTENT)
            local result = send(remote, item, CONTENT)
            if not result.ok then error("authenticated node-owned replica was not admitted: " .. tostring(result.code) .. ": " .. tostring(result.message)) end
            assert(io.print("BEE_HIVE_SUPERVISOR replica_unmapped"))
        elseif command == "replica-source-mismatch" then
            local item = descriptor("node-2", MISMATCH_KEY, CONTENT)
            local result = send(remote, item, CONTENT)
            if result.ok or result.code ~= "DENIED" then error("source-owner policy was not exact: " .. tostring(result.code) .. ": " .. tostring(result.message)) end
            assert(io.print("BEE_HIVE_SUPERVISOR replica_source_mismatch"))
        elseif command == "replica-send" then
            local item = descriptor("node-1", VERSION_KEY, CONTENT)
            local result = send(remote, item, CONTENT)
            if not result.ok then error("replica transfer failed: " .. tostring(result.code) .. ": " .. tostring(result.message)) end
            assert(io.print("BEE_HIVE_SUPERVISOR replica_sent"))
        elseif command == "replica-read" then
            local item = descriptor("node-1", VERSION_KEY, CONTENT)
            local store, open_error = replicas.open("bee.sync:db")
            if not store then error(tostring(open_error)) end
            local content, content_error = replicas.content(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            replicas.close(store)
            if content_error or content ~= CONTENT then error("replica content was not exact after restart") end
            assert(io.print("BEE_HIVE_SUPERVISOR replica_exact"))
        elseif command == "replica-publish" then
            publish_binary()
            assert(io.print("BEE_HIVE_SUPERVISOR replica_published"))
        elseif command == "replica-available" then
            local item = descriptor("node-1", WORKER_KEY, CONTENT)
            local deadline = time.now():add("30s")
            local found = false
            while time.now():before(deadline) do
                local store = assert(replicas.open("bee.sync:db"))
                local content = replicas.content(store, {source_owner = item.owner_id, feed = item.feed,
                    version_key = item.key, descriptor_digest = item.digest})
                assert(replicas.close(store))
                if content == CONTENT then found = true; break end
                time.sleep("100ms")
            end
            if not found then error("generic Sync worker did not transfer the binary content kind") end
            assert(io.print("BEE_HIVE_SUPERVISOR replica_available"))
        elseif command == "application-send-v1" or command == "application-send-v2" then
            local selected_version = string.sub(command, -2) == "v1" and PACKAGE_V1 or PACKAGE_V2
            local item = application(selected_version)
            local result = send(remote, application_descriptor(item), item.bytes, selected_version == PACKAGE_V1 and 2 or 3)
            if not result.ok then error("application transfer failed: " .. tostring(result.code) .. ": " .. tostring(result.message)) end
            assert(io.print("BEE_HIVE_SUPERVISOR application_sent_" .. (selected_version == PACKAGE_V1 and "v1" or "v2")))
        elseif command == "application-publish-v1" or command == "application-publish-v2" then
            local label = string.sub(command, -2)
            local selected_version = label == "v1" and PACKAGE_V1 or PACKAGE_V2
            local exact = private_artifact(selected_version)
            local result = publisher.publish("bee.sync:db", "node-1", {source_workspace = "shared/application",
                component = PACKAGE, version = selected_version,
                artifact = {bytes = exact.bytes, digest = exact.digest}})
            required(result :: {[string]: unknown}, "publish application " .. selected_version)
            assert(io.print("BEE_HIVE_SUPERVISOR application_published_" .. label))
        elseif command == "application-available-v1" or command == "application-available-v2" then
            local label = string.sub(command, -2)
            local selected_version = label == "v1" and PACKAGE_V1 or PACKAGE_V2
            local expected = application_descriptor(application(selected_version))
            local deadline = time.now():add("30s")
            local found = false
            while time.now():before(deadline) do
                local result = destination_call({operation = "available", workspace_id = "workspace-node-0"},
                    "list available applications")
                local versions = result.versions
                if type(versions) == "table" then
                    for _, raw in ipairs(versions :: {unknown}) do
                        local item = object(raw)
                        if item.digest == expected.digest and item.key == expected.key then found = true; break end
                    end
                end
                if found then break end
                time.sleep("100ms")
            end
            if not found then error("published application did not become available") end
            assert(io.print("BEE_HIVE_SUPERVISOR application_available_" .. label))
        elseif command == "application-stage-public-v1" or command == "application-stage-public-v2" then
            local label = string.sub(command, -2)
            local selected_version = label == "v1" and PACKAGE_V1 or PACKAGE_V2
            local descriptor_value = application_descriptor(application(selected_version))
            local value = destination_call({operation = "stage", workspace_id = "workspace-node-0",
                source_owner = descriptor_value.owner_id, feed = descriptor_value.feed,
                version_key = descriptor_value.key, descriptor_digest = descriptor_value.digest,
                idempotency_key = "stage-public-" .. label}, "stage published application " .. selected_version)
            if value.selected == true or value.status ~= "staged" then error("publication selected an application version") end
            assert(io.print("BEE_HIVE_SUPERVISOR application_staged_public_" .. label))
        elseif command == "application-stage-v1" or command == "application-stage-v2" then
            local label = string.sub(command, -2)
            local selected_version = label == "v1" and PACKAGE_V1 or PACKAGE_V2
            local item = application(selected_version)
            local descriptor_value = application_descriptor(item)
            local replica_store, replica_error = replicas.open("bee.sync:db")
            if not replica_store then error(tostring(replica_error)) end
            local plans = governance_plans()
            local staged = destination.stage_replica(plans, replica_store, "destination-reviewer", {
                source_owner = descriptor_value.owner_id, feed = descriptor_value.feed,
                version_key = descriptor_value.key, descriptor_digest = descriptor_value.digest,
                idempotency_key = "stage-" .. label}, stage_resolver(), PACKAGE)
            assert(plan_store.close(plans)); assert(replicas.close(replica_store))
            local value = required(staged, "stage application " .. selected_version)
            if value.selected == true or value.status ~= "staged" then error("replication selected an application version") end
            assert(io.print("BEE_HIVE_SUPERVISOR application_staged_" .. label))
        elseif command == "application-select-v1" then
            destination_call({operation = "review", workspace_id = "workspace-node-0", source_node = "node-1",
                source_workspace = "shared/application", version = PACKAGE_V1, expected_revision = 1,
                idempotency_key = "review-v1", review_status = "accepted",
                review_reason = "destination reviewed v1"}, "review application v1")
            local selected = destination_call({operation = "select", workspace_id = "workspace-node-0",
                source_node = "node-1", source_workspace = "shared/application", version = PACKAGE_V1,
                expected_revision = 2, idempotency_key = "select-v1"}, "select application v1")
            if selected.selected ~= true then error("destination did not select v1") end
            assert(io.print("BEE_HIVE_SUPERVISOR application_selected_v1"))
        elseif command == "application-approve-v1" then
            local value = destination_call({operation = "prepare", workspace_id = "workspace-node-0",
                source_node = "node-1", source_workspace = "shared/application", version = PACKAGE_V1,
                intent_id = "activation-v1", receipt_key = "activation-v1"}, "prepare activation v1")
            if value.phase ~= "approval_bound" or value.version ~= PACKAGE_V1 then error("v1 activation did not request approval") end
            local decided_raw, decide_error = funcs.new():call("bee.approvals:decide", {approval_id = value.approval_id,
                expected_revision = 1, decision = "approved", proposal_digest = value.approval_proposal_digest})
            if decide_error then error("decide activation approval: " .. tostring(decide_error)) end
            required(object(decided_raw), "decide activation approval")
            assert(io.print("BEE_HIVE_SUPERVISOR application_approved_v1"))
        elseif command == "application-apply-v1" then
            local value: {[string]: unknown} = {}
            for _ = 1, 8 do
                value = destination_call({operation = "step", workspace_id = "workspace-node-0",
                    intent_id = "activation-v1", receipt_key = "activation-v1"}, "activation step")
                if value.phase == "settled" then break end
            end
            if value.phase ~= "settled" or value.outcome ~= "applied" then error("v1 activation did not apply") end
            if not exact_application_overlay(value) or not exact_application_runs(PACKAGE_V1) then
                error("v1 activation did not expose the exact private application")
            end
            assert(io.print("BEE_HIVE_SUPERVISOR application_applied_v1"))
        elseif command == "application-restored-v1" then
            local deadline = time.now():add("30s")
            while time.now():before(deadline) and not application_runs(PACKAGE_V1) do time.sleep("100ms") end
            if not application_runs(PACKAGE_V1) then
                error("destination runtime relaunch did not automatically restore the v1 overlay")
            end
            assert(io.print("BEE_HIVE_SUPERVISOR application_restored_v1"))
        elseif command == "application-current-v1" then
            local v1 = destination_call({operation = "get", workspace_id = "workspace-node-0",
                source_node = "node-1", source_workspace = "shared/application", version = PACKAGE_V1}, "read application v1")
            local v2 = destination_call({operation = "get", workspace_id = "workspace-node-0",
                source_node = "node-1", source_workspace = "shared/application", version = PACKAGE_V2}, "read application v2")
            if v1.selected ~= true or v2.selected == true or v2.status ~= "staged" then
                error("staged v2 changed the destination's v1 selection")
            end
            assert(io.print("BEE_HIVE_SUPERVISOR application_current_v1"))
        elseif command == "application-update-v2" then
            activate_version(PACKAGE_V2, "activation-v2", "activation-v2")
            if not exact_application_runs(PACKAGE_V2) then error("private application did not run v2") end
            assert(io.print("BEE_HIVE_SUPERVISOR application_updated_v2"))
        elseif command == "application-rollback-v1" then
            activate_version(PACKAGE_V1, "activation-v1-rollback", "activation-v1-rollback")
            if not exact_application_runs(PACKAGE_V1) then error("private application did not roll back to v1") end
            assert(io.print("BEE_HIVE_SUPERVISOR application_rolled_back_v1"))
        elseif command == "agent-artifact-publish" then
            if not agent or local_node ~= "node-1" then error("agent artifact publication belongs only to the configured source") end
            local exact = exact_agent_artifact(agent)
            local result = publisher.publish("bee.sync:db", "node-1", {source_workspace = AGENT_WORKSPACE,
                component = AGENT_PACKAGE, version = AGENT_VERSION, artifact = {bytes = exact.bytes, digest = exact.digest}})
            required(result :: {[string]: unknown}, "publish retained agent artifact")
            assert(io.print("BEE_HIVE_SUPERVISOR agent_artifact_published"))
        elseif command == "agent-artifact-absent" then
            if not agent or local_node ~= "node-0" then error("agent artifact absence belongs only to the configured destination") end
            if agent_available(agent) or registry.get(AGENT_DEFINITION) then
                error("destination held the agent artifact before source publication")
            end
            assert(io.print("BEE_HIVE_SUPERVISOR agent_artifact_absent"))
        elseif command == "agent-artifact-available" then
            if not agent or local_node ~= "node-0" then error("agent artifact availability belongs only to the configured destination") end
            local deadline = time.now():add("30s")
            local descriptor: {[string]: unknown}? = nil
            while time.now():before(deadline) do
                descriptor = agent_available(agent)
                if descriptor then break end
                time.sleep("100ms")
            end
            if not descriptor then error("retained agent artifact did not become available through Hive") end
            assert(io.print("BEE_HIVE_SUPERVISOR agent_artifact_available"))
        elseif command == "agent-artifact-stage" then
            if not agent or local_node ~= "node-0" then error("agent artifact staging belongs only to the configured destination") end
            local descriptor = agent_available(agent)
            if not descriptor then error("retained agent artifact is not available to stage") end
            local staged = destination_call({operation = "stage", workspace_id = agent.workspace_id,
                source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
                descriptor_digest = descriptor.digest, idempotency_key = "stage-retained-agent-artifact"},
                "stage retained agent artifact through public destination call")
            if staged.status ~= "staged" or staged.selected == true or staged.artifact_digest ~= agent.artifact_digest then
                error("retained agent artifact stage did not preserve the exact unselected candidate")
            end
            assert(io.print("BEE_HIVE_SUPERVISOR agent_artifact_staged"))
        elseif command == "agent-artifact-apply" then
            if not agent or local_node ~= "node-0" then error("agent artifact activation belongs only to the configured destination") end
            activate_agent_artifact(agent)
            assert(io.print("BEE_HIVE_SUPERVISOR agent_artifact_applied"))
        elseif command == "stop" then
            stop(supervisor)
            assert(io.print("BEE_HIVE_SUPERVISOR stopped"))
            return
        else error("unexpected command " .. command) end
    end
end
return {main = main}
