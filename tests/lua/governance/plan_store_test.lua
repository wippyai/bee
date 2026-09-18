-- MIT. Durable destination plan lifecycle; no approval or overlay is invoked.
local test = require("test")
local hash = require("hash")
local store = require("plan_store")

local function blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end

local function ok(result: {[string]: unknown}): {[string]: unknown}
    test.is_true(result.ok == true)
    return result.value :: {[string]: unknown}
end

local function identity(operation: string, revision: integer, key: string, workspace: string): {[string]: unknown}
    return {operation = operation, source_node = "source-a", source_workspace = workspace,
        version = "v1", expected_revision = revision, idempotency_key = key}
end

local function define_tests()
    test.describe("Governance destination plan store", function()
        test.it("retains review, selection and exact approval binding across reopen", function()
            local state, open_error = store.open("bee.governance:plan_test_db", "node-a", "workspace-a")
            if not state then error(tostring(open_error)) end
            local stage = identity("stage", 0, "stage-1", "author-a")
            stage.candidate, stage.artifact, stage.preflight = blob("candidate"), blob("artifact"), blob("preflight")
            local staged = ok(store.call(state, "reviewer-a", stage))
            test.eq(staged.revision, 1)
            test.is_false(staged.selected == true)
            local replay = store.call(state, "reviewer-a", stage)
            test.is_true(replay.ok == true and replay.replayed == true)

            local review = identity("record_review", 1, "review-1", "author-a")
            review.review_status, review.review_reason = "accepted", "exact definitions checked"
            local reviewed = ok(store.call(state, "reviewer-a", review))
            test.eq(reviewed.revision, 2)
            local bind_early = identity("bind_approval", 2, "bind-early", "author-a")
            bind_early.approval_id, bind_early.approval_plan_digest = "approval-1", reviewed.plan_digest
            bind_early.approval_proposal_digest = string.rep("b", 64)
            bind_early.approval_owner_incarnation = 7
            test.is_false(store.call(state, "reviewer-a", bind_early).ok == true)

            local selected = ok(store.call(state, "reviewer-a", identity("select", 2, "select-1", "author-a")))
            test.is_true(selected.selected == true)
            test.eq(selected.selection_revision, 3)
            local wrong = identity("bind_approval", 3, "bind-wrong", "author-a")
            wrong.approval_id, wrong.approval_plan_digest = "approval-1", string.rep("a", 64)
            wrong.approval_proposal_digest = string.rep("b", 64)
            wrong.approval_owner_incarnation = 7
            test.is_false(store.call(state, "reviewer-a", wrong).ok == true)
            local bind = identity("bind_approval", 3, "bind-1", "author-a")
            bind.approval_id, bind.approval_plan_digest = "approval-1", selected.plan_digest
            bind.approval_proposal_digest = string.rep("b", 64)
            bind.approval_owner_incarnation = 7
            local bound = ok(store.call(state, "reviewer-a", bind))
            test.eq(bound.status, "approval_bound")
            assert(store.close(state))

            local reopened, reopen_error = store.open("bee.governance:plan_test_db", "node-a", "workspace-a")
            if not reopened then error(tostring(reopen_error)) end
            local restored = ok(store.call(reopened, "reader-a", {operation = "get", source_node = "source-a",
                source_workspace = "author-a", version = "v1"}))
            test.eq(restored.plan_digest, bound.plan_digest)
            test.eq(restored.approval_id, "approval-1")
            test.eq(restored.approval_plan_digest, bound.plan_digest)
            test.eq(restored.approval_proposal_digest, string.rep("b", 64))
            test.eq(restored.approval_owner_incarnation, 7)
            test.is_true(restored.selected == true)
            test.eq(restored.selection_revision, 3)
            assert(store.close(reopened))
        end)
        test.it("selects two applications independently in one workspace", function()
            local state, open_error = store.open("bee.governance:plan_test_db", "node-a", "workspace-multi")
            if not state then error(tostring(open_error)) end
            for index, application in ipairs({"application-a", "application-b"}) do
                local stage = identity("stage", 0, "multi-stage-" .. index, application)
                stage.candidate = blob("candidate-" .. application)
                stage.artifact = blob("artifact-" .. application)
                stage.preflight = blob("preflight-" .. application)
                ok(store.call(state, "reviewer-a", stage))
                local review = identity("record_review", 1, "multi-review-" .. index, application)
                review.review_status, review.review_reason = "accepted", "reviewed"
                ok(store.call(state, "reviewer-a", review))
                ok(store.call(state, "reviewer-a", identity("select", 2,
                    "multi-select-" .. index, application)))
            end
            local first = ok(store.call(state, "reader", {operation = "get", source_node = "source-a",
                source_workspace = "application-a", version = "v1"}))
            local second = ok(store.call(state, "reader", {operation = "get", source_node = "source-a",
                source_workspace = "application-b", version = "v1"}))
            test.is_true(first.selected == true)
            test.is_true(second.selected == true)
            assert(store.close(state))
        end)
    end)
end

return test.run_cases(define_tests)
