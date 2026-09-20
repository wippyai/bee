local test = require("test")
local reducer = require("reducer")

local DIGEST = string.rep("a", 64)
type Binding = reducer.Binding
type Prepare = reducer.Prepare
type Effect = reducer.Effect
type Event = reducer.Event

local function prepare(): Prepare
    return {instance_id = "instance", thread_id = "thread", definition_id = "bee.example:app",
        actor_id = "bee.application:instance", role = "participant", idempotency_key = "open-once",
        definition_revision = "revision-1", initiating_owner_id = "owner-1", gateway_binding_id = "gateway-1",
        gateway_approval_id = "approval-1", gateway_proposal_digest = DIGEST, access = "observe_post",
        join_expected_revision = 7}
end

local function binding(state: "pending" | "active" | "revoked", revision: integer, membership: integer?, cleanup: 0 | 1,
    cleanup_revision: integer?, join_revision: integer?): Binding
    return {instance_id = "instance", thread_id = "thread", definition_id = "bee.example:app",
        actor_id = "bee.application:instance", role = "participant", binding_revision = revision,
        state = state, idempotency_key = "open-once", definition_revision = "revision-1",
        initiating_owner_id = "owner-1", gateway_binding_id = "gateway-1", gateway_approval_id = "approval-1",
        gateway_proposal_digest = DIGEST, access = "observe_post", join_expected_revision = join_revision or 7,
        membership_revision = membership, cleanup_pending = cleanup,
        cleanup_expected_revision = cleanup_revision}
end

local function host(state: "pending" | "active" | "revoked", revision: integer, membership: integer?, cleanup: 0 | 1,
    cleanup_revision: integer?, join_revision: integer?): Binding
    return binding(state, revision, membership, cleanup, cleanup_revision, join_revision)
end

local function field(effect: Effect?, name: string): unknown
    if type(effect) ~= "table" then return nil end
    return (effect :: {[string]: unknown})[name]
end
local function open_event(): Event return {kind = "open", value = prepare()} end
local function recover_event(value: Binding): Event return {kind = "recover", binding = value} end
local function host_event(op: "prepare" | "activate" | "refresh_join" | "begin_revoke" | "refresh_cleanup" | "finish_revoke",
    outcome: "success" | "failure" | "unknown", value: Binding?): Event
    return {kind = "host", op = op, outcome = outcome, binding = value}
end
local function membership_event(principal: "owner" | "application",
    purpose: "join" | "after_join" | "after_unknown_join" | "active_recovery" | "cleanup" | "join_refresh" | "cleanup_refresh",
    state: "active" | "absent" | "unknown", head: integer?, member: integer?): Event
    return {kind = "membership", principal = principal, purpose = purpose, state = state,
        head_revision = head, membership_revision = member}
end
local function join_event(outcome: "success" | "conflict" | "unknown"): Event return {kind = "join", outcome = outcome} end
local function leave_event(outcome: "success" | "conflict" | "unknown"): Event return {kind = "leave", outcome = outcome} end
local function revoke_event(): Event return {kind = "revoke"} end

local function define_tests()
    test.describe("Application thread binding reducer", function()
        test.it("opens, joins, verifies membership and activates once", function()
            local state, effect = reducer.reduce(reducer.new(), open_event())
            test.eq(field(effect, "kind"), "host")
            test.eq(field(effect, "op"), "prepare")

            state, effect = reducer.reduce(state, host_event("prepare", "success", host("pending", 1, nil, 0, nil, 7)))
            test.eq(field(effect, "kind"), "join")
            test.eq(field(effect, "expected_revision"), 7)
            state, effect = reducer.reduce(state, join_event("success"))
            test.eq(field(effect, "kind"), "membership")
            test.eq(field(effect, "principal"), "application")
            test.eq(field(effect, "purpose"), "after_join")
            state, effect = reducer.reduce(state, membership_event("application", "after_join", "active", 10, 9))
            test.eq(field(effect, "kind"), "host")
            test.eq(field(effect, "op"), "activate")
            local activate_value = field(effect, "value") :: {[string]: unknown}
            test.eq(activate_value.membership_revision, 9)
            state, effect = reducer.reduce(state, host_event("activate", "success", host("active", 2, 9, 0, nil, 7)))
            test.eq(effect, "active")
            test.eq(state.terminal, "active")
        end)

        test.it("recovers pending bindings with one bounded join refresh", function()
            local pending = host("pending", 1, nil, 0, nil, 7)
            local state, effect = reducer.reduce(reducer.new(), recover_event(pending))
            test.eq(field(effect, "kind"), "join")
            test.eq(field(effect, "expected_revision"), 7)
            state, effect = reducer.reduce(state, membership_event("application", "join", "absent", nil, nil))
            test.is_nil(effect)
            state, effect = reducer.reduce(state, join_event("conflict"))
            test.eq(field(effect, "kind"), "membership")
            test.eq(field(effect, "principal"), "owner")
            test.eq(field(effect, "purpose"), "join_refresh")
            state, effect = reducer.reduce(state, membership_event("owner", "join_refresh", "active", 12, nil))
            test.eq(field(effect, "kind"), "host")
            test.eq(field(effect, "op"), "refresh_join")
            test.eq((field(effect, "value") :: {[string]: unknown}).join_expected_revision, 12)
            state, effect = reducer.reduce(state, host_event("refresh_join", "success", host("pending", 2, nil, 0, nil, 12)))
            test.eq(field(effect, "kind"), "join")
            test.eq(field(effect, "expected_revision"), 12)
            state, effect = reducer.reduce(state, join_event("conflict"))
            test.eq(field(effect, "kind"), "host")
            test.eq(field(effect, "op"), "begin_revoke")
            test.eq((field(effect, "value") :: {[string]: unknown}).cleanup_expected_revision, 12)
        end)

        test.it("requires the exact membership revision during active recovery", function()
            local active = host("active", 4, 11, 0, nil, 7)
            local state, effect = reducer.reduce(reducer.new(), recover_event(active))
            test.eq(field(effect, "purpose"), "active_recovery")
            state, effect = reducer.reduce(state, membership_event("application", "active_recovery", "active", nil, 11))
            test.eq(effect, "active")

            state, effect = reducer.reduce(reducer.new(), recover_event(active))
            state, effect = reducer.reduce(state, membership_event("application", "active_recovery", "active", nil, 12))
            test.eq(field(effect, "kind"), "host")
            test.eq(field(effect, "op"), "begin_revoke")
            state, effect = reducer.reduce(reducer.new(), recover_event(active))
            state, effect = reducer.reduce(state, membership_event("application", "active_recovery", "unknown", nil, nil))
            test.eq(effect, "retry")
            test.eq(state.binding, active)
            state, effect = reducer.reduce(reducer.new(), recover_event(active))
            state, effect = reducer.reduce(state, membership_event("application", "active_recovery", "absent", nil, nil))
            test.eq(field(effect, "op"), "begin_revoke")
        end)

        test.it("cleans a revoked row and bounds cleanup refresh", function()
            local revoked = host("revoked", 6, 11, 1, 15, 7)
            local state, effect = reducer.reduce(reducer.new(), recover_event(revoked))
            test.eq(field(effect, "kind"), "membership")
            state, effect = reducer.reduce(state, membership_event("application", "cleanup", "active", nil, 11))
            test.eq(field(effect, "kind"), "leave")
            test.eq(field(effect, "expected_revision"), 15)
            state, effect = reducer.reduce(state, leave_event("conflict"))
            test.eq(field(effect, "principal"), "owner")
            test.eq(field(effect, "purpose"), "cleanup_refresh")
            state, effect = reducer.reduce(state, membership_event("owner", "cleanup_refresh", "active", 18, nil))
            test.eq(field(effect, "op"), "refresh_cleanup")
            state, effect = reducer.reduce(state, host_event("refresh_cleanup", "success", host("revoked", 7, 11, 1, 18, 7)))
            test.eq(field(effect, "kind"), "leave")
            state, effect = reducer.reduce(state, leave_event("unknown"))
            test.eq(effect, "cleanup_pending")

            state, effect = reducer.reduce(reducer.new(), recover_event(revoked))
            state, effect = reducer.reduce(state, membership_event("application", "cleanup", "active", nil, 12))
            test.eq(effect, "cleanup_pending")
        end)

        test.it("uses the stored head to revoke and never activates late", function()
            local pending = host("pending", 1, nil, 0, nil, 7)
            local state, effect = reducer.reduce(reducer.new(), recover_event(pending))
            state, effect = reducer.reduce(state, join_event("success"))
            state, effect = reducer.reduce(state, membership_event("application", "after_join", "active", nil, 9))
            test.eq(field(effect, "op"), "activate")
            state, effect = reducer.reduce(state, revoke_event())
            test.is_nil(effect)
            test.eq(state.intent, "revoke")
            state, effect = reducer.reduce(state, host_event("activate", "success", host("active", 2, 9, 0, nil, 7)))
            test.eq(field(effect, "op"), "begin_revoke")
            test.eq((field(effect, "value") :: {[string]: unknown}).expected_state, "active")
            test.eq((field(effect, "value") :: {[string]: unknown}).cleanup_expected_revision, 7)
        end)

        test.it("does not turn unknown join or leave outcomes into absence", function()
            local pending = host("pending", 1, nil, 0, nil, 7)
            local state, effect = reducer.reduce(reducer.new(), recover_event(pending))
            test.eq(field(effect, "kind"), "join")
            state, effect = reducer.reduce(state, join_event("unknown"))
            test.eq(field(effect, "purpose"), "after_unknown_join")
            state, effect = reducer.reduce(state, membership_event("application", "after_unknown_join", "unknown", nil, nil))
            test.eq(effect, "retry")

            local revoked = host("revoked", 2, 9, 1, 7, 7)
            state, effect = reducer.reduce(reducer.new(), recover_event(revoked))
            state, effect = reducer.reduce(state, membership_event("application", "cleanup", "active", nil, 9))
            state, effect = reducer.reduce(state, leave_event("unknown"))
            test.eq(effect, "cleanup_pending")
        end)

        test.it("does not reissue durable revocation while cleanup is independent", function()
            local active = host("active", 4, 11, 0, nil, 7)
            local state, effect = reducer.reduce(reducer.new(), recover_event(active))
            test.eq(field(effect, "purpose"), "active_recovery")

            state, effect = reducer.reduce(state, revoke_event())
            test.is_nil(effect)
            state, effect = reducer.reduce(state, membership_event("application", "active_recovery", "absent", nil, nil))
            test.eq(field(effect, "kind"), "host")
            test.eq(field(effect, "op"), "begin_revoke")

            local revoked = host("revoked", 5, 11, 1, 7, 7)
            state, effect = reducer.reduce(state, host_event("begin_revoke", "success", revoked))
            test.eq(field(effect, "kind"), "membership")
            test.eq(field(effect, "purpose"), "cleanup")

            state, effect = reducer.reduce(state, revoke_event())
            test.is_nil(effect)
            test.eq(state.binding, revoked)
            test.eq(field(state.outstanding, "purpose"), "cleanup")
        end)
    end)
end

return test.run_cases(define_tests)
