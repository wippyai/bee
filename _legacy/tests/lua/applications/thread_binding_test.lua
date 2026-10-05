local test = require("test")
local binding = require("thread_binding")

local WORKSPACE = "0123456789abcdef0123456789abcdef"
local function value(): {[string]: unknown}
    return {instance_id = "app-1", thread_id = "thread-1", actor_id = "bee.application:" .. WORKSPACE .. ":app-1",
        role = "participant", initiating_owner_id = "agent-1"}
end
local function reply(actor: string, role: string, active: boolean): {[string]: unknown}
    return {ok = true, replayed = false, value = {summary = {thread_id = "thread-1", title = "Research", state = "open",
        revision = 7, head_sequence = 4, owner_id = "agent-1", created_at = "2026-09-20T10:11:12.123Z"},
        membership = {member_id = actor, role = role, revision = 6, active = active}}}
end
local function failure(code: string): {[string]: unknown}
    return {ok = false, replayed = false, error = {code = code, message = "thread result", retryable = false}}
end

local function define_tests()
    test.describe("Application thread binding", function()
        test.it("derives the stable actor and exact authority calls", function()
            test.eq(binding.actor(WORKSPACE, "app-1"), "bee.application:" .. WORKSPACE .. ":app-1")
            test.is_nil(binding.actor("workspace", "app-1"))
            local get = assert(binding.get_request(value(), WORKSPACE))
            test.eq(get.thread_id, "thread-1")
            local get_fields = 0; for _ in pairs(get) do get_fields = get_fields + 1 end
            test.eq(get_fields, 1)
            local join = assert(binding.join_request(value(), WORKSPACE, "join-1", 7))
            test.eq(join.thread_id, "thread-1"); test.eq(join.idempotency_key, "join-1")
            test.eq(join.member_id, "bee.application:" .. WORKSPACE .. ":app-1")
            test.eq(join.role, "participant"); test.eq(join.expected_revision, 7)
            local join_fields = 0; for _ in pairs(join) do join_fields = join_fields + 1 end
            test.eq(join_fields, 5)
            local leave = assert(binding.leave_request(value(), WORKSPACE, "leave-1", 8))
            test.eq(leave.thread_id, "thread-1"); test.eq(leave.idempotency_key, "leave-1")
            test.eq(leave.member_id, "bee.application:" .. WORKSPACE .. ":app-1")
            test.is_nil(leave.role); test.eq(leave.expected_revision, 8)
            local leave_fields = 0; for _ in pairs(leave) do leave_fields = leave_fields + 1 end
            test.eq(leave_fields, 4)
        end)

        test.it("proves the owner and app memberships against the exact binding", function()
            test.eq(binding.owner_get(reply("agent-1", "owner", true), value(), WORKSPACE), 7)
            local app = assert(binding.application_get(reply("bee.application:" .. WORKSPACE .. ":app-1", "participant", true), value(), WORKSPACE))
            test.eq(app.head_revision, 7); test.eq(app.membership_revision, 6)
            test.is_nil(binding.owner_get(reply("agent-1", "participant", true), value(), WORKSPACE))
            test.is_nil(binding.application_get(reply("bee.application:" .. WORKSPACE .. ":app-1", "observer", true), value(), WORKSPACE))
            test.is_nil(binding.application_get(reply("bee.application:" .. WORKSPACE .. ":app-1", "participant", false), value(), WORKSPACE))
            local closed = reply("agent-1", "owner", true); closed.value.summary.state = "closed"
            test.is_nil(binding.owner_get(closed, value(), WORKSPACE))
            test.eq(binding.owner_head(closed, value(), WORKSPACE), 7)
            test.is_nil(binding.owner_head(reply("agent-1", "participant", true), value(), WORKSPACE))
        end)

        test.it("distinguishes active, absent and unknown application membership", function()
            local active = binding.application_status(reply("bee.application:" .. WORKSPACE .. ":app-1", "participant", true), value(), WORKSPACE)
            test.eq(active.state, "active")
            test.eq(active.head_revision, 7)
            test.eq(active.membership_revision, 6)

            local absent = binding.application_status(failure("DENIED"), value(), WORKSPACE)
            test.eq(absent.state, "absent")
            test.is_nil(absent.head_revision)
            absent = binding.application_status(failure("NOT_FOUND"), value(), WORKSPACE)
            test.eq(absent.state, "absent")
            local inactive = binding.application_status(reply("bee.application:" .. WORKSPACE .. ":app-1", "participant", false), value(), WORKSPACE)
            test.eq(inactive.state, "absent")
            test.eq(inactive.head_revision, 7)
            test.eq(inactive.membership_revision, 6)

            local unknown = binding.application_status(failure("BUSY"), value(), WORKSPACE)
            test.eq(unknown.state, "unknown")
            unknown = binding.application_status(nil, value(), WORKSPACE)
            test.eq(unknown.state, "unknown")
            local malformed = reply("bee.application:" .. WORKSPACE .. ":app-1", "participant", true)
            malformed.value.membership.member_id = "other"
            unknown = binding.application_status(malformed, value(), WORKSPACE)
            test.eq(unknown.state, "unknown")
        end)

        test.it("rejects malformed replies, identities, revisions and extra fields", function()
            local forged = reply("agent-1", "owner", true)
            forged.value.summary.thread_id = "other"
            test.is_nil(binding.owner_get(forged, value(), WORKSPACE))
            forged = reply("agent-1", "owner", true); forged.value.membership.extra = true
            test.is_nil(binding.owner_get(forged, value(), WORKSPACE))
            forged = reply("agent-1", "owner", true); forged.error = {code = "DENIED", message = "mixed", retryable = false}
            test.is_nil(binding.reply(forged))
            forged = reply("agent-1", "owner", true); forged.value.summary.revision = 0
            test.is_nil(binding.owner_get(forged, value(), WORKSPACE))
            local bad = value(); bad.actor_id = "bee.application:" .. WORKSPACE .. ":forged"
            test.is_nil(binding.get_request(bad, WORKSPACE))
            test.is_nil(binding.join_request(value(), WORKSPACE, "key", 0))
            test.is_nil(binding.leave_request(value(), WORKSPACE, "", 1))
        end)
    end)
end

return test.run_cases(define_tests)
