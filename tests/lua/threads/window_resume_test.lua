-- MIT. A window session's hooks reach the thread through its carrier, so a
-- reopened or restored window resumes the provider conversation they name.
local test = require("test")
local host = require("host")
local harness = require("harness")
local bounds = require("bounds")
local hook_records = require("hook_records")
local checkpoint = require("checkpoint")
local continuation = require("continuation")
local claude = require("claude")
local codex = require("codex")
local agy = require("agy")
local muse = require("muse")
-- The window argv each driver's descriptor forms to resume a conversation.
local function resume_argv(driver: string, resume_ref: string): string
    local value = {profile_id = "window", brief = "", resume_ref = resume_ref}
    local argv: {string}
    if driver == "claude" then argv = claude.specification(assert(claude.decode(value))).argv
    elseif driver == "codex" then argv = codex.specification(assert(codex.decode(value))).argv
    elseif driver == "agy" then argv = agy.specification(assert(agy.decode(value))).argv
    else argv = muse.specification(assert(muse.decode(value))).argv end
    return table.concat(argv, " ")
end
-- The provider fields each CLI reports its conversation with.
local function conversation_fields(driver: string, conversation: string): {[string]: unknown}
    if driver == "agy" then return {conversationId = conversation} end
    return {session_id = conversation, source = "startup"}
end
local DIGEST = string.rep("a", 64)
local METHODS: {[string]: string} = {}
for _, method in ipairs({"prepare", "start", "status", "stop", "reconcile", "cleanup", "evidence", "attach", "capabilities", "measure_executable", "close_stdin"}) do
    METHODS[method] = "bee.tests.placement:" .. method
end
-- The previous window as its owner reports it: ended, its process exited
-- and cleaned up, its checkpoint pinned to the hook binding it used, and the
-- thread holding the records its carrier committed.
type Call = (string, unknown) -> (unknown, string?)
local function owner(binding_id: string, records: {{[string]: unknown}}): Call
    local point = checkpoint.new({binding_ref = "driver:binding", binding_digest = "binding-digest", profile_id = "window",
        profile_digest = "profile-digest", gateway_binding = binding_id}, 1)
    point.retained_session_ref = "session"
    local rows: {unknown} = {}
    for index, item in ipairs(records) do
        rows[index] = {schema_revision = "bee.thread-record@1", record_id = "record:" .. tostring(index), thread_id = "thread",
            sequence = index, recorded_at = "2026-11-05T10:00:00.000Z", kind = "observation", producer_id = "alice", source = item.source,
            action_id = "action", attempt_id = "previous", body = item.body}
    end
    return function(target: string, _input: unknown): (unknown, string?)
        if target == "bee.threads.binding:checkpoint" then
            return {ok = true, value = {attempt_id = "previous", action_id = "action", attempt_state = "ended", attempt_outcome = "cancelled",
                placement_binding = "bee.tests.placement:binding", placement_binding_digest = DIGEST, checkpoint = point}}, nil
        end
        if target == METHODS.status then
            return {ok = true, value = {private_home = false, attempt = {attempt_id = "previous", action_id = "action", owner_id = "alice",
                session_ref = "session", execution_state = "exited", cleanup_state = "complete"}}}, nil
        end
        test.eq(target, "bee.threads.binding:read_after")
        return {ok = true, value = {records = rows, scanned_through = #rows, has_more = false}}, nil
    end
end
local function define_tests(driver: string)
    test.describe("Window resume through hook records", function()
        test.after_all(host.close_all)
        test.it(driver .. " records its window hooks on the thread and its restored window resumes that conversation", function()
            local session = host.open(nil, nil, driver, nil, nil, {"SessionStart"})
            harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
            local _, endpoint, token = host.transport(session)
            local conversation = "conversation-" .. harness.key()
            host.cli_hook(session, "SessionStart", conversation_fields(driver, conversation), assert(token), endpoint, driver == "codex")
            local claimed = host.call("bee.gateway.binding:hook_claim", {binding_id = session.binding.binding_id,
                carrier_epoch = session.binding.carrier_epoch, limit = 16})
            local claimed_hooks = assert(bounds.array(claimed.hooks, 16))
            test.eq(#claimed_hooks, 1, "the delivered hook waits for its carrier")
            local batch = assert(hook_records.batch(session.binding.binding_id, nil, claimed_hooks))
            local request: continuation.Request = {thread_id = "thread", action_id = "action", attempt_id = "next", owner_id = "alice",
                previous_attempt_id = "previous", session_ref = "session", binding_ref = "driver:binding", binding_digest = "binding-digest",
                profile_id = "window", profile_digest = "profile-digest", placement_binding_ref = "bee.tests.placement:binding",
                placement_binding_digest = DIGEST, placement_methods = METHODS}
            local resumed, resume_error = continuation.resolve_window(owner(session.binding.binding_id, batch.records), request)
            test.is_nil(resume_error)
            test.eq(resumed, conversation)
            local argv = resume_argv(driver, assert(resumed))
            local flags = {claude = "-r ", codex = "resume ", agy = "--conversation ", muse = "resume "}
            test.is_true(argv:find(flags[driver] .. conversation, 1, true) ~= nil, driver .. " resume argv: " .. argv)
            host.call("bee.gateway.binding:hook_ack", {binding_id = session.binding.binding_id, carrier_epoch = session.binding.carrier_epoch,
                event_ids = batch.event_ids})
        end)
    end)
end
local methods = {}
for _, driver in ipairs({"claude", "codex", "agy", "muse"}) do
    methods[driver] = test.run_cases(function() define_tests(driver) end)
end
return methods
