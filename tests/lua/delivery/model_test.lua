-- MIT. App Delivery presents destination-owned state and emits only facade requests.
local test = require("test")
local model = require("model")
local caller = require("caller")
local preflight = require("preflight")

local function reply(value: unknown): caller.Reply
    local result = caller.decode({ok = true, value = value, replayed = false})
    if not result then error("valid fixture reply was rejected") end
    return result
end

local function plan(version: string, status: string, selected: boolean, revision: integer): {[string]: unknown}
    local value: {[string]: unknown} = {
        owner_node = "node-destination", workspace_id = "workspace-destination",
        source_node = "node-source", source_workspace = "workspace-source",
        version = version, plan_digest = string.rep("a", 64),
        candidate_digest = string.rep("b", 64), artifact_digest = string.rep("c", 64),
        preflight_digest = string.rep("d", 64), revision = revision, status = status,
        selected = selected,
    }
    if status == "reviewed" then
        value.review_status = "accepted"
        value.reviewer_id = "reviewer"
    end
    if selected then value.selection_revision = 1 end
    return value
end

local function available(version: string): {[string]: unknown}
    return {schema = "bee.sync-version@1", owner_id = "node-source", feed = "governance.application_versions",
        key = "version-key-" .. version, object_id = "sample/app", version_id = version,
        content_digest = string.rep("a", 64), manifest_digest = string.rep("b", 64),
        content_kind = "bee.governance-application-version@2", total_bytes = 2048,
        manifest = {schema_revision = "bee.governance-application-version@2", source_workspace = "workspace-source",
            component = "sample/app", artifact_digest = string.rep("c", 64)}, digest = string.rep("d", 64)}
end

local function report(ready: boolean): (string, string)
    local diagnostics: {unknown} = {}
    if not ready then
        diagnostics[1] = {code = "DANGLING_REFERENCE", target = "demo:run",
            message = "missing final-state target demo:absent", remedy = "repair the reference or include its target"}
    end
    local bytes, digest = preflight.encode_report({schema_revision = "bee.governance-preflight@1",
        plan_digest = string.rep("a", 64), destination_node = "node-destination", base_revision = 7,
        policy_digest = string.rep("a", 64), ready = ready, diagnostics = diagnostics, pending_migrations = {}})
    if not bytes or not digest then error("valid preflight report fixture was rejected") end
    return bytes, digest
end

local function detail(version: string, bytes: string, digest: string): {[string]: unknown}
    local value = plan(version, "staged", false, 1)
    value.preflight_bytes, value.preflight_digest = bytes, digest
    return value
end

local function changes_value(version: string): {[string]: unknown}
    return {owner_node = "node-destination", workspace_id = "workspace-destination",
        source_node = "node-source", source_workspace = "workspace-source", version = version,
        plan_digest = string.rep("a", 64), candidate_digest = string.rep("b", 64),
        artifact_digest = string.rep("c", 64), base_revision = 7, base_digest = string.rep("a", 64),
        composed_base_revision = 8, composed_base_digest = string.rep("b", 64),
        added = {{id = "demo:run", kind = "function.lua", digest = string.rep("a", 64)}},
        changed = {},
        removed = {{id = "demo:gone", kind = "function.lua", digest = string.rep("b", 64)}}}
end

local function activation(): {[string]: unknown}
    return {owner_node = "node-destination", workspace_id = "workspace-destination", intent_id = "intent",
        actor_id = "actor", overlay_owner = "overlay", source_node = "node-source",
        source_workspace = "workspace-source", version = "1.0.0", plan_digest = string.rep("a", 64),
        plan_revision = 1, selection_revision = 1, artifact_bytes = "artifact",
        artifact_digest = string.rep("b", 64), resolution_bytes = "resolution",
        resolution_digest = string.rep("c", 64), preflight_bytes = "preflight",
        preflight_digest = string.rep("d", 64), migration_work_bytes = "work",
        migration_work_digest = string.rep("e", 64), authorization_digest = string.rep("f", 64),
        effect_key = "effect", revision = 2, phase = "approval_bound", migrations_completed = false}
end

local function define_tests()
    test.describe("App Delivery model", function()
        test.it("keeps replicated versions staged until explicit destination actions", function()
            local state = model.new("workspace-destination")
            test.is_true(model.apply_list(state, reply({
                owner_node = "node-destination", workspace_id = "workspace-destination",
                plans = {plan("1.0.0", "reviewed", true, 4), plan("2.0.0", "staged", false, 1)},
            })))
            local selected = model.selected(state)
            test.not_nil(selected)
            if selected then
                test.eq(selected.version, "1.0.0")
                test.is_true(model.can_prepare(state, selected))
            end
            model.move(state, 1)
            local available = model.selected(state)
            test.not_nil(available)
            if available then
                test.eq(available.version, "2.0.0")
                test.is_true(model.accepts_review(available))
                test.is_false(model.can_select(available))
                local request = model.review_request(state, available, true, "review-key")
                test.eq(request.operation, "review")
                test.eq(request.expected_revision, 1)
            end
        end)

        test.it("routes every operation through the one destination facade contract", function()
            local state = model.new("workspace-destination")
            local item = plan("2.0.0", "reviewed", true, 7)
            item.review_status = "accepted"
            item.selection_revision = 2
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {item}})))
            local selected = model.selected(state)
            test.not_nil(selected)
            if selected then
                test.eq(model.CALL, "bee.governance:destination_call")
                test.eq(model.get_request(state, selected).operation, "get")
                test.eq(model.select_request(state, selected, "select-key").operation, "select")
                test.eq(model.prepare_request(state, selected, "intent", "prepare-key").operation, "prepare")
            end
            test.eq(model.step_request(state, "intent", "step-key").operation, "step")
            test.eq(model.status_request(state, "intent").operation, "status")
            test.eq(model.recover_request(state, "recover-key").operation, "recover")
        end)

        test.it("decodes available descriptors and stages only a local review plan", function()
            local state = model.new("workspace-destination")
            test.is_true(model.apply_available(state, reply({workspace_id = "workspace-destination",
                versions = {available("2.0.0")}})))
            local item = model.selected_available(state)
            test.not_nil(item)
            if item then
                local request = model.stage_request(state, item, "stage-key")
                test.eq(request.operation, "stage")
                test.eq(request.source_owner, "node-source")
                test.eq(request.feed, "governance.application_versions")
                test.eq(request.version_key, "version-key-2.0.0")
                test.eq(request.descriptor_digest, string.rep("d", 64))
                test.eq(request.idempotency_key, "stage-key")
                test.is_true(model.apply_stage(state, reply(plan("2.0.0", "staged", false, 1)), item))
                test.eq(#state.plans, 1)
                test.eq(model.available_status(state, item), "staged")
                test.eq(state.pane, "plans")
                test.is_true(state.notice:find("no installation", 1, true) ~= nil)
            end
        end)

        test.it("rejects malformed available descriptors without replacing decoded entries", function()
            local state = model.new("workspace-destination")
            test.is_true(model.apply_available(state, reply({workspace_id = "workspace-destination",
                versions = {available("1.0.0")}})))
            local malformed = available("2.0.0")
            malformed.content_kind = "other"
            test.is_false(model.apply_available(state, reply({workspace_id = "workspace-destination",
                versions = {malformed}})))
            test.eq(#state.available, 1)
            test.eq(model.selected_available(state).version, "1.0.0")
        end)

        test.it("restores retry identities without trusting saved activation details", function()
            local state = model.new("workspace-destination")
            model.set_pending_recover(state, "recover-key")
            model.select_available(state, "source\0feed\0key\0digest")
            model.set_pending_stage(state, "source\0feed\0key\0digest", "stage-key")
            local encoded = model.checkpoint(state)
            local restored = model.new("workspace-destination")
            test.is_true(model.restore(restored, encoded))
            test.eq(restored.pending_recover_key, "recover-key")
            test.eq(restored.pane, "available")
            test.eq(restored.pending_stage.idempotency_key, "stage-key")
            test.is_nil(restored.intent)
            test.is_false(model.restore(restored, '{"pending_recover_key":7}'))
        end)

        test.it("reads the verdict from the report bytes the plan stores", function()
            local state = model.new("workspace-destination")
            local ready_bytes, ready_digest = report(true)
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {plan("1.0.0", "staged", false, 1)}})))
            test.eq(model.verdict(state, model.selected(state)), "unread")
            test.is_true(model.refusal(state, model.selected(state)):find("preflight report first", 1, true) ~= nil)
            test.is_true(model.apply_plan(state, reply(detail("1.0.0", ready_bytes, ready_digest))))
            test.eq(model.verdict(state, model.selected(state)), "ready")
            test.is_nil(model.refusal(state, model.selected(state)))
        end)

        test.it("refuses to act on a plan whose report refuses it or fails its digest check", function()
            local state = model.new("workspace-destination")
            local blocked_bytes, blocked_digest = report(false)
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {plan("1.0.0", "staged", false, 1)}})))
            test.is_true(model.apply_plan(state, reply(detail("1.0.0", blocked_bytes, blocked_digest))))
            test.eq(model.verdict(state, model.selected(state)), "blocked")
            test.is_true(model.refusal(state, model.selected(state)):find("Preflight blocks", 1, true) ~= nil)
            local rows = model.review_rows(state)
            local rendered = ""
            for _, row in ipairs(rows) do rendered = rendered .. row.text .. "\n" end
            test.is_true(rendered:find("DANGLING_REFERENCE  demo:run", 1, true) ~= nil)
            test.is_true(rendered:find("missing final-state target demo:absent", 1, true) ~= nil)
            -- The same bytes under another plan's digest are not that plan's report.
            test.is_true(model.apply_plan(state, reply(detail("1.0.0", blocked_bytes, string.rep("e", 64)))))
            test.eq(model.verdict(state, model.selected(state)), "unreadable")
            test.is_true(model.refusal(state, model.selected(state)):find("does not match its digest", 1, true) ~= nil)
        end)

        test.it("decodes the entry set of one plan against the composed base", function()
            local state = model.new("workspace-destination")
            local ready_bytes, ready_digest = report(true)
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {plan("1.0.0", "staged", false, 1)}})))
            test.is_true(model.apply_plan(state, reply(detail("1.0.0", ready_bytes, ready_digest))))
            local item = model.selected(state)
            test.not_nil(item)
            if not item then return end
            test.eq(model.changes_request(state, item).operation, "changes")
            test.is_true(model.apply_changes(state, reply(changes_value("1.0.0")), item))
            test.eq(#state.changes.added, 1)
            test.eq(state.changes.added[1].id, "demo:run")
            test.eq(state.changes.removed[1].id, "demo:gone")
            local foreign = changes_value("1.0.0")
            foreign.plan_digest = string.rep("f", 64)
            test.is_false(model.apply_changes(state, reply(foreign), item))
            test.is_nil(state.changes)
            test.is_true(state.changes_error ~= nil)
        end)

        test.it("rejects foreign workspaces and malformed evidence", function()
            local state = model.new("workspace-destination")
            test.is_false(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-other", plans = {}})))
            test.is_false(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {plan("1.0.0", "staged", false, 0)}})))
        end)

        test.it("accepts the complete destination activation evidence", function()
            local state = model.new("workspace-destination")
            test.is_true(model.apply_activation(state, reply(activation())))
            test.eq(state.intent.intent_id, "intent")
            local malformed = activation()
            malformed.migration_work_digest = "bad"
            test.is_false(model.apply_activation(state, reply(malformed)))
        end)
    end)
end

return test.run_cases(define_tests)
