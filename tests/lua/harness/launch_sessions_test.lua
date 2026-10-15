-- MIT. Sessions launch behaviour.
local test = require("test")
local carrier_fixtures = require("carrier_fixtures")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local admission = require("admission")
local machine = require("machine")
local checkpoint = require("checkpoint")
local hook_records = require("hook_records")
local placement_store = require("placement_store")
local bounds = require("bounds")
local fixture = require("fixture")
local DEFINITION = fixture.DEFINITION
local RETAINED_DEFINITION = fixture.RETAINED_DEFINITION
local POLICY = fixture.POLICY
local ROOT = fixture.ROOT
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local value = fixture.value
local code = fixture.code
local apply = fixture.apply
local carrier_io = fixture.carrier_io
local await_settled = fixture.await_settled
local kinds = fixture.kinds
local count = fixture.count
local function define_tests()
    test.describe("Launch sessions", function()
        local workspace = fixture.prepare()
        test.it("fans two managed research actions into one caller-owned durable thread", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local shared = fresh("autoresearch")
                value(call("bee.threads.binding:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Autoresearch"}))
                local first_id, second_id = fresh("research-one"), fresh("research-two")
                local first = value(call("bee.tests.harness.launch:start", {request_id = first_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the first hypothesis", thread_id = shared}))
                local second = value(call("bee.tests.harness.launch:start", {request_id = second_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the second hypothesis", thread_id = shared}))
                test.eq(first.thread_id, shared)
                test.eq(second.thread_id, shared)
                test.neq(first.action_id, second.action_id)
                test.neq(first.attempt_id, second.attempt_id)
                test.eq(await_settled(shared, tostring(first.attempt_id)).answer, "pong")
                test.eq(await_settled(shared, tostring(second.attempt_id)).answer, "pong")
                local records = kinds(shared)
                test.eq(count(records, "action.admitted"), 2)
                test.eq(count(records, "attempt.prepared"), 2)
                test.eq(count(records, "attempt.started"), 2)
                test.eq(count(records, "turn.request"), 2)
                test.eq(count(records, "receipt"), 2)
                local subscribed = value(call("bee.threads.binding:subscribe", {thread_id = shared,
                    idempotency_key = fresh("subscribe"), consumer_id = "autoresearch-coordinator",
                    after_sequence = 0, filter = {kinds = {"receipt"}}, durability = "durable"}))
                local page = value(call("bee.threads.binding:page", {thread_id = shared,
                    subscription_id = subscribed.subscription_id}))
                test.eq(#(principals.items(page.records)), 2)
                value(call("bee.threads.binding:ack_page", {thread_id = shared,
                    idempotency_key = fresh("ack-page"), subscription_id = subscribed.subscription_id,
                    page_id = page.page_id, scanned_through = page.scanned_through}))
                local detached = value(call("bee.threads.binding:unsubscribe", {thread_id = shared,
                    idempotency_key = fresh("detach-consumer"), subscription_id = subscribed.subscription_id}))
                test.is_true(detached.closed)
                local resumed = value(call("bee.threads.binding:resume", {thread_id = shared,
                    idempotency_key = fresh("resume-consumer"), subscription_id = subscribed.subscription_id}))
                test.eq(resumed.lease_generation, 2)
                local caught_up = value(call("bee.threads.binding:page", {thread_id = shared,
                    subscription_id = subscribed.subscription_id}))
                test.eq(#(principals.items(caught_up.records)), 0)
                test.is_nil(caught_up.page_id)
                value(call("bee.threads.binding:unsubscribe", {thread_id = shared,
                    idempotency_key = fresh("close-consumer"), subscription_id = subscribed.subscription_id}))
                local settled_replay = value(call("bee.tests.harness.launch:start", {request_id = first_id,
                    definition_ref = DEFINITION, workspace_id = workspace, brief = "investigate the first hypothesis", thread_id = shared}))
                test.eq(settled_replay.mode, "settled")
                test.eq(settled_replay.thread_id, first.thread_id)
                test.eq(settled_replay.action_id, first.action_id)
                test.eq(settled_replay.attempt_id, first.attempt_id)
                test.eq(count(kinds(shared), "receipt"), 2)
                test.eq(count(kinds(shared), "receipt"), 2)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("readmits a recorded window with fresh grants and its original action and session", function()
            -- Construct committed predecessor state through the actual owners.
            -- No native process is started: placement completion is an explicit
            -- store fixture, not evidence of native process cleanup.
            local entry = registry.get(RETAINED_DEFINITION)
            if not entry then error("retained definition") end
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.profile_id, changed.default_mode = "window", "window"
            entry.data = changed
            apply(entry)
            local policy_entry = registry.get(POLICY)
            if not policy_entry then error("fixture policy") end
            local original_policy = policy_entry.data
            local window_policy: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_policy))) do window_policy[key] = item end
            window_policy.prepare_options = {permission_mode = "manual"}
            window_policy.allow_host_home = true
            policy_entry.data = window_policy
            apply(policy_entry)
            local origin = fresh("window-origin")
            local first = value(call("bee.tests.harness.launch:admit", {request_id = origin, definition_ref = RETAINED_DEFINITION,
                workspace_id = workspace, brief = ""}))
            local transport = carrier_io(workspace)
            local planned, plan_error = machine.plan(transport, carrier_fixtures.request(first.request))
            if not planned then error(tostring(plan_error)) end
            local prepared, prepare_error = machine.prepare_attempt(transport, planned)
            if not prepared then error(tostring(prepare_error)) end
            local first_plan = assert(bounds.object(first.plan))
            assert(type(first_plan.binding_ref) == "string" and type(first_plan.binding_digest) == "string" and type(first_plan.profile_id) == "string" and type(first_plan.profile_digest) == "string" and type(first_plan.plan_digest) == "string")
            assert(type(first.attempt_id) == "string" and type(first.thread_id) == "string")
            local point = checkpoint.new({binding_ref = first_plan.binding_ref, binding_digest = first_plan.binding_digest,
                profile_id = first_plan.profile_id, profile_digest = first_plan.profile_digest, gateway_binding = "recorded-binding"}, prepared.epoch)
            point.retained_session_ref = first.session_ref
            local records, records_error = hook_records.batch("recorded-binding", nil, {{event_id = "session-start", event = "SessionStart",
                occurrence = "session:provider-session", ambiguous = false, provenance = "fixture", sequence = 1,
                fields = {event = "SessionStart", session_id = "provider-session", source = "startup"}}})
            if not records then error(tostring(records_error)) end
            value(call("bee.threads.binding:commit", {thread_id = first.thread_id, attempt_id = first.attempt_id,
                idempotency_key = fresh("commit"), carrier_epoch = prepared.epoch, expected_revision = 0, checkpoint = point, records = records.records}))
            local request: admission.Request = {request_id = fresh("resume"), definition_ref = RETAINED_DEFINITION, workspace_id = workspace,
                brief = "", expected_plan_digest = first_plan.plan_digest,
                continuation = {origin_request_id = origin, previous_attempt_id = first.attempt_id, thread_id = first.thread_id}}
            local refused_resume = call("bee.tests.harness.launch:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            value(call("bee.threads.binding:receipt", {thread_id = first.thread_id, action_id = first.action_id, attempt_id = first.attempt_id,
                idempotency_key = fresh("receipt"), carrier_epoch = prepared.epoch, receipt = {scope = "attempt", outcome = "cancelled", evidence_refs = {},
                    error = {code = "fixture_closed", message = "predecessor fixture closed", retryable = false}}}))
            local refused_resume = call("bee.tests.harness.launch:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            local db, db_error = placement_store.open()
            if not db then error(tostring(db_error)) end
            test.is_true(placement_store.transition(db, first.attempt_id, {execution = "starting", evidence = {kind = "fixture", detail = "no process started"}}).ok)
            test.is_true(placement_store.transition(db, first.attempt_id, {execution = "exited", evidence = {kind = "fixture", detail = "no process exists"}}).ok)
            local refused_resume = call("bee.tests.harness.launch:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            test.is_true(placement_store.transition(db, first.attempt_id, {cleanup = "complete", evidence = {kind = "fixture", detail = "no home materialized"}}).ok)
            db:release()
            local resumed = value(call("bee.tests.harness.launch:admit", request))
            test.eq(resumed.action_id, first.action_id)
            test.eq(resumed.thread_id, first.thread_id)
            test.eq(resumed.session_ref, first.session_ref)
            test.eq(resumed.attempt_id, "attempt:" .. request.request_id)
            test.eq(resumed.request.previous_attempt_id, first.attempt_id)
            test.eq(resumed.request.brief, "")
            test.eq(resumed.request.resources[1].name, first.request.resources[1].name)
            test.is_true(resumed.request.resources[1].grant_ref ~= first.request.resources[1].grant_ref)
            local replay = value(call("bee.tests.harness.launch:admit", request))
            test.eq(replay.request.resources[1].grant_ref, resumed.request.resources[1].grant_ref)
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request.request_id})), "NOT_FOUND")
            local resume_plan, resume_error = machine.plan(transport, carrier_fixtures.request(resumed.request))
            if not resume_plan then error(tostring(resume_error)) end
            test.eq(resume_plan.resume_ref, "provider-session")
            test.is_nil(resume_plan.launch.stdin)
            test.eq(resume_plan.launch.argv[#resume_plan.launch.argv], "provider-session")
            local prior_retention = window_policy.retain_ms
            window_policy.retain_ms = 54321
            policy_entry.data = window_policy
            apply(policy_entry)
            request.request_id = fresh("reviewed-resume")
            request.continuation.reauthorize = true
            local refused_resume = call("bee.tests.harness.launch:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            local current, current_error = admission.resolve(RETAINED_DEFINITION, "window")
            if not current then error(tostring(current_error)) end
            request.expected_plan_digest = current.plan_digest
            local reviewed = value(call("bee.tests.harness.launch:admit", request))
            test.eq(reviewed.plan.plan_digest, current.plan_digest)
            test.eq(reviewed.session_ref, first.session_ref)
            test.eq(reviewed.action_id, first.action_id)
            test.is_true(reviewed.request.reauthorize)
            local reviewed_plan, reviewed_error = machine.plan(transport, carrier_fixtures.request(reviewed.request))
            if not reviewed_plan then error(tostring(reviewed_error)) end
            test.eq(reviewed_plan.resume_ref, "provider-session")
            window_policy.retain_ms = prior_retention
            policy_entry.data = window_policy
            apply(policy_entry)
            request.expected_plan_digest = first.plan.plan_digest
            request.continuation.reauthorize = false
            -- Mutated saved references and changed host plans cannot select
            -- another session or silently replay under new configuration.
            request.workspace_id = fresh("foreign-workspace")
            local refused_resume = call("bee.tests.harness.launch:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            request.workspace_id = workspace
            request.expected_plan_digest = string.rep("0", 64)
            local refused_resume = call("bee.tests.harness.launch:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            request.continuation.reauthorize = true
            test.eq(code(call("bee.tests.harness.launch:admit", request)), "CONFLICT", "review never bypasses the current plan fence")
            request.continuation.reauthorize = false
            request.expected_plan_digest = first.plan.plan_digest
            request.brief = "repeat original prompt"
            test.eq(code(call("bee.tests.harness.launch:admit", request)), "INVALID")
            request.brief = ""
            local foreign, foreign_error = funcs.new():with_actor(security.new_actor("bee.test.foreign")):with_scope(scope()):call("bee.tests.harness.launch:admit", request)
            if foreign_error then error(tostring(foreign_error)) end
            test.is_false((principals.reply(foreign)).ok)
            -- Current resource authority must approve again; the old grant
            -- and committed hook do not authorize a new attempt.
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "read"}))
            request.request_id = fresh("revoked-resume")
            test.is_false(call("bee.tests.harness.launch:admit", request).ok)
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            entry.data = original
            apply(entry)
            policy_entry.data = original_policy
            apply(policy_entry)
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
