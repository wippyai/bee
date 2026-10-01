-- MIT. Reopened conversations retain observations after their Work settles.
local test = require("test")
local harness = require("harness")
local agents = require("agents")
local sessions = require("sessions")
local protocol = require("protocol")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
local function object(value: unknown): Object
    local row = bounds.object(value)
    if not row then error("expected object") end
    return row
end
local function text(row: Object, key: string): string
    local value = row[key]
    if type(value) ~= "string" then error("expected " .. key) end
    return value
end
function M.probe(request: unknown): Object
    local args = object(request)
    local session_ref, work_ref = text(args, "session"), text(args, "work")
    -- The fixture's default contract binding is a scripted client. Use a typed
    -- historical handle here, with real owner await and journal observation reads.
    local session: sessions.Session = {incarnation = 1, snapshot = {session = session_ref, thread_ref = text(args, "thread"),
        revision = 1, incarnation = 1, title = "Read the guide", lifecycle = "closed", activity = "idle", queue_count = 0,
        execution = {state = "quiescent", evidence_at = "2026-10-01T00:00:00Z", stale = false},
        effective_limits = {}, continuity = {mode = "exact"}, actions = {}},
        ref = function(): string return session_ref end,
        get = function(self: sessions.Session): (sessions.Session, nil) return self, nil end,
        send = function(): (nil, nil) return nil, nil end,
        await = function(): (nil, nil) return nil, nil end,
        close = function(): (nil, nil) return nil, nil end,
        history = function(): (nil, nil) return nil, nil end}
    local work: sessions.Work = {session = session_ref, incarnation = 1, ref = function(): string return work_ref end,
        cancel = function(): (nil, nil) return nil, nil end, state = function(): (nil, nil) return nil, nil end,
        await = function(): (protocol.WorkAwait?, nil)
            local raw, err = funcs.call("bee.sessions.binding:await", {subject = work_ref, timeout_ms = 0})
            if err then error(tostring(err)) end
            local reply = object(raw)
            if reply.ok ~= true then error("await failed") end
            local awaited, decode_error = protocol.decode_work_await(reply.value)
            if not awaited then error(tostring(decode_error)) end
            return awaited, nil
        end}
    local conv: agents.Conversation = {session = session, title = session.snapshot.title, lifecycle = "closed", activity = "idle",
        queued = 0, notice = "", turns = {{work = work, input = "Read the guide", state = "queued", text = ""}}}
    agents.refresh(conv)
    agents.refresh(conv)
    local turn = conv.turns[1]
    if not turn then error("missing historical turn") end
    return {text = turn.text, state = turn.state, tools = turn.tools, diagnostics = turn.diagnostics}
end
local function define_tests()
    test.describe("Conversation observations", function()
        test.it("keeps late tool results and stderr in reopened history without replacing the final answer", function()
            local workspace = string.rep("f", 32)
            local journal = harness.session_owner(workspace)
            local opened = object(harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}})))
            local session = text(opened, "session")
            local sent = object(harness.value(journal:call("work_send", {session = session, input = "Read the guide", operation_key = harness.key()})))
            local reserved = object(harness.value(journal:call("turn_reserve", {session = session, operation_key = harness.key()})))
            local turn, claim = text(reserved, "turn"), text(reserved, "claim")
            local pulled = object(harness.value(journal:call("turn_pull", {turn = turn, claim = claim})))
            harness.value(journal:call("turn_accept", {turn = turn, claim = claim, input_digest = text(pulled, "input_digest"), checkpoint = {}, operation_key = harness.key()}))
            local function append(data: Object)
                harness.value(journal:call("turn_observation", {turn = turn, claim = claim, operation_key = harness.key(),
                    observation = {type = data.type, event_key = harness.key(), data = data}}))
            end
            append({type = "tool.call", call_id = "read-guide", tool_name = "Read", input = {text = "guide"}})
            -- Force the result and diagnostics onto a later read_after page.
            for _ = 1, 65 do append({type = "text", segment_id = "progress", channel = "progress", operation = "append", text = "Reading"}) end
            append({type = "tool.result", call_id = "read-guide", outcome = "succeeded", output = {text = "guide read"}})
            append({type = "text", segment_id = "executor-stderr", channel = "progress", operation = "append", text = "no stdin data received"})
            append({type = "text", segment_id = "answer", channel = "answer", operation = "replace", text = "partial answer"})
            harness.value(journal:call("work_settle", {turn = turn, claim = claim, operation_key = harness.key(),
                result = {state = "succeeded", schema = "bee:Text@1", value = {text = "Final answer\nSecond paragraph"}}}))
            local policies: {security.Policy} = {}
            for _, name in ipairs({"bee.tests.sessions:interactive_lifecycle_policy", "bee.threads:session_owner_test_policy",
                "bee.harness.security:harness_setup_policy", "bee.security.threads:thread_observe_policy"}) do
                policies[#policies + 1] = assert(security.policy(name))
            end
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = workspace}))
            local described = object(harness.value(journal:call("session_describe", {session = session})))
            local raw, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call(
                "bee.harness.profiles:observations_probe", {session = session, work = text(sent, "work"), thread = text(described, "thread_ref")})
            if err then error(tostring(err)) end
            local result = object(raw)
            test.eq(result.state, "ready")
            test.eq(result.text, "Final answer\nSecond paragraph")
            test.eq(object(result.tools)["read-guide"], "Tool: Read · succeeded")
            test.eq(result.diagnostics, "no stdin data received")
        end)
    end)
end
M.run = test.run_cases(define_tests)
return M
