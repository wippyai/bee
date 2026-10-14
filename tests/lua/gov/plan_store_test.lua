-- MIT. Durable destination plan lifecycle; no approval or overlay is invoked.
local test = require("test")
local bounds = require("bounds")
local hash = require("hash")
local store = require("plan_store")

local function blob(bytes: string): {[string]: string}
    local digest, err = hash.sha256(bytes)
    if not digest then error(tostring(err)) end
    return {bytes = bytes, digest = digest}
end

local function ok(result: {[string]: unknown}): {[string]: unknown}
    test.is_true(result.ok == true)
    return assert(bounds.object(result.value))
end

local function identity(operation: string, revision: integer, key: string, workspace: string): {[string]: unknown}
    return {operation = operation, source_node = "source-a", source_workspace = workspace,
        version = "v1", expected_revision = revision, idempotency_key = key}
end

local function define_tests()
    test.describe("Governance destination plan store", function()
        test.it("retains review and selection across reopen, and refuses an approval binding", function()
            local state, open_error = store.open("bee:db", "node-a", "workspace-a")
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
            local selected = ok(store.call(state, "reviewer-a", identity("select", 2, "select-1", "author-a")))
            test.is_true(selected.selected == true)
            test.eq(selected.selection_revision, 3)
            -- Activation approvals bind measured intents; a plan has none.
            local bind = identity("bind_approval", 3, "bind-1", "author-a")
            bind.approval_id, bind.approval_plan_digest = "approval-1", selected.plan_digest
            bind.approval_proposal_digest = string.rep("b", 64)
            bind.approval_owner_incarnation = 7
            test.is_false(store.call(state, "reviewer-a", bind).ok == true)
            assert(store.close(state))

            local reopened, reopen_error = store.open("bee:db", "node-a", "workspace-a")
            if not reopened then error(tostring(reopen_error)) end
            local restored = ok(store.call(reopened, "reader-a", {operation = "get", source_node = "source-a",
                source_workspace = "author-a", version = "v1"}))
            test.eq(restored.plan_digest, selected.plan_digest)
            test.eq(restored.status, "reviewed")
            test.is_true(restored.selected == true)
            test.eq(restored.selection_revision, 3)
            assert(store.close(reopened))
        end)
        test.it("keeps the name of the agent that made a staged version", function()
            local state, open_error = store.open("bee:db", "node-a", "workspace-made")
            if not state then error(tostring(open_error)) end
            local stage = identity("stage", 0, "stage-made", "author-made")
            stage.candidate, stage.artifact, stage.preflight = blob("candidate"), blob("artifact"), blob("preflight")
            stage.author = "Claude Code"
            test.eq(ok(store.call(state, "reviewer-a", stage)).author, "Claude Code")
            local unnamed = identity("stage", 0, "stage-unnamed", "author-unnamed")
            unnamed.candidate, unnamed.artifact, unnamed.preflight = blob("candidate"), blob("artifact"), blob("preflight")
            test.is_nil(ok(store.call(state, "reviewer-a", unnamed)).author)
            assert(store.close(state))

            local reopened = assert(store.open("bee:db", "node-a", "workspace-made"))
            test.eq(ok(store.call(reopened, "reader-a", {operation = "get", source_node = "source-a",
                source_workspace = "author-made", version = "v1"})).author, "Claude Code")
            -- One version has one maker: the same bytes staged under another name conflict.
            local renamed = identity("stage", 0, "stage-renamed", "author-made")
            renamed.candidate, renamed.artifact, renamed.preflight = blob("candidate"), blob("artifact"), blob("preflight")
            renamed.author = "Codex"
            test.eq(store.call(reopened, "reviewer-a", renamed).code, "CONFLICT")
            assert(store.close(reopened))
        end)

        test.it("selects two applications independently in one workspace", function()
            local state, open_error = store.open("bee:db", "node-a", "workspace-multi")
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
