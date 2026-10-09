local test = require("test")
local bounds = require("bounds")
local channel = require("channel")
local time = require("time")
local json = require("json")
local hash = require("hash")
local store = require("store")
local request = require("request")
local types = require("types")
local runner_fixture = require("runner_fixture")
local principals = require("approval_principals")
local fs = require("fs")
local function cases()
    test.describe("Composed launch without a login projection", function()
        for _, decision in ipairs({"approved", "denied"}) do
        test.it("asks once in Needs you and handles " .. decision .. " without a login projection", function()
            local id = "composition-" .. principals.key()
            local volume = assert(fs.get("bee.placement.publication.test:configuration_source"))
            assert(volume:writefile("opencode.json", '{"provider":{"synthetic":{"options":{"apiKey":"{file:/synthetic/provider.key}"}}}}'))
            local content = '{"lane":true}'
            local path: {string} = {"lane"}
            local operation: types.JsonOperation = {kind = "insert", path = path}
            local operations: {types.JsonOperation} = {operation}
            local composition: types.Composition = {kind = "json_patch", base_path = ".config/opencode/.bee-global-opencode.json",
                operations = operations}
            local delivery: types.ConfigurationDelivery = {arguments = {}, files = {{revision = "fixture@1",
                path = ".config/opencode/opencode.json", content = content, digest = assert(hash.sha256(content)),
                provider_ref = "bee.test:provider", composition = composition}}}
            local value: types.LaunchRequest = {workspace_id = id, idempotency_key = id, attempt_id = id,
                owner_id = "bee.test.configuration", owner_incarnation = 1, action_id = id,
                binding_ref = "bee.driver.opencode.binding:binding", policy_ref = "bee.test:policy", profile_id = "window",
                binding_digest = string.rep("b", 64), profile_digest = string.rep("c", 64),
                launch = {executable = "sh", argv = {}, environment = {}, readiness = "none", home_ref = "session",
                    provider_home = {provider = "opencode", private = false, files = {}}},
                session_ref = id, resources = {{name = "session", grant_ref = "test-session", root_ref = "bee.placement.native.env:root",
                    subpath = "", access = "write", purpose = "session"}}, environment = {}, environment_refs = {}, projections = {},
                required_cleanup = "process_group", required_exit_observation = "independent",
                timeouts = {stop_grace_ms = 100, drain_ms = 1000, retain_ms = 1000},
                delivery = delivery}
            local db = assert(store.open())
            local intended = store.intend(db, value, assert(request.digest(value)), assert(json.encode(value)),
                {capability = "process_group", exit_observation = "independent"})
            test.is_true(intended.ok)
            local runner = runner_fixture.claim("bee.placement.publication.test:materialization_runner_process", value, 0)
            local results: Channel<runner_fixture.Outcome> = channel.new(1)
            coroutine.spawn(function() results:send(runner_fixture.prepare(runner)) end)
            local approver = principals.caller("configuration-person-" .. principals.key(), {"bee.security.approvals:approval_decide_policy"},
                {definition_id = "bee.approvals.inbox.app:app"})
            local ticker = assert(time.ticker("20ms"))
            local timeout = time.after("15s")
            local approvals = 0
            local settled = false
            local outcome: runner_fixture.Outcome? = nil
            while not outcome do
                local event = channel.select({results:case_receive(), ticker:channel():case_receive(), timeout:case_receive()})
                if event.channel == timeout then runner_fixture.release(runner); error("configuration admission did not continue") end
                if event.channel == results then outcome = event.value
                elseif not settled then
                    local raw, err = approver:call("bee.approvals.binding:inbox", {workspace_id = id})
                    test.is_nil(err)
                    local reply = assert(bounds.object(raw))
                    test.is_true(reply.ok == true)
                    local page = assert(bounds.object(reply.value))
                    for _, raw_change in ipairs(assert(bounds.array(page.changes, 64))) do
                        local change = assert(bounds.object(raw_change))
                        local view = assert(bounds.object(change.request))
                        if view.state == "pending" then
                            approvals = approvals + 1
                            local decision = approver:call("bee.approvals.binding:decide", {approval_id = view.approval_id,
                                expected_revision = view.revision, proposal_digest = view.proposal_digest, decision = decision})
                            test.is_true(assert(bounds.object(decision)).ok == true)
                            settled = true
                        end
                    end
                end
            end
            ticker:stop()
            runner_fixture.release(runner)
            if decision == "approved" then
                test.eq(outcome.error, "configuration published; durability requires inspection")
                test.eq(outcome.observed.publications, 1)
                local rendered = assert(bounds.object(assert(json.decode(tostring(outcome.observed.configuration)))))
                local providers = assert(bounds.object(rendered.provider))
                local provider = assert(bounds.object(providers.synthetic))
                test.eq(assert(bounds.object(provider.options)).apiKey, "{file:/synthetic/provider.key}")
            else
                test.is_true(assert(outcome.error):find("was denied", 1, true) ~= nil)
                test.eq(outcome.observed.publications, 0)
            end
            test.eq(approvals, 1)
            db:release()
        end)
        end
    end)
end
return test.run_cases(cases)
