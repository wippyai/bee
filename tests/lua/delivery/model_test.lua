-- MIT. App Delivery presents destination-owned state and emits only facade requests.
local test = require("test")
local model = require("model")
local caller = require("caller")

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

        test.it("rejects foreign workspaces and malformed evidence", function()
            local state = model.new("workspace-destination")
            test.is_false(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-other", plans = {}})))
            test.is_false(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {plan("1.0.0", "staged", false, 0)}})))
        end)
    end)
end

return test.run_cases(define_tests)
