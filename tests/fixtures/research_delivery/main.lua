-- SPDX-License-Identifier: MIT
-- Bounded Bee acceptance fixture for research delivery.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local json = require("json")
local io = require("io")
local uuid = require("uuid")
local bounds = require("bounds")
local artifact = require("artifact")
local materializer = require("materializer")
local recovery = require("recovery")
local time = require("time")

type Object = {[string]: unknown}

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected object value") end
    return decoded
end

local function call_api(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    local reply = object(result)
    if reply.ok ~= true then
        error(target .. " returned error: " .. tostring(reply.code) .. ": " .. tostring(reply.message or json.encode(reply.error)))
    end
    local val = bounds.object(reply.value)
    if not val then error(target .. " missing value") end
    return val
end

local function recover()
    time.sleep("3s")
    local input = assert(registry.get("bee.research_delivery:artifact_input"))
    local parsed = object(json.decode(tostring(object(input.data).raw_json)))
    local measured = assert(artifact.create(parsed.entries))
    local matches, match_error = materializer.matches("bee.research_delivery:activation_overlay", measured.entries)
    if matches ~= true then
        local states = system.supervisor.states()
        for _, state in ipairs(states or {}) do
            if tostring(state.id) == "bee.governance:activation_recovery_service" then
                io.print("RESEARCH_RECOVERY_SERVICE " .. tostring(json.encode(state)))
            end
        end
        local restored, problem = recovery.recover_all()
        error("automatic recovery absent; explicit diagnostic recovery=" .. tostring(restored) .. ": " .. tostring(problem or match_error))
    end
    io.print("RESEARCH_RECOVERY_PASS " .. measured.digest)
end

local function main()
    -- Read supplied artifact from registry entry
    local input_entry = registry.get("bee.research_delivery:artifact_input")
    if not input_entry then error("missing bee.research_delivery:artifact_input entry") end
    local input_data = object(input_entry.data)
    local raw_json = input_data.raw_json
    if type(raw_json) ~= "string" or #raw_json == 0 then
        error("artifact raw_json missing or empty")
    end
    local parsed_raw, parse_err = json.decode(raw_json)
    if parse_err or type(parsed_raw) ~= "table" then
        error("failed to parse artifact raw_json: " .. tostring(parse_err))
    end
    local parsed_artifact = object(parsed_raw)
    local supplied_digest = bounds.id(parsed_artifact.artifact_digest)
    if not supplied_digest or #supplied_digest ~= 64 then
        error("artifact_digest missing or invalid in supplied artifact")
    end
    local raw_entries = parsed_artifact.entries
    if type(raw_entries) ~= "table" then
        error("entries list missing in supplied artifact")
    end

    -- Strictly preserve artifact entries byte values and verify digest
    local measured, measure_err = artifact.create(raw_entries)
    if not measured then
        error("failed to measure artifact entries: " .. tostring(measure_err))
    end
    if measured.digest ~= supplied_digest then
        error("measured artifact digest " .. tostring(measured.digest) .. " does not match supplied " .. supplied_digest)
    end

    -- Record expected source bytes for later registry verification
    local expected_app_source: string? = nil
    local expected_canonical_source: string? = nil
    for _, raw_entry in ipairs(measured.entries) do
        local item = object(raw_entry)
        local id = bounds.id(item.id)
        if id == "bee.research.demo:app" and item.kind == "process.lua" then
            expected_app_source = object(item.data).source :: string
        elseif id == "bee.research.demo:canonical" and item.kind == "library.lua" then
            expected_canonical_source = object(item.data).source :: string
        end
    end
    if not expected_app_source or not expected_canonical_source then
        error("artifact missing required bee.research.demo:app or bee.research.demo:canonical entry")
    end

    if registry.get("bee.research.demo:app") or registry.get("bee.research.demo:canonical") then
        error("candidate must be absent before governed activation")
    end
    local SOURCE_WORKSPACE = "research-performance"

    -- 1 overlay_call create/put entries.json/freeze (test operator actor);
    --   returned snapshot_digest is a new file snapshot, distinct from original artifact digest.
    --   Keep exact entries so artifact digest remains same.
    local create_res = call_api("bee.governance:overlay_call", {
        operation = "create",
        overlay_id = SOURCE_WORKSPACE,
        expected_revision = 0,
        idempotency_key = "create-" .. SOURCE_WORKSPACE,
    })
    assert(create_res.revision == 1, "create revision expected 1")

    local entries_json = json.encode(measured.entries)
    local put_res = call_api("bee.governance:overlay_call", {
        operation = "put",
        overlay_id = SOURCE_WORKSPACE,
        expected_revision = 1,
        idempotency_key = "put-entries-" .. SOURCE_WORKSPACE,
        path = "entries.json",
        content = entries_json,
    })
    assert(put_res.revision == 2, "put revision expected 2")

    local freeze_res = call_api("bee.governance:overlay_call", {
        operation = "freeze",
        overlay_id = SOURCE_WORKSPACE,
        expected_revision = 2,
        idempotency_key = "freeze-" .. SOURCE_WORKSPACE,
    })
    local snapshot_digest = bounds.id(freeze_res.digest)
    if not snapshot_digest or #snapshot_digest ~= 64 then
        error("freeze omitted or returned invalid snapshot digest")
    end
    assert(snapshot_digest ~= measured.digest,
        "returned snapshot_digest is a new file snapshot, distinct from original artifact digest")

    -- 2 Host publication_profiles binding actual test workspace UUID,
    --   source_workspace fixed research-performance, component bee.research.demo/app,
    --   overlay_owner host chosen.
    local test_workspace_uuid = tostring(uuid.v7())
    local COMPONENT = "bee.research.demo/app"
    local OVERLAY_OWNER = "bee.research_delivery:activation_overlay"
    local APPROVAL_POLICY = "local-research-delivery"
    local VERSION = "1.0.0"
    local local_node = assert(system.node.id())

    local pub_entry = assert(registry.get("bee.governance:publication_profiles"))
    local pub_data = object(pub_entry.data) or {}
    pub_data.profiles = {
        {
            workspace_id = test_workspace_uuid,
            source_workspace = SOURCE_WORKSPACE,
            component = COMPONENT,
            overlay_owner = OVERLAY_OWNER,
        },
    }
    pub_entry.data = pub_data

    -- 3 host activation profile narrow namespace bee.research.demo,
    --   allowed kinds library.lua/process.lua, explicit approval policy and overlay owner.
    local act_entry = assert(registry.get("bee.governance:activation_profiles"))
    local act_data = object(act_entry.data) or {}
    act_data.profiles = {
        {
            workspace_id = test_workspace_uuid,
            source_node = local_node,
            source_workspace = SOURCE_WORKSPACE,
            component = COMPONENT,
            resolver = "overlay",
            overlay_owner = OVERLAY_OWNER,
            approval_policy = APPROVAL_POLICY,
            parameters = {},
            allow = {
                packages = {COMPONENT},
                namespaces = {"bee.research.demo"},
                kinds = {"library.lua", "process.lua", "function.lua"},
                databases = {},
                grants = {},
                modules = {"channel", "funcs", "json", "process", "time", "tty", "uuid"},
            },
        },
    }
    act_entry.data = act_data

    local app_entry = assert(registry.get("bee.approvals:approver_policies"))
    local app_data = object(app_entry.data) or {}
    local app_policies = app_data.policies
    if type(app_policies) ~= "table" then error("host approval policies missing") end
    app_policies[#app_policies + 1] = {
        name = APPROVAL_POLICY,
        approvers = {"bee.research_delivery.operator"},
        max_ttl_ms = 60000,
    }
    app_data.policies = app_policies
    app_entry.data = app_data

    local changes = registry.snapshot():changes()
    assert(changes:update(pub_entry))
    assert(changes:update(act_entry))
    assert(changes:update(app_entry))
    local applied, apply_err = changes:apply()
    if not applied then error("failed to apply host profiles: " .. tostring(apply_err)) end

    -- publication_call prepare {operation,workspace_id,component,version,snapshot_digest}.
    -- Verify descriptor manifest artifact_digest matches supplied artifact.
    local pub_res = call_api("bee.governance:publication_call", {
        operation = "prepare",
        workspace_id = test_workspace_uuid,
        component = COMPONENT,
        version = VERSION,
        snapshot_digest = snapshot_digest,
    })

    local descriptor = object(pub_res.descriptor)
    local manifest = object(descriptor.manifest)
    assert(manifest.artifact_digest == measured.digest,
        "descriptor manifest artifact_digest " .. tostring(manifest.artifact_digest) .. " does not match artifact " .. measured.digest)

    -- destination_call available -> stage using returned descriptor/source_owner/feed/version_key/descriptor_digest
    -- -> review accepted -> select -> prepare intent/receipt.
    local avail_res = call_api("bee.governance:destination_call", {
        operation = "available",
        workspace_id = test_workspace_uuid,
    })
    local versions = avail_res.versions
    if type(versions) ~= "table" then error("available returned invalid versions list") end
    local found_desc = false
    for _, v_raw in ipairs(versions :: {unknown}) do
        local v = object(v_raw)
        if v.key == descriptor.key and v.digest == descriptor.digest then
            found_desc = true
            break
        end
    end
    assert(found_desc, "prepared descriptor was not listed in destination available versions")

    local stage_res = call_api("bee.governance:destination_call", {
        operation = "stage",
        workspace_id = test_workspace_uuid,
        source_owner = descriptor.owner_id,
        feed = descriptor.feed,
        version_key = descriptor.key,
        descriptor_digest = descriptor.digest,
        idempotency_key = "stage-" .. test_workspace_uuid,
    })
    assert(stage_res.status == "staged", "staged version status expected 'staged'")
    assert(stage_res.selected ~= true, "staged version must not be selected")
    local stage_rev = stage_res.revision :: integer

    local review_res = call_api("bee.governance:destination_call", {
        operation = "review",
        workspace_id = test_workspace_uuid,
        source_node = descriptor.owner_id,
        source_workspace = SOURCE_WORKSPACE,
        version = VERSION,
        expected_revision = stage_rev,
        idempotency_key = "review-" .. test_workspace_uuid,
        review_status = "accepted",
        review_reason = "Test operator acceptance review",
    })
    assert(review_res.review_status == "accepted", "review_status expected 'accepted'")
    local review_rev = review_res.revision :: integer

    local select_res = call_api("bee.governance:destination_call", {
        operation = "select",
        workspace_id = test_workspace_uuid,
        source_node = descriptor.owner_id,
        source_workspace = SOURCE_WORKSPACE,
        version = VERSION,
        expected_revision = review_rev,
        idempotency_key = "select-" .. test_workspace_uuid,
    })
    assert(select_res.selected == true, "plan selected expected true")

    local intent_id = "intent-" .. test_workspace_uuid
    local receipt_key = "receipt-" .. test_workspace_uuid
    local prep_res = call_api("bee.governance:destination_call", {
        operation = "prepare",
        workspace_id = test_workspace_uuid,
        source_node = descriptor.owner_id,
        source_workspace = SOURCE_WORKSPACE,
        version = VERSION,
        intent_id = intent_id,
        receipt_key = receipt_key,
    })
    assert(prep_res.phase == "approval_bound", "prepared activation phase expected 'approval_bound'")
    local approval_id = bounds.id(prep_res.approval_id)
    local proposal_digest = bounds.id(prep_res.approval_proposal_digest)
    if not approval_id or not proposal_digest then
        error("prepare omitted approval_id or approval_proposal_digest")
    end

    local pending = call_api("bee.governance:destination_call", {operation = "step",
        workspace_id = test_workspace_uuid, intent_id = intent_id, receipt_key = receipt_key})
    if pending.phase == "settled" or registry.get("bee.research.demo:app") then
        error("unapproved candidate was applied")
    end

    -- 4 TEST OPERATOR decides exact approval_id/proposal_digest (never expose this to Gemini).
    --   destination_call step until settled applied.
    call_api("bee.approvals:decide", {
        approval_id = approval_id,
        expected_revision = 1,
        decision = "approved",
        proposal_digest = proposal_digest,
    })

    local stepped: Object = prep_res
    for _ = 1, 8 do
        stepped = call_api("bee.governance:destination_call", {
            operation = "step",
            workspace_id = test_workspace_uuid,
            intent_id = intent_id,
            receipt_key = receipt_key,
        })
        if stepped.phase == "settled" then break end
    end

    assert(stepped.phase == "settled", "activation did not reach settled phase; got: " .. tostring(stepped.phase))
    assert(stepped.outcome == "applied", "activation outcome expected 'applied'; got: " .. tostring(stepped.outcome))

    -- Verify resulting registry library and process source bytes match entries
    local app_entry = registry.get("bee.research.demo:app")
    assert(app_entry, "resulting registry entry bee.research.demo:app missing")
    assert(app_entry.kind == "process.lua", "bee.research.demo:app kind mismatch")
    assert(object(app_entry.data).source == expected_app_source, "bee.research.demo:app source bytes mismatch")
    local effective = assert(registry.snapshot())
    local snap_app, snap_error = effective:get("bee.research.demo:app")
    if not snap_app then error("installed app absent from native registry snapshot: " .. tostring(snap_error)) end
    assert(object(snap_app.data).source == expected_app_source, "snapshot app source differs from direct registry read")

    local canonical_entry = registry.get("bee.research.demo:canonical")
    assert(canonical_entry, "resulting registry entry bee.research.demo:canonical missing")
    assert(canonical_entry.kind == "library.lua", "bee.research.demo:canonical kind mismatch")
    assert(object(canonical_entry.data).source == expected_canonical_source, "bee.research.demo:canonical source bytes mismatch")

    local matches, match_error = materializer.matches(OVERLAY_OWNER, measured.entries)
    if matches ~= true then error("applied overlay differs from reviewed artifact: " .. tostring(match_error)) end

    if registry.get("bee.research_measurement:inputs") then
        local result, result_error = funcs.call("bee.research_measurement:probe", {})
        if result_error then error("measurement probe: " .. tostring(result_error)) end
        local checked = object(result)
        if checked.ok ~= true then error("measurement probe failed") end
        io.print("RESEARCH_MEASUREMENT_PASS " .. tostring(json.encode(checked)))
    end

    -- Report actual final phase and digests. No UI launch claim yet; parent extends after this.
    local report_data = {
        passed = true,
        phase = stepped.phase,
        outcome = stepped.outcome,
        workspace_id = test_workspace_uuid,
        artifact_digest = measured.digest,
        snapshot_digest = snapshot_digest,
        proposal_digest = proposal_digest,
        plan_digest = stepped.plan_digest,
    }
    io.print("RESEARCH_DELIVERY_PASS " .. tostring(json.encode(report_data)))
end

return {main = main, recover = recover}
