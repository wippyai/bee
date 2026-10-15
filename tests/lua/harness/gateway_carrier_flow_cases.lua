-- MIT. Focused gateway carrier test cases.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local time = require("time")
local json = require("json")
local sql = require("sql")
local harness = require("harness")
local support = require("support")
local ACTOR = support.ACTOR
local POLICY = support.POLICY
local AUTHOR_WORKSPACE = support.AUTHOR_WORKSPACE
local SCRIPTED_AUTHOR_TIMEOUT_MS = support.SCRIPTED_AUTHOR_TIMEOUT_MS
type Object = support.Object
local fresh = support.fresh
local raw_call = support.raw_call
local call = support.call
local stream = support.stream
local install_policy = support.install_policy
local admit_root = support.admit_root
local open_gateway = support.open_gateway
local thread = support.thread
local request = support.request
type Outcome = support.Outcome
local spawn_carrier = support.spawn_carrier
local await_exit = support.await_exit
local run_carrier = support.run_carrier
local continue_carrier = support.continue_carrier
local await_paused = support.await_paused
local records_of = support.records_of
local report = support.report
local evidence_kinds = support.evidence_kinds
local has = support.has
local detail_with = support.detail_with
local await_evidence = support.await_evidence
local expect_evidence = support.expect_evidence
local expect_detail = support.expect_detail
local binding_of = support.binding_of
local await_presented = support.await_presented
local hook_report = support.hook_report
local hook_records = support.hook_records
local no_secret_in = support.no_secret_in
local no_token_in = support.no_token_in
local function define_tests()
    test.describe("Gateway through the carrier", function()
        install_policy(POLICY)
        install_policy("bee.tests.harness:gateway_surface_policy")
        admit_root()
        open_gateway()
        local readiness = call("bee.gateway.binding:ready", {})
        if readiness.listening ~= true then error("managed gateway readiness route did not become ready") end
        test.it("publishes no credential generation when credential insertion fails", function()
            local attempt_id = fresh("atomic-materialization")
            local crashed = run_carrier(request(thread(), attempt_id, {}), "open", "gateway_admitted")
            test.contains(tostring(crashed.error), "crash after gateway_admitted")
            local binding = binding_of(attempt_id, 1)
            local authorized = call("bee.gateway.binding:authorize_materialization", {
                attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding.binding_id})
            local db = assert(sql.get("bee:db"))
            assert(db:execute([[CREATE TRIGGER bee_test_credential_failure BEFORE INSERT ON bee_gateway_credentials
                WHEN NEW.binding_id IN (SELECT binding_id FROM bee_gateway_bindings WHERE attempt_id LIKE '%atomic-materialization%')
                BEGIN SELECT RAISE(ABORT, 'fixture credential insertion failure'); END]]))
            db:release()
            local policy = assert(security.policy("bee.security.gateway:gateway_materialize_policy"))
            local materializer = funcs.new():with_actor(principals.actor(ACTOR, nil))
                :with_scope(security.new_scope({policy, assert(security.policy("bee.tests.harness:gateway_client_policy"))}))
            local ok, result = pcall(function(): Object
                local raw, err = materializer:call("bee.gateway.binding:materialize", {
                attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding.binding_id,
                materialization_key = authorized.materialization_key})
                assert(not err, tostring(err))
                return assert(bounds.object(raw))
            end)
            db = assert(sql.get("bee:db"))
            assert(db:execute("DROP TRIGGER bee_test_credential_failure"))
            local rows = assert(db:query([[SELECT credential_generation, materialization_key_hash,
                (SELECT COUNT(*) FROM bee_gateway_credentials WHERE binding_id = ?) AS credentials
                FROM bee_gateway_bindings WHERE binding_id = ?]], {binding.binding_id, binding.binding_id}))
            db:release()
            assert(ok, tostring(result))
            test.is_false(result.ok == true)
            test.eq(assert(bounds.object(result.error)).code, "CONFLICT")
            test.eq(rows[1].credential_generation, 0, "generation and credentials publish together")
            test.eq(rows[1].credentials, 0)
            test.not_nil(rows[1].materialization_key_hash)
            test.is_true(call("bee.gateway.binding:check", {binding_id = binding.binding_id}).valid == true)
        end)
        test.it("starts a carrier when seeded session traits produce an approval reply", function()
            local workspace = string.rep("e", 32)
            local owner = harness.session_owner(workspace)
            local opened = harness.value(owner:call("session_create", {operation_key = fresh("session")}))
            local session = assert(bounds.id(opened.session))
            local described = harness.value(owner:call("session_describe", {session = session}))
            local member = harness.principal("sessions-owner", harness.ALL, workspace)
            harness.value(member:call("join", {thread_id = described.thread_ref, member_id = ACTOR, role = "participant", expected_revision = 1, idempotency_key = fresh("join")}))
            local entry = assert(registry.get(POLICY))
            local original = assert(bounds.object(entry.data))
            local changed: Object = {}
            for key, item in pairs(original) do changed[key] = item end
            changed.gateway_surface = {access = {policy = "agent-access", traits = {"bee.tests.memory:trait"}}}
            entry.data = changed
            local changes = registry.snapshot():changes(); changes:update(entry); assert(changes:apply())
            local ok, err = pcall(function()
                local requested = request(assert(bounds.id(described.thread_ref)), fresh("seeded"), {})
                requested.workspace_id = workspace
                requested.action_id = session
                requested.preferences = {active_traits = {"bee.tests.memory:trait"}, options = {}, instructions = ""}
                local outcome = run_carrier(requested, "open")
                test.not_nil(outcome.value, tostring(outcome.error))
                test.eq(assert(bounds.object(assert(outcome.value).settlement)).outcome, "succeeded")
            end)
            entry.data = original
            changes = registry.snapshot():changes(); changes:update(entry); assert(changes:apply())
            if not ok then error(tostring(err)) end
        end)
        test.it("reports the monitored startup exit cause while waiting for a pause", function()
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local pid = spawn_carrier(request(thread(), fresh("pause-exit"), {}), "open", "prepared", "attempt_started")
            local ok, failure = pcall(function() await_paused(paused, pid, "attempt_started", false) end)
            process.unlisten(paused)
            test.is_false(ok)
            test.is_true(tostring(failure):find("crash after prepared", 1, true) ~= nil, tostring(failure))
        end)
        test.it("admits after preparation, projects the token at delivery, serves the child as an MCP client and revokes on exit", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local outcome = run_carrier(request(thread_id, attempt_id, {}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            test.eq((assert(bounds.object(outcome.value.settlement))).outcome, "succeeded")
            local seen = report(thread_id)
            test.eq(seen.initialize, 200)
            test.eq(seen.protocol, "2025-06-18")
            test.eq(seen.list, 200)
            test.eq(json.encode(seen.tools), (json.encode({"call_tool", "capabilities", "session", "thread_read"})))
            test.eq(seen.read, 200)
            test.eq(seen.read_ok, true)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "gateway.materialized", true)
            expect_evidence(names, details, "gateway.sealed", true)
            expect_evidence(names, details, "carrier.lost", false)
            expect_detail(details, "credential generation 1 under carrier epoch 1", true)
            expect_detail(details, "child exited; binding", true)
            no_token_in(details)
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.valid, false)
            test.eq(binding.reason, "binding is revoked")
            test.eq(binding.credential_generation, 1)
        end)
        test.it("delivers configured traits and bounded context to the managed MCP child", function()
            local thread_id = thread()
            local result = run_carrier(request(thread_id, fresh("surface"), {BEE_FIXTURE_GATEWAY_SURFACE = "1"}, nil,
                "bee.tests.harness:gateway_surface_policy"), "open", nil)
            if not result.value then error("configured carrier failed: " .. tostring(result.error)) end
            test.eq((assert(bounds.object(result.value.settlement))).outcome, "succeeded")
            local seen = report(thread_id)
            test.eq(json.encode(seen.tools), (json.encode({"call_tool", "session", "thread_read"})))
            test.eq((assert(bounds.object(seen.surface_inactive))).code, -32602)
            test.eq((assert(bounds.object(seen.surface_selected))).ok, true)
            local current = assert(bounds.object((assert(bounds.object(seen.surface_after))).value))
            test.eq(current.revision, 2)
            test.eq(json.encode(current.active_traits), (json.encode({"research:read", "research:inspect"})))
            test.eq((assert(bounds.object(current.context))).experiment, "managed-one")
            test.eq((assert(bounds.object(seen.surface_dispatch))).ok, true)
            test.eq((assert(bounds.object(seen.surface_overwrite))).ok, false)
        end)
        test.it("replays the binding whose carrier was lost before projection and starts under it on retry", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {})
            local crashed = run_carrier(launch, "open", "gateway_admitted")
            test.is_nil(crashed.value)
            test.is_true(tostring(crashed.error):find("crash after gateway_admitted", 1, true) ~= nil)
            local before = binding_of(attempt_id, 1)
            test.eq(before.valid, true)
            test.eq(before.credential_generation, 0)
            -- The retry claims the same carrier epoch and admits the same
            -- identity, so the binding replays rather than multiplies; its
            -- first credential generation is minted at the retry's delivery.
            local retried = run_carrier(launch, "open", nil)
            if not retried.value then error("retried carrier failed: " .. tostring(retried.error)) end
            test.eq((assert(bounds.object(retried.value.settlement))).outcome, "succeeded")
            local replayed = call("bee.gateway.binding:check", {binding_id = before.binding_id})
            test.eq(replayed.credential_generation, 1)
            test.eq(replayed.valid, false)
            test.eq(replayed.reason, "binding is revoked")
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "gateway.materialized", true)
            expect_detail(details, "binding " .. tostring(before.binding_id) .. " credential generation 1", true)
        end)
        test.it("revokes a projected token when the child never starts", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            -- The working directory is a subpath the project root does not
            -- hold, so the executor refuses the start after the token was
            -- materialized into the environment.
            local outcome = run_carrier(request(thread_id, attempt_id, {}, "absent-directory"), "open", nil)
            test.is_nil(outcome.error)
            local settled = assert(bounds.object(assert(outcome.value).settlement))
            test.eq(settled.outcome, "failed")
            test.is_true(assert(bounds.text(settled.reason, 4096)):find("absent-directory", 1, true) ~= nil)
            -- The runner held the materialization key and the token when it
            -- refused; neither reaches the carrier's error nor the records.
            no_secret_in(tostring(settled.reason), "carrier failure")
            for _, item in ipairs(records_of(thread_id)) do no_secret_in(json.encode(item), "thread record") end
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "gateway.materialized", true)
            expect_evidence(names, details, "gateway.revoked", true)
            expect_detail(details, "start refused", true)
            expect_evidence(names, details, "child.exited", false)
            no_token_in(details)
            local status = call("bee.placement.native.binding:status", {attempt_id = attempt_id})
            test.eq((assert(bounds.object(status.attempt))).execution_state, "start_failed")
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.valid, false)
            test.eq(binding.reason, "binding is revoked")
        end)
        test.it("refuses the start when the listener generation changes between readiness and start", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local pid = spawn_carrier(request(thread_id, attempt_id, {}), "open", nil, "gateway_ready")
            await_paused(paused, pid, "gateway_ready", false)
            process.unlisten(paused)
            open_gateway()
            continue_carrier(pid)
            local outcome = await_exit(pid, "paused carrier")
            test.is_nil(outcome.value)
            test.is_true(tostring(outcome.error):find("earlier listener epoch", 1, true) ~= nil)
            local names, details = evidence_kinds(attempt_id)
            if not has(names, "gateway.refused") then error("evidence gateway.refused missing; carrier error: " .. tostring(outcome.error) .. "; evidence: " .. table.concat(details, " | ")) end
            expect_detail(details, "earlier listener epoch", true)
            expect_evidence(names, details, "gateway.materialized", false)
            expect_evidence(names, details, "child.exited", false)
            -- The failed startup revokes the binding; nothing was ever minted.
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.valid, false)
            test.eq(binding.reason, "binding is revoked")
            test.eq(binding.credential_generation, 0)
        end)
        test.it("retires the binding when the carrier is lost and no replacement takes over within the grace", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "stop"})
            local pid = spawn_carrier(launch, "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            local live = binding_of(attempt_id, 1)
            test.eq(live.valid, true)
            assert(process.terminate(pid), "terminate carrier")
            await_exit(pid, "terminated carrier")
            -- Once the runner has observed the loss, the child keeps its token
            -- within the takeover grace.
            await_evidence(attempt_id, "carrier.lost")
            local kept = binding_of(attempt_id, 1)
            test.eq(kept.valid, true)
            await_evidence(attempt_id, "gateway.revoked", "no takeover")
            local lost = binding_of(attempt_id, 1)
            test.eq(lost.valid, false)
            test.eq(lost.reason, "binding is revoked")
            -- The child holds until the enforcement path stops it, so it
            -- presents its token again only after the retirement.
            call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            test.eq(seen.after_hold, 401)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.lost", true)
            expect_detail(details, "lost under generation 1; no takeover", true)
            no_token_in(details)
        end)
        test.it("retires the binding when a replacement carrier is lost and nothing takes over", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "stop"})
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local old = spawn_carrier(launch, "open", nil, "attempt_started")
            await_paused(paused, old, "attempt_started", false)
            process.unlisten(paused)
            await_presented(attempt_id, 1, 3)
            local replacement = spawn_carrier(launch, "resume", nil, nil)
            await_evidence(attempt_id, "attach.fenced", "runner installed generation 2")
            assert(process.terminate(old), "terminate old carrier")
            await_exit(old, "old carrier")
            assert(process.terminate(replacement), "terminate replacement carrier")
            await_exit(replacement, "replacement carrier")
            await_evidence(attempt_id, "carrier.lost", "under generation 2")
            await_evidence(attempt_id, "gateway.revoked", "lost under generation 2; no takeover")
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.lost", true)
            no_token_in(details)
            local status = call("bee.placement.native.binding:status", {attempt_id = attempt_id})
            local runner = assert(bounds.id(assert(bounds.object(status.attempt)).runner))
            assert(process.monitor(runner))
            assert(process.terminate(runner), "terminate replacement-loss runner")
            await_exit(runner, "replacement-loss runner")
        end)
        test.it("records a carrier lost after its child exited, whichever the runner observes first", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {})
            local pid = spawn_carrier(launch, "open", nil, "attempt_started")
            -- The child ends on its own while the carrier holds, so the runner
            -- has observed its exit before the carrier is terminated.
            await_presented(attempt_id, 1, 3)
            await_evidence(attempt_id, "child.exited")
            assert(process.terminate(pid), "terminate carrier")
            await_exit(pid, "terminated carrier")
            await_evidence(attempt_id, "carrier.lost")
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            test.eq((assert(bounds.object(resumed.value.settlement))).outcome, "succeeded")
            test.eq(report(thread_id, attempt_id).read, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.replaced", true)
            no_token_in(details)
        end)
        test.it("keeps the child's token across a takeover and ignores the old carrier's delayed exit", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "4"})
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local old = spawn_carrier(launch, "open", nil, "attempt_started")
            await_paused(paused, old, "attempt_started", false)
            process.unlisten(paused)
            await_presented(attempt_id, 1, 3)
            local replacement = spawn_carrier(launch, "resume", nil, nil)
            -- The runner monitors generation 2 rather than
            -- the old carrier, whose exit then revokes nothing.
            await_evidence(attempt_id, "attach.fenced", "runner installed generation 2")
            assert(process.terminate(old), "terminate old carrier")
            await_exit(old, "old carrier")
            local inherited = binding_of(attempt_id, 2)
            test.eq(inherited.valid, true)
            test.eq(inherited.carrier_epoch, 1)
            local outcome = await_exit(replacement, "replacement carrier")
            if not outcome.value then error("replacement carrier failed: " .. tostring(outcome.error)) end
            test.eq(outcome.value.epoch, 2)
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            test.eq(seen.after_hold, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_detail(details, "runner installed generation 2", true)
            expect_evidence(names, details, "carrier.lost", false)
            expect_detail(details, "no takeover", false)
            -- Settlement under the replacement retires the inherited binding.
            local settled = binding_of(attempt_id, 2)
            test.eq(settled.valid, false)
            test.eq(settled.reason, "binding is revoked")
            no_token_in(details)
        end)
        -- Inside the takeover grace the binding is alive only for a takeover;
        -- an explicit revocation, a listener reopen and the binding's own
        -- expiry each take effect at once.
        local function lose_carrier_then(policy_ref: string?, act: (string) -> ()): Object
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "stop"}, nil, policy_ref)
            local pid = spawn_carrier(launch, "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            assert(process.terminate(pid), "terminate carrier")
            await_exit(pid, "terminated carrier")
            await_evidence(attempt_id, "carrier.lost")
            act(attempt_id)
            -- Force the real enforcement path instead of racing the periodic
            -- sweeper. The fixture must still report an actual HTTP denial.
            local status = call("bee.placement.native.binding:status", {attempt_id = attempt_id})
            local runner = (assert(bounds.object(status.attempt))).runner
            assert(type(runner) == "string", "live runner before revocation enforcement")
            assert(process.monitor(runner))
            -- The token changed while the original carrier was lost. Attach
            -- its consumer before enforcing the stop: output retention is a
            -- declared bound, and an absent consumer cannot acknowledge it.
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local replacement = spawn_carrier(launch, "resume", nil, "reattached")
            await_paused(paused, replacement, "reattached", false)
            process.unlisten(paused)
            local _, fenced_details = evidence_kinds(attempt_id)
            assert(detail_with(fenced_details, "runner installed generation 2"), "replacement attachment was not fenced")
            continue_carrier(replacement)
            call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
            local runner_exit = await_exit(runner, "native runner")
            if runner_exit.error then error("native runner: " .. runner_exit.error) end
            local resumed = await_exit(replacement, "replacement carrier")
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            local seen = report(thread_id, attempt_id)
            test.eq(seen.read, 200)
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "carrier.lost", true)
            expect_evidence(names, details, "gateway.revoked", true)
            expect_evidence(names, details, "stop.requested", true)
            no_token_in(details)
            return seen
        end
        test.it("refuses a token revoked inside the takeover grace at once", function()
            local seen = lose_carrier_then(nil, function(attempt_id: string)
                local live = binding_of(attempt_id, 1)
                test.eq(live.valid, true)
                call("bee.gateway.binding:revoke", {binding_id = live.binding_id})
            end)
            test.eq(seen.after_hold, 401)
        end)
        test.it("refuses a token whose listener generation changed inside the takeover grace at once", function()
            local seen = lose_carrier_then(nil, function(attempt_id: string)
                test.eq(binding_of(attempt_id, 1).valid, true)
                open_gateway()
            end)
            test.eq(seen.after_hold, 401)
        end)
        test.it("refuses a token that expires inside the takeover grace at once", function()
            local instant = assert(registry.get("bee.gateway:fixture_instant"))
            local succeeded, seen = pcall(function(): Object
                return lose_carrier_then(nil, function(attempt_id: string)
                    local live = binding_of(attempt_id, 1)
                    test.eq(live.valid, true)
                    assert(type(live.expires_at) == "string", "binding expiry")
                    instant.data = {at = live.expires_at}
                    local changes = assert(registry.snapshot()):changes()
                    changes:update(instant)
                    assert(changes:apply())
                    local expired = binding_of(attempt_id, 1)
                    test.eq(expired.valid, false)
                    test.eq(expired.reason, "binding has expired")
                end)
            end)
            instant.data = {}
            local changes = assert(registry.snapshot()):changes()
            changes:update(instant)
            assert(changes:apply())
            if not succeeded then error(tostring(seen)) end
            assert(type(seen) == "table", "expired token report")
            test.eq(seen.after_hold, 401)
        end)
        test.it("commits the child's hooks as records through its own commit path and keeps content out", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local outcome = run_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_RESULT_DELAY = "0.1"}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            test.eq((assert(bounds.object(outcome.value.settlement))).outcome, "succeeded")
            local reported = hook_report(thread_id)
            test.eq(json.encode(reported.statuses), (json.encode({202, 202, 202, 202, 202})))
            -- The carrier can commit the first occurrence before the child
            -- replays it: queued replay is 202, committed replay is 200.
            -- The records and final queue below still prove exactly one commit.
            test.is_true(reported.replay == 202 or reported.replay == 200)
            test.eq(reported.bodies_empty, true)
            local committed = hook_records(thread_id)
            local by_event: {[string]: integer} = {}
            for _, payload in ipairs(committed) do by_event[tostring(payload.event)] = (by_event[tostring(payload.event)] or 0) + 1 end
            for _, event in ipairs({"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}) do
                if by_event[event] ~= 1 then error("hook " .. event .. " committed " .. tostring(by_event[event]) .. " times") end
            end
            local text = json.encode(committed) or ""
            test.is_nil((text:find("sk-fixture", 1, true)))
            test.is_nil((text:find("the brief", 1, true)))
            test.is_nil((text:find("decision", 1, true)))
            test.is_true(text:find("content_digests", 1, true) ~= nil)
            local binding = binding_of(attempt_id, 1)
            test.eq(binding.reason, "binding is revoked")
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding.binding_id})
            for _, item in ipairs(principals.objects(queue.hooks)) do test.eq(item.status, "committed") end
            no_token_in({text})
        end)
        test.it("recovers a crash between the hook commit and its acknowledgment without a duplicate record", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_LINGER = "1"})
            local crashed = run_carrier(launch, "open", "hooks_committed")
            test.is_nil(crashed.value)
            test.is_true(tostring(crashed.error):find("crash after hooks_committed", 1, true) ~= nil)
            local resumed = run_carrier(launch, "resume", nil)
            if not resumed.value then error("resumed carrier failed: " .. tostring(resumed.error)) end
            test.eq((assert(bounds.object(resumed.value.settlement))).outcome, "succeeded")
            local committed = hook_records(thread_id)
            local seen: {[string]: integer} = {}
            for _, payload in ipairs(committed) do
                local key = tostring(payload.event) .. ":" .. tostring(payload.occurrence)
                seen[key] = (seen[key] or 0) + 1
            end
            for key, count in pairs(seen) do
                if count ~= 1 then error("hook " .. key .. " committed " .. tostring(count) .. " times after the crash") end
            end
            local binding = binding_of(attempt_id, 2)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding.binding_id})
            for _, item in ipairs(principals.objects(queue.hooks)) do
                if item.status == "queued" then error("a queued hook survived settlement: " .. tostring(item.event)) end
            end
        end)
        test.it("answers overload while the carrier is not draining and commits every accepted submission once it drains", function()
            -- The carrier is held right after the attempt starts, so nothing
            -- drains while the child floods; the queue fills to its bound, the
            -- child receives 429 past it, and once the carrier continues every
            -- accepted row ends committed.
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local pid = spawn_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_HOOKS_FLOOD = "80"}), "open", nil, "attempt_started")
            local binding_id = ""
            for _ = 1, 200 do
                local reply = raw_call("bee.gateway.binding:check", {attempt_id = attempt_id, carrier_epoch = 1})
                if reply.ok then
                    binding_id = tostring((assert(bounds.object(reply.value))).binding_id)
                    local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding_id})
                    local queued = 0
                    for _, item in ipairs(principals.objects(queue.hooks)) do
                        if item.status == "queued" then queued = queued + 1 end
                    end
                    if queued >= 64 then break end
                end
                time.sleep("50ms")
            end
            test.neq(binding_id, "")
            continue_carrier(pid)
            local outcome = await_exit(pid, "flooded carrier")
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local reported = hook_report(thread_id)
            local flood = assert(bounds.object(reported.flood))
            local accepted = (tonumber(flood["202"]) or 0)
            local refused = (tonumber(flood["429"]) or 0)
            test.eq(accepted + refused, 80)
            test.is_true(refused > 0)
            local committed = 0
            for _, payload in ipairs(hook_records(thread_id)) do
                if tostring(payload.occurrence):find("toolu_flood_", 1, true) then committed = committed + 1 end
            end
            test.eq(committed, accepted)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding_id})
            for _, item in ipairs(principals.objects(queue.hooks)) do
                if item.status == "queued" then error("a queued row survived: " .. tostring(item.occurrence)) end
            end
        end)
        -- Two live carriers on one queue: the replacement takes the rows over
        -- at its claim, and the fenced original can neither commit nor
        -- acknowledge them afterwards.
        local function two_carriers(pause_at: string)
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local launch = request(thread_id, attempt_id, {BEE_FIXTURE_HOOKS = "1", BEE_FIXTURE_GATEWAY_HOLD = "3"})
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            -- An original held after its commit holds again once its
            -- acknowledgment call returns.
            local pauses = pause_at
            if pause_at == "hooks_committed" then pauses = "hooks_committed,hooks_acknowledged" end
            local old = spawn_carrier(launch, "open", nil, pauses)
            await_paused(paused, old, pause_at, false)
            local replacement = spawn_carrier(launch, "resume", nil, nil)
            local outcome = await_exit(replacement, "replacement carrier")
            if not outcome.value then error("replacement carrier failed: " .. tostring(outcome.error)) end
            continue_carrier(old)
            -- An original held after its commit acknowledges nothing the
            -- replacement claimed; it then holds after that call or ends on its
            -- next refused commit, and is stopped once either is observed. One
            -- held before its commit is refused at the commit and ends on its
            -- own.
            local fenced: Outcome
            if pause_at == "hooks_committed" then
                await_paused(paused, old, "hooks_acknowledged", true)
                -- Cleanup may race the fenced carrier's own exit. The monitored
                -- EXIT below is the proof it stopped, not terminate's return.
                process.terminate(old)
            end
            process.unlisten(paused)
            fenced = await_exit(old, "fenced carrier")
            test.is_nil(fenced.value)
            local committed = hook_records(thread_id)
            local seen: {[string]: integer} = {}
            for _, payload in ipairs(committed) do
                local key = tostring(payload.event) .. ":" .. tostring(payload.occurrence)
                seen[key] = (seen[key] or 0) + 1
            end
            for key, count in pairs(seen) do
                if count ~= 1 then error("hook " .. key .. " committed " .. tostring(count) .. " times across two carriers") end
            end
            test.is_true(seen["PreToolUse:tool:toolu_fixture_1"] == 1)
            local binding = binding_of(attempt_id, 2)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding.binding_id})
            for _, item in ipairs(principals.objects(queue.hooks)) do
                if item.status == "queued" then error("a queued row survived the takeover: " .. tostring(item.occurrence)) end
                if item.status == "committed" and item.claimed_epoch ~= 2 then error("a row was acknowledged by an epoch that did not claim it: " .. tostring(item.claimed_epoch)) end
            end
            return fenced
        end
        test.it("lets a replacement take over rows the original claimed but never committed, and the original cannot acknowledge them", function()
            local fenced = two_carriers("hooks_claimed")
            local text = tostring(fenced.error)
            -- The thread refuses the original's commit: fenced by the newer
            -- epoch, or the attempt already ended under the replacement.
            if not (text:find("fenced", 1, true) or text:find("CONFLICT", 1, true) or text:find("epoch", 1, true) or text:find("DENIED", 1, true) or text:find("attempt has ended", 1, true)) then error("the original ended for another reason: " .. text) end
        end)
        test.it("lets a replacement replay rows the original committed but never acknowledged, leaving one observation", function()
            two_carriers("hooks_committed")
        end)
        test.it("lets a scripted agent author from the guide alone and repair a stray overlay on its remedy", function()
            -- The scripted child holds the plain request only: it learns the
            -- artifact from the overlay tool's guide operation over the real
            -- MCP surface. Round 1 authors only index.html and app.js and is
            -- refused with a named remedy; round 2 authors the guide's own
            -- example in the same overlay and the destination preflight is
            -- ready.
            install_policy("bee.tests.harness:gateway_author_policy")
            local source = "counter"
            local environment = {BEE_FIXTURE_GATEWAY_AUTHOR = "repair", BEE_FIXTURE_AUTHOR_WORKSPACE = source,
                BEE_FIXTURE_AUTHOR_SOURCE = source, BEE_FIXTURE_AUTHOR_DESTINATION = AUTHOR_WORKSPACE,
                BEE_FIXTURE_AUTHOR_VERSION = "1.0.0", BEE_FIXTURE_STREAM = stream("plain.jsonl")}
            local thread_id = thread(AUTHOR_WORKSPACE)
            local attempt_id = fresh("author")
            -- The gateway takes the delivery destination from the binding, so
            -- the authoring session is bound to the destination workspace.
            local authoring = request(thread_id, attempt_id, environment, nil, "bee.tests.harness:gateway_author_policy")
            authoring.workspace_id = AUTHOR_WORKSPACE
            local outcome = run_carrier(authoring, "open", nil, SCRIPTED_AUTHOR_TIMEOUT_MS)
            if not outcome.value then error("authoring carrier failed: " .. tostring(outcome.error)) end
            test.eq((assert(bounds.object(outcome.value.settlement))).outcome, "succeeded")
            local seen = report(thread_id)
            test.eq(seen.author_has_guide, true)
            test.is_true(type(seen.guide_document) == "string" and (seen.guide_document):find("entries.json", 1, true) ~= nil)
            test.eq(seen.guide_example_present, true)
            -- The stray round really held only the two files.
            local files = principals.objects(seen.author_files)
            test.eq(#files, 2)
            -- Round 1 was refused with a named code and a remedy.
            test.eq(seen.refusal_ok, false)
            test.eq(seen.refusal_code, "MISSING_ARTIFACT")
            test.is_true(type(seen.refusal_remedy) == "string" and (seen.refusal_remedy):find("entries.json", 1, true) ~= nil)
            -- Round 2 repaired exactly what the remedy named and delivery was ready.
            test.not_nil(seen.repaired_snapshot_digest)
            test.eq(seen.delivery_ready, true, assert(json.encode(seen.delivery_diagnostic_reply)))
            local steps = principals.strings(seen.delivery_human_steps)
            test.eq(#steps, 3)
        end)
        test.it("renews the binding of a live attempt for its supervisor past its first term, and never an ended one", function()
            local instant = assert(registry.get("bee.gateway:fixture_instant"))
            local original = instant.data
            local now = time.now()
            local function advance(duration: integer)
                now = now:add(tostring(duration) .. "ms")
                instant.data = {at = now:utc():format("2006-01-02T15:04:05.000Z07:00")}
                local changes = registry.snapshot():changes(); changes:update(instant); assert(changes:apply())
            end
            advance(0)
            local ok, problem = pcall(function()
                local thread_id = thread()
                local function admit(attempt_id: string): Object
                    return assert(bounds.object(call("bee.gateway.binding:admit", {subject = "carrier-fixture", action_id = fresh("action"), attempt_id = attempt_id,
                        thread_id = thread_id, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 2000}).binding))
                end
                local function renew(attempt_id: string): Object
                    return call("bee.gateway.binding:renew_attempt", {attempt_id = attempt_id, carrier_epoch = 1})
                end
                local live_attempt, idle_attempt, sealed_attempt = fresh("lease-live"), fresh("lease-idle"), fresh("lease-sealed")
                local live = admit(live_attempt)
                admit(idle_attempt)
                local sealed = admit(sealed_attempt)
                call("bee.gateway.binding:seal", {binding_id = sealed.binding_id})
                test.eq(renew(live_attempt).renewed, 0)
                test.eq(binding_of(live_attempt, 1).expires_at, live.expires_at)
                advance(1100)
                test.eq(renew(live_attempt).renewed, 1)
                test.eq(renew(sealed_attempt).renewed, 0)
                advance(1100)
                test.eq(binding_of(live_attempt, 1).valid, true)
                local idle = binding_of(idle_attempt, 1)
                test.eq(idle.valid, false)
                test.eq(idle.reason, "binding has expired")
                test.eq(renew(idle_attempt).renewed, 0)
                test.eq(binding_of(idle_attempt, 1).valid, false)
                test.eq(binding_of(sealed_attempt, 1).valid, false)
            end)
            instant.data = original
            local changes = registry.snapshot():changes(); changes:update(instant); assert(changes:apply())
            if not ok then error(tostring(problem)) end
        end)
        test.it("drains without admitting a new child while a bound child finishes", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local pid = spawn_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "1"}), "open", nil, "placement_started")
            await_presented(attempt_id, 1, 3)
            call("bee.gateway.binding:drain", {deadline_ms = 8000})
            local refused = raw_call("bee.gateway.binding:admit", {subject = "carrier-fixture", action_id = fresh("action"),
                attempt_id = fresh("drained"), thread_id = thread_id, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}})
            test.eq(refused.ok, false)
            test.eq((assert(bounds.object(refused.error))).code, "UNAVAILABLE")
            continue_carrier(pid)
            local outcome = await_exit(pid, "draining carrier")
            open_gateway()
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            test.eq((assert(bounds.object(outcome.value.settlement))).outcome, "succeeded")
            test.eq(report(thread_id).after_hold, 200)
        end)
        test.it("refuses a token revoked while the child uses it", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local pid = spawn_carrier(request(thread_id, attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "10"}), "open", nil, "attempt_started")
            await_presented(attempt_id, 1, 3)
            local live = binding_of(attempt_id, 1)
            test.eq(live.valid, true)
            call("bee.gateway.binding:revoke", {binding_id = live.binding_id})
            call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
            continue_carrier(pid)
            local outcome = await_exit(pid, "revoked carrier")
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local seen = report(thread_id)
            test.eq(seen.read, 200)
            test.eq(seen.after_hold, 401)
        end)
    end)
end
return {define = define_tests}
