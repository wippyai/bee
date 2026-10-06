-- MIT. A selected plan is bound to the existing Approvals protocol exactly.
local test = require("test")
local bounds = require("bounds")
local approval = require("approval")
local drivers = require("drivers")
local canonical = require("canonical")
local hash = require("hash")

local DIGEST = string.rep("a", 64)
local function executor(change: boolean?, inspect_prompt: boolean?): approval.Executor
    local selected = {}
    function selected.call(self: approval.Executor, method: string, request: unknown): (unknown?, unknown?)
        local value = assert(bounds.object(request))
        if method == "bee.approvals.binding:request" then
            local prompt = assert(bounds.object(value.prompt))
            local wording = assert(bounds.text(prompt.text))
            test.is_true(wording:find("Install ", 1, true) == 1)
            if inspect_prompt then
                test.is_true(wording:find("Install application-a v1?", 1, true) ~= nil)
                test.is_true(wording:find("permissions", 1, true) ~= nil or wording:find("It adds:", 1, true) ~= nil)
                test.is_true(wording:find("this workspace", 1, true) ~= nil)
                test.is_true(wording:find("until replaced or removed", 1, true) ~= nil)
            end
            local proposal = assert(bounds.object(value.proposal))
            if change then proposal = {kind = "operation", ref = "other", revision = "other", payload = {}} end
            local bytes = assert(canonical.encode(proposal))
            local digest = assert(hash.sha256(bytes))
            return {ok = true, replayed = false, value = {approval_id = "approval-1",
                proposal = proposal, proposal_digest = digest, owner_incarnation = 7}}, nil
        end
        if method == "bee.approvals.binding:revalidate" then
            return {ok = true, replayed = false, value = {approval_id = value.approval_id,
                proposal_digest = value.proposal_digest, validated_incarnation = value.owner_incarnation}}, nil
        end
        return {ok = true, replayed = false, value = {approval_id = value.approval_id,
            proposal_digest = value.proposal_digest, consumer_id = "governance-host",
            consumed_effect = value.effect_key}}, nil
    end
    return selected
end

local function define_tests()
    test.describe("Governance approval bridge", function()
        test.it("binds activation and validates the exact consumption receipt", function()
            local intent = {workspace_id = "workspace-a", overlay_owner = "bee.gov:overlay",
                source_node = "source-a", source_workspace = "application-a", version = "v1",
                authorization_digest = DIGEST, artifact_digest = string.rep("b", 64),
                resolution_digest = string.rep("c", 64), preflight_digest = string.rep("d", 64),
                application_admission_digest = string.rep("f", 64),
                effect_key = string.rep("e", 64)}
            local bound, bind_error = approval.request_activation(executor(nil, true), intent, "user-approval", "activation-1")
            if not bound then error(tostring(bind_error)) end
            intent.approval_id, intent.approval_proposal_digest = bound.approval_id, bound.approval_proposal_digest
            intent.approval_owner_incarnation = bound.owner_incarnation
            local consumed, consume_error = approval.consume_activation(executor(), intent, "governance-host")
            if not consumed then error(tostring(consume_error and consume_error.message)) end
            test.eq(consumed.consumed_effect, intent.effect_key)
            local proposal = assert(approval.activation_proposal(intent))
            test.eq(((assert(bounds.object(proposal.payload))).application_admission_digest), string.rep("f", 64))
            local wrong, wrong_error = approval.consume_activation(executor(), intent, "other-host")
            test.is_nil(wrong)
            test.eq(wrong_error and wrong_error.code, "CONFLICT")
            local stale = {}
            function stale.call(self: approval.Executor, _method: string, _request: unknown): (unknown?, unknown?)
                return {ok = false, error = {code = "REVALIDATE", message = "authority changed"},
                    value = {current_incarnation = 9}}, nil
            end
            local stale_result, stale_error = approval.consume_activation(stale, intent, "governance-host")
            test.is_nil(stale_result)
            test.eq(stale_error and stale_error.code, "REVALIDATE")
            test.eq(stale_error and stale_error.value and stale_error.value.current_incarnation, 9)
            local validated, validation_error = approval.revalidate_activation(executor(), intent, 9)
            if not validated then error(tostring(validation_error and validation_error.message)) end
            test.eq(validated.validated_incarnation, 9)
        end)
        test.it("shows the person each migration the activation runs before they approve", function()
            local intent = {workspace_id = "workspace-a", overlay_owner = "bee.gov:overlay",
                source_node = "source-a", source_workspace = "application-a", version = "v1",
                authorization_digest = DIGEST, artifact_digest = string.rep("b", 64),
                resolution_digest = string.rep("c", 64), preflight_digest = string.rep("d", 64),
                effect_key = string.rep("e", 64)}
            local migrations = {{id = "app.notes:create_notes", target_db = "notes"}}
            local proposal = assert(approval.activation_proposal(intent, nil, migrations))
            local payload = assert(bounds.object(proposal.payload))
            local rows = assert(bounds.array(payload.migrations, 8))
            test.eq((assert(bounds.object(rows[1]))).id, "app.notes:create_notes")
            test.eq((assert(bounds.object(rows[1]))).target_db, "notes")
            local plain = assert(approval.activation_proposal(intent))
            test.is_nil((assert(bounds.object(plain.payload))).migrations)
            local seen: string? = nil
            local recorder = {}
            function recorder.call(self: approval.Executor, _method: string, request: unknown): (unknown?, unknown?)
                local value = assert(bounds.object(request))
                seen = bounds.text((assert(bounds.object(value.prompt))).text, 4096)
                local recorded = assert(bounds.object(value.proposal))
                local digest = assert(hash.sha256(assert(canonical.encode(recorded))))
                return {ok = true, value = {approval_id = "approval-2", proposal = recorded, proposal_digest = digest,
                    owner_incarnation = 1}}, nil
            end
            assert(approval.request_activation(recorder, intent, "user-approval", "activation-2", nil, migrations,
                {title = "Notes", maker = "from bee node-b"}))
            test.eq(tostring(seen):sub(1, 40), "Install Notes v1 (from bee node-b)? It a")
            test.is_true(tostring(seen):find("It runs 1 database migration: app.notes:create_notes on notes.", 1, true) ~= nil)
            test.is_true(tostring(seen):find("change the database for good", 1, true) ~= nil)
        end)

        test.it("carries what the card names and shows tools as agents see them", function()
            local intent = {workspace_id = "workspace-a", overlay_owner = "bee.gov.apps:workspace-a.notes",
                source_node = "node-a", source_workspace = "notes", version = "1.0.0",
                authorization_digest = string.rep("a", 64), artifact_digest = string.rep("b", 64),
                resolution_digest = string.rep("c", 64), preflight_digest = string.rep("d", 64), effect_key = "effect-notes"}
            local review = {requires_approval = true,
                resolved = {"Use an isolated application database named notes",
                    "Let agents you enable call app.notes:add_note, app.notes:list_notes as this application, with this application's grants"},
                delta = {"added: Use an isolated application database named notes"}}
            local proposal = assert(approval.activation_proposal(intent, review, nil,
                {title = "Notes", maker = "made by Claude Code · this bee",
                    tools = {["app.notes:add_note"] = "notes_add", ["app.notes:list_notes"] = "notes_list"}}))
            local payload = assert(bounds.object(proposal.payload))
            test.eq(payload.title, "Notes")
            test.eq(payload.maker, "made by Claude Code · this bee")
            test.is_nil(payload.subject)
            local resolved = assert(bounds.array(payload.resolved_capabilities))
            test.eq(resolved[2], "Let agents you enable call notes_add, notes_list as this application, with this application's grants")
            test.eq(resolved[1], "Use an isolated application database named notes")
            local plain = assert(approval.activation_proposal(intent, review))
            test.is_nil(assert(bounds.object(plain.payload)).title)
            local driver = {}
            for key, value in pairs(intent) do driver[key] = value end
            driver.overlay_owner = drivers.OWNER_PREFIX .. "workspace-a.stub"
            test.eq(assert(bounds.object(assert(approval.activation_proposal(driver)).payload)).subject, "driver")
        end)
    end)
end

return test.run_cases(define_tests)
