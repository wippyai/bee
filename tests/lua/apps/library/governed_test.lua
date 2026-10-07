-- MIT. The Library presents destination-owned versions and emits only facade requests.
local test = require("test")
local model = require("model")
local preflight = require("preflight")

local function reply(value: unknown): model.Reply
    local result = model.reply({ok = true, value = value, replayed = false})
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
    test.describe("Library governed model", function()
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
            model.select(state, model.key(state.plans[2]))
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

        test.it("lists, reads and stages a version an agent made with the agent's name the destination keeps", function()
            local state = model.new("workspace-destination")
            local made = plan("1.0.0", "reviewed", true, 3)
            made.author = "Claude Code"
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {made}})), state.fault)
            local selected = assert(model.selected(state))
            test.eq(selected.author, "Claude Code")
            test.is_true(model.can_prepare(state, selected))
            test.is_true(model.apply_plan(state, reply(made)), state.fault)
            made.author = string.rep("x", 200)
            test.is_false(model.apply_plan(state, reply(made)))
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
                test.eq(model.CALL, "bee.gov.binding:destination_call")
                test.eq(model.get_request(state, selected).operation, "get")
                test.eq(model.select_request(state, selected, "select-key").operation, "select")
                test.eq(model.prepare_request(state, selected, "intent", "prepare-key").operation, "prepare")
            end
            test.eq(model.step_request(state, "intent", "step-key").operation, "step")
            test.eq(model.status_request(state, "intent").operation, "status")
        end)

        test.it("recovers the desired activation of the chosen version's source overlay", function()
            local state = model.new("workspace-destination")
            local item = plan("2.0.0", "reviewed", true, 7)
            item.review_status = "accepted"
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {item}})))
            local selected = assert(model.selected(state))
            local request = model.recover_request(state, selected, "recover-key")
            test.eq(request.operation, "recover")
            test.eq(request.workspace_id, "workspace-destination")
            test.eq(request.source_node, "node-source")
            test.eq(request.source_workspace, "workspace-source")
            test.eq(request.receipt_key, "recover-key")
        end)

        test.it("decodes the destination's refusal and treats a malformed reply as unknown", function()
            local refused = assert(model.reply({ok = false, replayed = false,
                error = {code = "BLOCKED", message = "no activation profile"}}))
            test.is_false(refused.ok)
            test.eq(assert(refused.error).code, "BLOCKED")
            test.is_nil(model.reply({ok = true, replayed = false}))
            test.is_nil(model.reply({ok = false, error = {code = "BLOCKED"}}))
            test.is_nil(model.reply("not a reply"))
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
                test.not_nil(model.staged_plan(state, item))
                test.eq(state.notice, "")
                test.is_true(state.fault:find("no installation", 1, true) ~= nil)
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

        test.it("reads the verdict from the report bytes the plan stores", function()
            local state = model.new("workspace-destination")
            local ready_bytes, ready_digest = report(true)
            test.is_true(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-destination", plans = {plan("1.0.0", "staged", false, 1)}})))
            test.eq(model.verdict(state, model.selected(state)), "unread")
            local unread, unread_detail = model.refusal(state, model.selected(state))
            test.is_true(assert(unread):find("still being checked", 1, true) ~= nil)
            test.is_true(assert(unread_detail):find("preflight report first", 1, true) ~= nil)
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
            local blocked, blocked_detail = model.refusal(state, model.selected(state))
            test.is_true(assert(blocked):find("fails 1 check", 1, true) ~= nil)
            test.is_true(assert(blocked_detail):find("Preflight blocks", 1, true) ~= nil)
            local rows = model.review_rows(state)
            local rendered = ""
            for _, row in ipairs(rows) do rendered = rendered .. row.text .. "\n" end
            test.is_true(rendered:find("DANGLING_REFERENCE  demo:run", 1, true) ~= nil)
            test.is_true(rendered:find("missing final-state target demo:absent", 1, true) ~= nil)
            -- The same bytes under another plan's digest are not that plan's report.
            test.is_true(model.apply_plan(state, reply(detail("1.0.0", blocked_bytes, string.rep("e", 64)))))
            test.eq(model.verdict(state, model.selected(state)), "unreadable")
            local unreadable, unreadable_detail = model.refusal(state, model.selected(state))
            test.is_true(assert(unreadable):find("can't be trusted", 1, true) ~= nil)
            test.is_true(assert(unreadable_detail):find("does not match its digest", 1, true) ~= nil)
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

        test.it("tells a person a version can't be read and keeps the owner's words for details", function()
            local state = model.new("workspace-destination")
            test.is_false(model.apply_list(state, reply({owner_node = "node-destination",
                workspace_id = "workspace-other", plans = {}})))
            test.eq(state.notice, "This version can't be read; try Refresh")
            test.eq(state.fault, "Destination returned an invalid plan list")
            local refused = assert(model.reply({ok = false, replayed = false,
                error = {code = "BLOCKED", message = "no activation profile"}}))
            test.is_false(model.apply_available(state, refused))
            test.eq(state.notice, "That did not go through; Details (T) says why")
            test.eq(state.fault, "BLOCKED: no activation profile")
            test.is_false(model.apply_available(state, nil))
            test.eq(state.notice, "No answer yet; try Refresh")
        end)

        test.it("reads the author a version names and refuses a malformed one", function()
            local state = model.new("workspace-destination")
            local named = available("2.0.0")
            assert(named.manifest :: {[string]: unknown}).author = "Claude Code"
            test.is_true(model.apply_available(state, reply({workspace_id = "workspace-destination", versions = {named}})))
            test.eq(state.available[1].author, "Claude Code")
            test.is_nil(available("3.0.0").manifest.author)
            for _, bad in ipairs({7, string.rep("x", 81)}) do
                local malformed = available("4.0.0")
                assert(malformed.manifest :: {[string]: unknown}).author = bad
                test.is_false(model.apply_available(state, reply({workspace_id = "workspace-destination", versions = {malformed}})))
            end
            test.eq(#state.available, 1)
        end)

        test.it("reads which application an install runs and the version it replaced", function()
            local state = model.new("workspace-destination")
            local installed = {owner_node = "node-destination", workspace_id = "workspace-destination",
                intent_id = "intent-2", overlay_owner = "overlay", source_node = "node-source",
                source_workspace = "notes", version = "1.0.1", revision = 6, phase = "settled", outcome = "applied",
                observed_intent_id = "intent-2", observed_outcome = "applied", baseline_intent_id = "intent-1",
                application = "app.notes:main"}
            test.is_true(model.apply_activations(state, reply({workspace_id = "workspace-destination", activations = {installed}})))
            test.eq(state.activations[1].application, "app.notes:main")
            test.eq(state.activations[1].baseline_intent_id, "intent-1")
        end)

        test.it("asks for node names, keeps the answered ones and builds the person's revert", function()
            local state = model.new("workspace-destination")
            test.eq(model.NAMES, "bee.node.binding:names")
            test.eq(model.names_request({"node-a"}).nodes[1], "node-a")
            test.is_true(model.apply_names(state, reply({names = {["node-a"] = "laptop"}})))
            test.is_true(model.apply_names(state, reply({names = {["node-b"] = "desk", ["node\nbad"] = "x"}})))
            test.eq(state.names["node-a"], "laptop")
            test.eq(state.names["node-b"], "desk")
            test.is_nil(state.names["node\nbad"])
            test.is_false(model.apply_names(state, reply({names = {}, extra = true})))
            local request = model.revert_request(state, "notes", "revert-key")
            test.eq(request.operation, "revert")
            test.eq(request.workspace_id, "workspace-destination")
            test.eq(request.source_workspace, "notes")
            test.eq(request.receipt_key, "revert-key")
        end)

        test.it("reads the activations of the workspace with their slot pointers", function()
            local state = model.new("workspace-destination")
            test.eq(model.activations_request(state).operation, "activations")
            local installed = {owner_node = "node-destination", workspace_id = "workspace-destination",
                intent_id = "intent-1", overlay_owner = "overlay", source_node = "node-source",
                source_workspace = "notes", version = "1.0.0", revision = 6, phase = "settled", outcome = "applied",
                slot_revision = 4, desired_intent_id = "intent-1", observed_intent_id = "intent-1", observed_outcome = "applied"}
            test.is_true(model.apply_activations(state, reply({workspace_id = "workspace-destination",
                activations = {installed}})))
            test.eq(#state.activations, 1)
            test.eq(state.activations[1].observed_outcome, "applied")
            test.is_false(model.apply_activations(state, reply({workspace_id = "workspace-other", activations = {}})))
            test.eq(#state.activations, 1)
            local malformed = {owner_node = "node-destination", workspace_id = "workspace-destination",
                intent_id = "intent-2", overlay_owner = "overlay", source_node = "node-source",
                source_workspace = "notes", version = "1.0.1", revision = 1, phase = "unknown"}
            test.is_false(model.apply_activations(state, reply({workspace_id = "workspace-destination",
                activations = {malformed}})))
        end)

        test.it("names each activation phase in the words a person reads", function()
            local base = {owner_node = "node-destination", workspace_id = "workspace-destination",
                intent_id = "intent-1", overlay_owner = "overlay", source_node = "node-source",
                source_workspace = "notes", version = "1.0.0", revision = 1}
            local function phrase(phase: string, outcome: string?): string
                local state = model.new("workspace-destination")
                local value: {[string]: unknown} = {}
                for key, item in pairs(base) do value[key] = item end
                value.phase, value.outcome = phase, outcome
                test.is_true(model.apply_activation(state, reply(value)))
                test.is_true(state.fault:find("Activation " .. phase, 1, true) == 1)
                return state.notice
            end
            test.eq(phrase("prepared"), "Waiting for your approval in Needs you")
            test.eq(phrase("approval_bound"), "Waiting for your approval in Needs you")
            test.eq(phrase("authorized"), "Installing")
            test.eq(phrase("applying"), "Installing")
            test.eq(phrase("settled", "applied"), "Installed")
            test.is_true(phrase("settled", "failed"):find("could not be installed", 1, true) ~= nil)
        end)

        test.it("accepts the complete destination activation evidence", function()
            local state = model.new("workspace-destination")
            test.is_true(model.apply_activation(state, reply(activation())))
            test.eq(state.intent.intent_id, "intent")
            local malformed = activation()
            malformed.migration_work_digest = "bad"
            test.is_false(model.apply_activation(state, reply(malformed)))
        end)

        test.it("accepts an activation carrying its application admission as the store records it", function()
            local state = model.new("workspace-destination")
            local admitted = activation()
            admitted.application_admission_bytes = "admission"
            admitted.application_admission_digest = string.rep("1", 64)
            admitted.application_admission_generation = "current"
            test.is_true(model.apply_activation(state, reply(admitted)))
            local unknown_generation = activation()
            unknown_generation.application_admission_generation = "later"
            test.is_false(model.apply_activation(state, reply(unknown_generation)))
        end)
    end)
end

return test.run_cases(define_tests)
