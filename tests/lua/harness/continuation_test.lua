-- MIT. Continuation comes from a successful owner receipt and native session.
local test = require("test")
local continuation = require("continuation")
local checkpoint = require("checkpoint")
local hook_records = require("hook_records")
local codex = require("codex")
local claude = require("claude")
local machine = require("machine")
local catalog = require("catalog")
local hooks = require("hooks")
local interrupted = require("interrupted")
local placement_fixture = require("placement_fixture")
local PLACEMENT = placement_fixture.resolve()
local PLACEMENT_METHODS = PLACEMENT.methods
local function observation(sequence: integer, session: string, binding: string, ambiguous: boolean, attempt: string): {[string]: unknown}
    local batch, err = hook_records.batch(binding, nil, {{event_id = "event:" .. tostring(sequence), event = "SessionStart",
        occurrence = "session:" .. session, ambiguous = ambiguous, provenance = "fixture", sequence = sequence,
        fields = {event = "SessionStart", session_id = session, source = "resume"}}})
    if not batch then error(tostring(err)) end
    return {schema_revision = "bee.thread-record@1", record_id = "record:" .. tostring(sequence), thread_id = "thread",
        sequence = sequence, recorded_at = "2026-09-12T10:00:00.000Z", kind = "observation", producer_id = "alice", source = "bee",
        action_id = "action", attempt_id = attempt, body = batch.records[1].body}
end
local function tool_observation(sequence: integer, session: string, binding: string, event: string): {[string]: unknown}
    local fields: {[string]: unknown} = {event = event, session_id = session, tool_use_id = "tool:" .. tostring(sequence), tool_name = "provider_maintenance"}
    local batch, err = hook_records.batch(binding, nil, {{event_id = "event:" .. tostring(sequence), event = event,
        occurrence = "tool:" .. tostring(sequence), ambiguous = false, provenance = "fixture", sequence = sequence, fields = fields}})
    if not batch then error(tostring(err)) end
    return {schema_revision = "bee.thread-record@1", record_id = "record:" .. tostring(sequence), thread_id = "thread",
        sequence = sequence, recorded_at = "2026-09-12T10:00:00.000Z", kind = "observation", producer_id = "alice", source = "bee",
        action_id = "action", attempt_id = "previous", body = batch.records[1].body}
end
local function define_tests()
    test.describe("Native harness continuation", function()
        test.it("uses the committed provider resume reference and refuses a mismatched or unfinished predecessor", function()
            local point = checkpoint.new({binding_ref = "driver:binding", binding_digest = "binding-digest", profile_id = "batch", profile_digest = "profile-digest"}, 1)
            point.retained_session_ref = "session"
            point.output = "complete"
            point.terminal = {outcome = "succeeded", resume_ref = "native-session"}
            local stored: {[string]: unknown} = {attempt_id = "previous", action_id = "action", attempt_state = "ended", attempt_outcome = "succeeded", placement_binding = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest, checkpoint = point}
            local attempt: {[string]: unknown} = {attempt_id = "previous", action_id = "action", owner_id = "alice", session_ref = "session", execution_state = "exited"}
            local placement_calls = 0
            local function call(target: string, input: unknown): (unknown, string?)
                if target == "bee.threads.carrier:checkpoint" then return {ok = true, value = stored}, nil end
                test.eq(target, PLACEMENT_METHODS.status)
                placement_calls = placement_calls + 1
                return {ok = true, value = {attempt = attempt}}, nil
            end
            local request: continuation.Request = {thread_id = "thread", action_id = "action", attempt_id = "next", owner_id = "alice", previous_attempt_id = "previous", session_ref = "session",
                binding_ref = "driver:binding", binding_digest = "binding-digest", profile_id = "batch", profile_digest = "profile-digest",
                placement_binding_ref = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest, placement_methods = PLACEMENT_METHODS}
            local resumed, err = continuation.resolve(call, request)
            test.is_nil(err)
            test.eq(resumed, "native-session")
            test.eq(placement_calls, 1)
            stored.placement_binding_digest = nil
            test.is_nil(continuation.resolve(call, request))
            test.eq(placement_calls, 1, "missing historical placement digest is rejected before status")
            stored.placement_binding_digest = PLACEMENT.binding_digest
            stored.placement_binding = "example.placement:binding"
            test.is_nil(continuation.resolve(call, request))
            test.eq(placement_calls, 1, "placement mismatch is rejected before status")
            stored.placement_binding = PLACEMENT.binding_id
            for _, state in ipairs({"prepared", "running"}) do
                stored.attempt_state = state
                test.is_nil(continuation.resolve(call, request))
            end
            stored.attempt_state = "ended"
            for _, outcome in ipairs({"failed", "cancelled", "uncertain"}) do
                stored.attempt_outcome = outcome
                test.is_nil(continuation.resolve(call, request))
            end
            stored.attempt_outcome = "succeeded"
            stored.action_id = "foreign"
            test.is_nil(continuation.resolve(call, request))
            stored.action_id = "action"
            point.binding_digest = "replacement-driver"
            test.is_nil(continuation.resolve(call, request))
            point.binding_digest = "binding-digest"
            point.retained_session_ref = "other-session"
            test.is_nil(continuation.resolve(call, request))
            point.retained_session_ref = "session"
            point.output = "open"
            test.eq(continuation.resolve(call, request), "native-session")
            test.eq(point.output, "open")
            point.output = "complete"
            point.terminal = {outcome = "succeeded"}
            test.is_nil(continuation.resolve(call, request))
            point.terminal = {outcome = "succeeded", resume_ref = "native-session"}
            attempt.owner_id = "bob"
            test.is_nil(continuation.resolve(call, request))
            attempt.owner_id = "alice"
            attempt.execution_state = "running"
            test.is_nil(continuation.resolve(call, request))
        end)
        test.it("resolves an ended window from committed hook pages without claiming a successful turn", function()
            local point = checkpoint.new({binding_ref = "driver:binding", binding_digest = "binding-digest", profile_id = "window",
                profile_digest = "profile-digest", gateway_binding = "old-binding"}, 1)
            point.retained_session_ref = "session"
            local stored: {[string]: unknown} = {attempt_id = "previous", action_id = "action", attempt_state = "ended", attempt_outcome = "cancelled", placement_binding = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest, checkpoint = point}
            local attempt: {[string]: unknown} = {attempt_id = "previous", action_id = "action", owner_id = "alice", session_ref = "session",
                execution_state = "exited", cleanup_state = "complete"}
            local rows: {unknown} = {observation(1025, "provider-session", "old-binding", false, "previous"),
                observation(1026, "unrelated-session", "other-binding", false, "other-attempt"),
                observation(1027, "provider-session", "old-binding", true, "previous")}
            local foreign = observation(1028, "forged-session", "old-binding", false, "previous")
            foreign.producer_id = "another-member"
            rows[#rows + 1] = foreign
            local scanned = 1028
            local more = false
            local denied = false
            local reads = 0
            local cleanup_calls = 0
            local cleanup_reply: unknown = {ok = false, error = {code = "CONFLICT"}}
            local function call(target: string, input: unknown): (unknown, string?)
                if target == "bee.threads.carrier:checkpoint" then return {ok = true, value = stored}, nil end
                if target == PLACEMENT_METHODS.status then return {ok = true, value = {attempt = attempt, private_home = true}}, nil end
                if target == PLACEMENT_METHODS.cleanup then
                    test.eq((input :: {[string]: unknown}).attempt_id, "previous")
                    cleanup_calls = cleanup_calls + 1
                    return cleanup_reply, nil
                end
                test.eq(target, "bee.threads.service:read_after")
                reads = reads + 1
                if denied then return {ok = false, error = {code = "DENIED"}}, nil end
                local request = input :: {[string]: unknown}
                test.eq(request.thread_id, "thread")
                test.eq(request.limit, 64)
                local filter = request.filter :: {[string]: unknown}
                test.eq(filter.action_id, "action")
                if request.cursor == 0 then return {ok = true, value = {records = {}, scanned_through = 1024, has_more = true}}, nil end
                test.eq(request.cursor, 1024)
                return {ok = true, value = {records = rows, scanned_through = scanned, has_more = more}}, nil
            end
            local request: continuation.Request = {thread_id = "thread", action_id = "action", attempt_id = "next", owner_id = "alice",
                previous_attempt_id = "previous", session_ref = "session", binding_ref = "driver:binding", binding_digest = "binding-digest",
                profile_id = "window", profile_digest = "profile-digest", placement_binding_ref = PLACEMENT.binding_id,
                placement_binding_digest = PLACEMENT.binding_digest, placement_methods = PLACEMENT_METHODS}
            stored.attempt_state = "running"
            attempt.execution_state = "running"
            local inspected = continuation.inspect_window(call, request, false)
            test.is_true(inspected ~= nil)
            test.eq(cleanup_calls, 0, "inspection never cleans a live process")
            test.eq(reads, 0, "inspection does not scan observations")
            test.is_nil(continuation.resolve_window(call, request))
            attempt.owner_id = "foreign"
            test.is_nil(continuation.inspect_window(call, request, false))
            attempt.owner_id = "alice"
            stored.open_turn_id = "live-turn"
            test.is_nil(continuation.inspect_window(call, request, false))
            stored.open_turn_id = nil
            stored.attempt_state = "ended"
            attempt.execution_state = "exited"
            local initial_resume, initial_error, initial_private_home = continuation.resolve_window(call, request)
            test.eq(initial_resume, "provider-session")
            test.is_nil(initial_error)
            test.eq(initial_private_home, true)
            test.eq(reads, 2)
            -- Reviewing a new implementation never rewrites historical pins.
            -- Automatic restore still refuses that same changed preparation.
            stored.placement_binding_digest = nil
            test.is_nil(continuation.resolve_window(call, request))
            request.reauthorize = true
            test.eq(continuation.resolve_window(call, request), "provider-session")
            test.is_nil(stored.placement_binding_digest)
            stored.placement_binding_digest = string.rep("a", 64)
            test.eq(continuation.resolve_window(call, request), "provider-session")
            stored.placement_binding = "other:placement"
            test.is_nil(continuation.resolve_window(call, request))
            stored.placement_binding = PLACEMENT.binding_id
            attempt.execution_state = "running"
            test.is_nil(continuation.resolve_window(call, request))
            attempt.execution_state = "exited"
            attempt.owner_id = "foreign"
            test.is_nil(continuation.resolve_window(call, request))
            attempt.owner_id = "alice"
            attempt.session_ref = "other-session"
            test.is_nil(continuation.resolve_window(call, request))
            attempt.session_ref = "session"
            request.profile_digest = "other-profile"
            test.eq(continuation.resolve_window(call, request), "provider-session")
            request.reauthorize = false
            test.is_nil(continuation.resolve_window(call, request))
            request.reauthorize = true
            request.profile_id = "other-window"
            test.is_nil(continuation.resolve_window(call, request))
            request.profile_id = "window"
            request.binding_digest = "other-binding-digest"
            test.eq(continuation.resolve_window(call, request), "provider-session")
            request.binding_ref = "other:binding"
            test.is_nil(continuation.resolve_window(call, request))
            request.binding_ref = "driver:binding"
            request.binding_digest = "binding-digest"
            request.profile_digest = "profile-digest"
            request.reauthorize = false
            stored.placement_binding_digest = PLACEMENT.binding_digest
            test.eq(stored.attempt_outcome, "cancelled")
            test.is_nil(point.terminal)
            test.is_nil(continuation.resolve(call, request))
            stored.attempt_outcome = "uncertain"
            test.eq(continuation.resolve_window(call, request), "provider-session")
            test.eq(stored.attempt_outcome, "uncertain")
            local saved_private_home = true
            local original_call = call
            -- A window whose previous session never began a conversation
            -- names that exact condition, so recovery can end the window
            -- rather than offer a resume that cannot exist.
            local saved_rows = rows
            rows = {}
            local unresumable, unresumable_error = continuation.resolve_window(call, request)
            test.is_nil(unresumable)
            test.eq(unresumable_error, continuation.NO_CONVERSATION)
            rows = saved_rows
            local function missing_home(target: string, input: unknown): (unknown, string?)
                if target == PLACEMENT_METHODS.status and saved_private_home then
                    return {ok = true, value = {attempt = attempt}}, nil
                end
                return original_call(target, input)
            end
            test.is_nil(continuation.resolve_window(missing_home, request))
            saved_private_home = false
            rows = {observation(1025, "provider-session", "old-binding", false, "previous"),
                observation(1026, "different-session", "old-binding", true, "previous")}
            test.is_nil(continuation.resolve_window(call, request))
            rows = {observation(1025, "provider-session", "old-binding", false, "previous"),
                observation(1027, "provider-session", "old-binding", true, "previous")}
            table.insert(rows, 2, tool_observation(1026, "provider-maintenance-session", "old-binding", "PreToolUse"))
            scanned = 1027
            test.eq(continuation.resolve_window(call, request), "provider-session")
            rows = {observation(1025, "provider-session", "old-binding", false, "previous"),
                observation(1027, "provider-session", "old-binding", true, "previous")}
            denied = true
            test.is_nil(continuation.resolve_window(call, request))
            denied = false
            for _, state in ipairs({"pending", "uncertain"}) do
                attempt.cleanup_state = state
                local before = cleanup_calls
                test.is_nil(continuation.resolve_window(call, request))
                test.eq(cleanup_calls, before + 1)
            end
            local cleaned: {[string]: unknown} = {attempt_id = "previous", action_id = "action", owner_id = "alice",
                session_ref = "session", execution_state = "exited", cleanup_state = "complete"}
            cleanup_reply = {ok = true, value = cleaned}
            test.eq(continuation.resolve_window(call, request), "provider-session")
            for _, field in ipairs({"attempt_id", "action_id", "owner_id", "session_ref", "execution_state", "cleanup_state"}) do
                local original = cleaned[field]
                cleaned[field] = "foreign"
                test.is_nil(continuation.resolve_window(call, request))
                cleaned[field] = original
            end
            local before_invalid = cleanup_calls
            rows = {}
            test.is_nil(continuation.resolve_window(call, request))
            test.eq(cleanup_calls, before_invalid, "no cleanup without a verified conversation")
            rows = {observation(1025, "provider-session", "old-binding", false, "previous")}
            attempt.owner_id = "foreign"
            test.is_nil(continuation.resolve_window(call, request))
            test.eq(cleanup_calls, before_invalid, "no cleanup of another owner's attempt")
            attempt.owner_id = "alice"
            attempt.execution_state = "running"
            test.is_nil(continuation.resolve_window(call, request))
            test.eq(cleanup_calls, before_invalid, "no cleanup of a live attempt")
            attempt.cleanup_state = "complete"
            attempt.execution_state = "running"
            test.is_nil(continuation.resolve_window(call, request))
            attempt.execution_state = "exited"
            attempt.owner_id = "foreign"
            test.is_nil(continuation.resolve_window(call, request))
            attempt.owner_id = "alice"
            point.profile_digest = "changed"
            test.is_nil(continuation.resolve_window(call, request))
            point.profile_digest = "profile-digest"
            point.retained_session_ref = "foreign-session"
            test.is_nil(continuation.resolve_window(call, request))
            point.retained_session_ref = "session"
            stored.action_id = "foreign-action"
            test.is_nil(continuation.resolve_window(call, request))
            stored.action_id = "action"
            stored.open_turn_id = "open-turn"
            test.is_nil(continuation.resolve_window(call, request))
            stored.open_turn_id = nil
            rows = {observation(1025, "different", "old-binding", false, "previous"), observation(1026, "provider-session", "old-binding", false, "previous")}
            test.is_nil(continuation.resolve_window(call, request))
            rows = {observation(1025, "provider-session", "new-binding", false, "previous")}
            test.is_nil(continuation.resolve_window(call, request))
            rows = {observation(1025, "provider-session", "old-binding", true, "previous")}
            test.eq(continuation.resolve_window(call, request), "provider-session")
            rows = {foreign}
            test.is_nil(continuation.resolve_window(call, request))
            rows = {}
            test.is_nil(continuation.resolve_window(call, request))
            scanned, more = 1024, true
            test.is_nil(continuation.resolve_window(call, request))
            scanned, more = 1027, false
            rows = {observation(1028, "provider-session", "old-binding", false, "previous")}
            test.is_nil(continuation.resolve_window(call, request))
        end)
        test.it("resumes interrupted hooks with historical pins after implementation review", function()
            local point = checkpoint.new({binding_ref = "driver:binding", binding_digest = "historical-binding",
                profile_id = "window", profile_digest = "historical-profile", plan_digest = "historical-plan",
                gateway_binding = "historical-gateway"}, 1)
            point.retained_session_ref = "session"
            local stored: {[string]: unknown} = {attempt_id = "previous", action_id = "action", attempt_state = "running",
                placement_binding = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest, checkpoint = point}
            local attempt: {[string]: unknown} = {attempt_id = "previous", action_id = "action", owner_id = "alice",
                session_ref = "session", execution_state = "exited", cleanup_state = "complete"}
            local receipt: {[string]: unknown}? = nil
            local captured: hooks.Config? = nil
            local function fake_call(target: string, input: unknown): (unknown, string?)
                if target == "bee.threads.carrier:checkpoint" then return {ok = true, value = stored}, nil end
                if target == PLACEMENT_METHODS.status then return {ok = true, value = {attempt = attempt, private_home = true}}, nil end
                if target == PLACEMENT_METHODS.reconcile then return {ok = true, value = attempt}, nil end
                if target == "bee.threads.carrier:claim" then
                    return {ok = true, value = {attempt_id = "previous", action_id = "action", carrier_epoch = 2,
                        checkpoint_revision = 1, checkpoint = point}}, nil
                end
                if target == "bee.threads.service:receipt" then
                    receipt = input :: {[string]: unknown}
                    return {ok = true, value = {}}, nil
                end
                return nil, "unexpected recovery target " .. target
            end
            local function fake_resume(config: hooks.Config, recovered: checkpoint.Checkpoint?, revision: integer): (hooks.State?, string?)
                captured = config
                local disabled: hooks.Config = {thread_id = config.thread_id, attempt_id = config.attempt_id, epoch = config.epoch,
                    binding_ref = config.binding_ref, binding_digest = config.binding_digest, profile_id = config.profile_id,
                    profile_digest = config.profile_digest, plan_digest = config.plan_digest, session_ref = config.session_ref,
                    gateway_binding = nil, hooks_enabled = false, drain_ms = config.drain_ms, decoder = config.decoder}
                local state = hooks.new(disabled)
                state.started = true
                return state, nil
            end
            local recovered, recover_error = interrupted.recover({thread_id = "thread", action_id = "action", attempt_id = "next",
                    owner_id = "alice", previous_attempt_id = "previous", session_ref = "session", binding_ref = "driver:binding",
                    binding_digest = "current-binding", profile_id = "window", profile_digest = "current-profile",
                    placement_binding_ref = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest,
                    placement_methods = PLACEMENT_METHODS, reauthorize = true}, fake_call, fake_resume)
            if not recovered then error(tostring(recover_error)) end
            if not captured then error("hooks.resume was not called") end
            test.eq(captured.binding_ref, "driver:binding")
            test.eq(captured.binding_digest, "historical-binding")
            test.eq(captured.profile_id, "window")
            test.eq(captured.profile_digest, "historical-profile")
            test.eq(captured.plan_digest, "historical-plan")
            test.eq(captured.gateway_binding, "historical-gateway")
            test.eq(receipt and (receipt :: {[string]: unknown}).attempt_id, "previous")
        end)
        test.it("forms native resume argv with no prompt or stdin replay", function()
            local codex_request, codex_error = codex.decode({profile_id = "window", brief = "", resume_ref = "provider-session"})
            if not codex_request then error(tostring(codex_error)) end
            local codex_launch = codex.specification(codex_request)
            test.eq(table.concat(codex_launch.argv, " "), "--sandbox read-only resume provider-session")
            test.is_nil(codex_launch.stdin)
            local claude_request, claude_error = claude.decode({profile_id = "window", brief = "", resume_ref = "provider-session"})
            if not claude_request then error(tostring(claude_error)) end
            local claude_launch = claude.specification(claude_request)
            test.eq(table.concat(claude_launch.argv, " "), "--permission-mode default -r provider-session")
            test.is_nil(claude_launch.stdin)
            -- A recorded reference is one argument, never an extra CLI flag.
            for _, reference in ipairs({"--dangerously-bypass-approvals-and-sandbox", "--dangerously-skip-permissions", "--", "-p"}) do
                test.is_nil(codex.decode({profile_id = "window", brief = "", resume_ref = reference}))
                test.is_nil(claude.decode({profile_id = "window", brief = "", resume_ref = reference}))
                test.is_nil(codex.decode({profile_id = "batch", brief = "next", resume_ref = reference}))
                test.is_nil(claude.decode({profile_id = "batch", brief = "next", resume_ref = reference}))
            end
        end)
        test.it("routes window plans through interactive resume and rejects brief replay before dispatch", function()
            local snapshot, snapshot_error = catalog.snapshot()
            if not snapshot then error(tostring(snapshot_error)) end
            local binding_digest, profile_digest = "", ""
            for _, binding in ipairs(snapshot.bindings) do
                if binding.binding_id == "bee.driver.claude:binding" then
                    binding_digest, profile_digest = binding.binding_digest.entry, binding.profile_digest.entry
                end
            end
            test.is_true(binding_digest ~= "")
            local point = checkpoint.new({binding_ref = "bee.driver.claude:binding", binding_digest = binding_digest,
                profile_id = "window", profile_digest = profile_digest, gateway_binding = "old-binding"}, 1)
            point.retained_session_ref = "session"
            local calls = 0
            local dispatched = 0
            local io: machine.IO = {
                call = function(target: string, input: unknown): (unknown, string?)
                    calls = calls + 1
                    if target == "bee.threads.carrier:checkpoint" then
                        return {ok = true, value = {attempt_id = "previous", action_id = "action", attempt_state = "ended", attempt_outcome = "cancelled", placement_binding = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest, checkpoint = point}}, nil
                    elseif target == PLACEMENT_METHODS.status then
                        return {ok = true, value = {private_home = true, attempt = {attempt_id = "previous", action_id = "action", owner_id = "alice",
                            session_ref = "session", execution_state = "exited", cleanup_state = "complete"}}}, nil
                    elseif target == "bee.threads.service:read_after" then
                        return {ok = true, value = {records = {observation(1, "provider-session", "old-binding", false, "previous")}, scanned_through = 1, has_more = false}}, nil
                    end
                    test.eq(target, "bee.driver.claude.binding:dispatch")
                    local request = input :: {[string]: unknown}
                    test.eq(request.profile_id, "window")
                    test.eq(request.resume_ref, "provider-session")
                    test.eq(request.brief, "")
                    dispatched = dispatched + 1
                    return {ok = false, error = "dispatch reached"}, nil
                end,
                send = function(target: string, topic: string, input: unknown) error("unexpected side effect") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local request: machine.Request = {thread_id = "thread", action_id = "action", attempt_id = "next", owner_id = "alice", owner_incarnation = 1,
                binding_ref = "bee.driver.claude:binding", profile_id = "window", brief = "", policy_ref = "bee.harness.catalog:fixture_policy",
                placement_binding_ref = PLACEMENT.binding_id, placement_binding_digest = PLACEMENT.binding_digest, placement_methods = PLACEMENT_METHODS,
                resources = {}, environment = {}, previous_attempt_id = "previous", session_ref = "session"}
            local planned, err = machine.plan(io, request)
            test.is_nil(planned)
            test.is_true(err ~= nil and err:find("dispatch reached", 1, true) ~= nil)
            test.eq(dispatched, 1)
            calls = 0
            request.brief = "never replay this input"
            local denied, denied_error = machine.plan(io, request)
            test.is_nil(denied)
            test.eq(denied_error, "window continuation cannot replay a brief")
            test.eq(calls, 0)
            test.eq(dispatched, 1)
        end)
    end)
end
return test.run_cases(define_tests)
