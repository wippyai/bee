local test = require("test")
local admission = require("configuration_admission")
local principals = require("approval_principals")
local store = require("store")
local bounds = require("bounds")
local hash = require("hash")
type Object = {[string]: unknown}
local BASE = ".config/opencode/.bee-global-opencode.json"
local function fixture(decision: string)
    local requests, reads, admissions, waits = 0, 0, 0, 0
    local admitted = ""
    local current = "first"
    local keys: {string} = {}
    local receipt: Object? = nil
    local io: admission.IO
    local completed = false
    local reviewed: Object = {effect = {effect_id = "effect", owner_incarnation = 1, revision = 1}}
    io = {
        measure = function(): (admission.Base?, string?) return {path = "/synthetic/opencode.json", content = current, digest = assert(hash.sha256(current))}, nil end,
        admitted = function(base: admission.Base): (boolean?, string?) return admitted == base.digest, nil end,
        check = function(_base: admission.Base): string? return nil end,
        finish = function(base: admission.Base?, _approval: string, result: Object): string?
            if base then admitted = base.digest; admissions = admissions + 1 end
            receipt = result
            return nil
        end,
        receipt = function(_approval: string): (Object?, string?) return receipt, nil end,
        call = function(target: string, request: Object): (unknown, string?)
            if target == "bee.approvals.binding:request" then
                requests = requests + 1
                receipt = nil; completed = false
                reviewed = {approval_id = "approval", state = "decided", decision = decision, proposal = request.proposal,
                    effect = {effect_id = "effect", owner_incarnation = 1, revision = 1}, proposal_digest = "digest", reviewed_digest = "review", owner_incarnation = 1}
                keys[#keys + 1] = tostring(request.idempotency_key)
                test.eq(request.policy, "configuration-setup")
                test.eq(request.contract_version, 2)
                test.eq(assert(bounds.object(request.continuation)).destination, "credentials.configuration")
                local prompt = assert(type(request.prompt) == "table" and request.prompt or nil)
                test.is_true(tostring(prompt.text):find("Copy /synthetic/opencode.json into the opencode agent's session as .config/opencode/.bee-global-opencode.json?", 1, true) ~= nil, tostring(prompt.text))
                test.is_true(tostring(prompt.text):find("your file stays unchanged", 1, true) ~= nil, tostring(prompt.text))
                return {ok = true, value = {approval_id = "approval", state = "pending"}}, nil
            end
            if target == "bee.approvals.binding:effect" then
                if request.operation == "complete" then completed = true end
                return {ok = true, value = reviewed}, nil
            end
            reads = reads + 1
            return {ok = true, value = {approval_id = "approval", state = reads % 2 == 1 and "pending" or "decided", decision = reads % 2 == 0 and decision or nil, effect_completed_at = completed and "now" or nil, effect_result = receipt}}, nil
        end,
        changes = function(): (admission.Changes?, string?)
            return {next = function(approval_id: string): string?
                test.eq(approval_id, "approval")
                waits = waits + 1
                if waits % 2 == 0 then test.is_nil(admission.consume(io, reviewed)) end
                return nil
            end, close = function() end}, nil
        end,
    }
    return io, function(): (integer, integer, integer, integer) return requests, reads, admissions, waits end,
        function(value: string) current = value end, keys
end
function run()
    test.describe("configuration base admission", function()
        test.it("marks the stock OpenCode profile as needing setup before launch", function()
            local workspace = "0123456789abcdef0123456789abcdef"
            local requester = principals.caller("configuration-catalog-" .. principals.key(), {"bee.tests.credentials:configuration_catalog_client"}, {workspace_id = workspace})
            local raw, err = requester:call("bee.threads.sessions.binding:catalog", {kind = "definition", include_unavailable = true,
                definition_ref = "bee.driver.opencode.profiles:default_window"})
            test.is_nil(err)
            local reply = assert(bounds.object(raw))
            test.eq(reply.ok, true)
            local page = assert(bounds.object(reply.value))
            local rows = assert(bounds.array(page.items, 64))
            test.eq(#rows, 1)
            local item = assert(bounds.object(rows[1]))
            if item.status ~= "ready" then error("stock configuration status: " .. tostring(item.status) .. " " .. tostring(assert(bounds.array(item.reasons, 64))[1])) end
            test.eq(item.status, "ready")
            local features = assert(bounds.array(item.features, 64))
            local setup = false
            for _, feature in ipairs(features) do if feature == "configuration:needs_setup" then setup = true end end
            test.is_true(setup)
        end)
        test.it("uses the public approval decision to persist admission and resume", function()
            local workspace = "configuration-" .. principals.key()
            local requester = principals.caller("configuration-requester-" .. principals.key(), {"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy", "bee.tests.credentials:configuration_effect_client"})
            local approver = principals.caller("configuration-approver-" .. principals.key(), {"bee.security.approvals:approval_decide_policy"}, {definition_id = "bee.approvals.inbox.app:app"})
            local db = assert(store.open())
            local content = "synthetic configuration"
            local digest = assert(hash.sha256(content))
            local requested: Object? = nil
            local calls = 0
            local io: admission.IO
            io = {
                measure = function(): (admission.Base?, string?) return {path = "/synthetic/config.json", content = content, digest = digest}, nil end,
                admitted = function(base: admission.Base): (boolean?, string?) return store.configuration_admitted(db, workspace, "fixture-source", "config.json", base.digest) end,
                check = function(_base: admission.Base): string? return nil end,
                finish = function(base: admission.Base?, approval: string, result: Object): string? return store.finish_configuration(db, workspace, "fixture-source", "config.json", base and base.digest, approval, result) end,
                receipt = function(approval: string): (Object?, string?) return store.configuration_receipt(db, approval) end,
                call = function(target: string, input: Object): (unknown, string?)
                    local raw, err = requester:call(target, input)
                    if target == "bee.approvals.binding:request" then
                        calls = calls + 1
                        local reply = assert(bounds.object(raw))
                        requested = assert(bounds.object(reply.value))
                    end
                    return raw, err and tostring(err) or nil
                end,
                changes = function(): (admission.Changes?, string?)
                    return {next = function(_approval_id: string): string?
                        local view = assert(requested)
                        local raw, err = approver:call("bee.approvals.binding:decide", {approval_id = view.approval_id,
                            expected_revision = view.revision, proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, decision = "approved"})
                        test.is_nil(err)
                        local reply = assert(bounds.object(raw))
                        test.eq(reply.ok, true)
                        test.is_nil(admission.consume(io, assert(bounds.object(reply.value))))
                        return nil
                    end, close = function() end}, nil
                end,
            }
            local base, err = admission.ensure(io, workspace, "synthetic", nil, "config.json")
            test.is_nil(err); test.eq(assert(base).digest, digest); test.eq(calls, 1)
            test.is_false(assert(admission.status(io)).needs_setup)
            test.not_nil(admission.ensure(io, workspace, "synthetic", nil, "config.json")); test.eq(calls, 1)
            db:release()
        end)
        test.it("files one request, waits for approval, admits and continues", function()
            local io, counts = fixture("approved")
            local base, err = admission.ensure(io, "workspace", "opencode", nil, BASE)
            test.is_nil(err); test.eq(assert(base).content, "first")
            local requests, reads, admitted = counts()
            test.eq(requests, 1); test.eq(reads, 2); test.eq(admitted, 1)
            test.is_true(admission.ensure(io, "workspace", "opencode", nil, BASE) ~= nil)
            test.eq(counts(), 1)
        end)
        test.it("ends setup with the reason when Needs you stops announcing changes", function()
            local io = fixture("approved")
            local closed = false
            io.changes = function(): (admission.Changes?, string?)
                return {next = function(_approval_id: string): string? return "announcements ended" end,
                    close = function() closed = true end}, nil
            end
            local base, err = admission.ensure(io, "workspace", "opencode", nil, BASE)
            test.is_nil(base); test.eq(err, "announcements ended"); test.is_true(closed)
        end)
        test.it("denial ends launch with a clear reason and never admits", function()
            local io, counts = fixture("denied")
            local base, err = admission.ensure(io, "workspace", "opencode", nil, BASE)
            test.is_nil(base); test.is_true(assert(err):find("denied", 1, true) ~= nil)
            local requests, _, admitted = counts()
            test.eq(requests, 1); test.eq(admitted, 0)
        end)
        test.it("replays the durable admission receipt after completion delivery fails", function()
            local io, counts = fixture("approved")
            local measured = assert(io.measure())
            local view: Object = {approval_id = "replay", state = "decided", decision = "approved", owner_incarnation = 1,
                proposal_digest = "proposal", reviewed_digest = "review", effect = {effect_id = "effect"},
                proposal = {payload = {path = measured.path, digest = measured.digest}}}
            local original = io.call
            local fail_completion = true
            io.call = function(target: string, input: Object): (unknown, string?)
                if input.operation == "complete" and fail_completion then fail_completion = false; return nil, "delivery failed" end
                return original(target, input)
            end
            test.eq(admission.consume(io, view), "delivery failed")
            test.is_false(assert(admission.status(io)).needs_setup)
            test.is_nil(admission.consume(io, view))
            local _, _, admissions = counts()
            test.eq(admissions, 1)
        end)
        test.it("refuses to admit a file changed while the person reviews it", function()
            local io, counts, change = fixture("approved")
            local measured = assert(io.measure())
            local view: Object = {approval_id = "changed", state = "decided", decision = "approved", owner_incarnation = 1,
                proposal_digest = "proposal", reviewed_digest = "review", effect = {effect_id = "effect"},
                proposal = {payload = {path = measured.path, digest = measured.digest}}}
            change("changed during review")
            test.is_nil(admission.consume(io, view))
            local receipt = assert(io.receipt("changed"))
            test.eq(receipt.ok, false)
            test.is_true(tostring(receipt.message):find("changed while awaiting approval", 1, true) ~= nil)
            local _, _, admissions = counts()
            test.eq(admissions, 0)
        end)
        test.it("a new launch can request the same file after denial", function()
            local io, _, _, keys = fixture("denied")
            test.is_nil(admission.ensure(io, "workspace", "opencode", "first-launch", BASE))
            test.is_nil(admission.ensure(io, "workspace", "opencode", "next-launch", BASE))
            test.is_true(keys[1] ~= keys[2])
        end)
        test.it("reports a file the launch refuses before asking the person", function()
            local io, counts = fixture("approved")
            local checked = 0
            io.check = function(base: admission.Base): string?
                checked = checked + 1
                test.eq(base.content, "first")
                return BASE .. ": authority-bearing key provider has no admitted mapping"
            end
            local status, status_error = admission.status(io)
            test.is_nil(status)
            test.eq(status_error, "Bee cannot use /synthetic/opencode.json: " .. BASE .. ": authority-bearing key provider has no admitted mapping")
            local base, err = admission.ensure(io, "workspace", "opencode", "launch", BASE)
            test.is_nil(base)
            test.eq(err, status_error)
            test.eq(counts(), 0)
            test.eq(checked, 2)
        end)
        test.it("asks once per workspace and file digest across launches", function()
            local io, counts = fixture("approved")
            for _, attempt in ipairs({"first-launch", "second-launch", "third-launch"}) do
                test.eq(assert(admission.ensure(io, "workspace", "opencode", attempt, BASE)).content, "first")
            end
            test.eq(counts(), 1)
        end)
        test.it("a changed digest needs setup and asks again", function()
            local io, counts, change = fixture("approved")
            test.is_true(assert(admission.status(io)).needs_setup)
            assert(admission.ensure(io, "workspace", "opencode", nil, BASE))
            test.is_false(assert(admission.status(io)).needs_setup)
            change("changed")
            test.is_true(assert(admission.status(io)).needs_setup)
            test.eq(assert(admission.ensure(io, "workspace", "opencode", nil, BASE)).content, "changed")
            test.eq(counts(), 2)
        end)
    end)
end

return test.run_cases(run)
