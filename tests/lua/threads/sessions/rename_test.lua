-- MIT. Renaming a session: its title shows the explicit name, the automatic
-- first-prompt title never replaces it, the name is durable, and an empty
-- name returns the session to its automatic title.
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local WORKSPACE = string.rep("a", 32)
local OTHER_WORKSPACE = string.rep("b", 32)

type Object = {[string]: unknown}

local function caller(actor_id: string, workspace: string): funcs.Executor
    local actor = assert(security.new_actor(actor_id, {workspace_id = workspace}))
    return funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
        assert(security.policy("bee.tests.threads.sessions:interactive_lifecycle_policy"))}))
end

local function reply_of(executor: funcs.Executor, method: string, request: Object): Object
    local raw, err = executor:call("bee.threads.sessions.binding:" .. method, request)
    if err then error(tostring(err)) end
    return assert(bounds.object(raw))
end

local function value_of(reply: Object): Object
    if reply.ok ~= true then error(tostring((bounds.object(reply.error) or {}).message)) end
    return assert(bounds.object(reply.value))
end

local function code_of(reply: Object): string
    test.is_false(reply.ok)
    return tostring((assert(bounds.object(reply.error))).code)
end

local function snapshot(owner: funcs.Executor, session: string): Object
    local got = value_of(reply_of(owner, "get", {session = session}))
    return assert(bounds.object(got.value))
end

local function opened(journal: harness.Client, prompt: string?): string
    local created = harness.value(journal:call("session_create", {operation_key = harness.key(), title = "Claude Code", route = {}}))
    local session = assert(bounds.id(created.session))
    if prompt then harness.value(journal:call("work_send", {session = session, input = prompt, operation_key = harness.key()})) end
    return session
end

local function define_tests()
    test.describe("Session rename", function()
        test.it("shows the explicit name as the title in get and list", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = opened(journal, "check bee status\nand more")
            local owner = caller("sessions-owner", WORKSPACE)
            test.eq(snapshot(owner, session).title, "Claude Code · check bee status")
            local renamed = value_of(reply_of(owner, "rename", {session = session, name = "  Release checks  ", operation_key = harness.key()}))
            test.eq(renamed.session, session)
            test.eq(renamed.title, "Release checks")
            test.eq(renamed.name, "Release checks")
            local shown = snapshot(owner, session)
            test.eq(shown.title, "Release checks")
            test.eq(shown.name, "Release checks")
            local page = value_of(reply_of(owner, "list", {filter = {workspace = WORKSPACE}}))
            local listed: Object? = nil
            for _, raw in ipairs(assert(bounds.array(page.items, 4096))) do
                local row = assert(bounds.object(raw))
                if row.session == session then listed = row end
            end
            test.eq((assert(listed)).title, "Release checks")
        end)
        test.it("keeps the explicit name when the first prompt arrives after it", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = opened(journal, nil)
            local owner = caller("sessions-owner", WORKSPACE)
            value_of(reply_of(owner, "rename", {session = session, name = "Named first", operation_key = harness.key()}))
            harness.value(journal:call("work_send", {session = session, input = "first prompt", operation_key = harness.key()}))
            test.eq(snapshot(owner, session).title, "Named first")
        end)
        test.it("keeps the name in the journal, so a fresh read after a restart shows it", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = opened(journal, "automatic")
            local owner = caller("sessions-owner", WORKSPACE)
            value_of(reply_of(owner, "rename", {session = session, name = "Durable", operation_key = harness.key()}))
            local db = harness.open()
            local rows = harness.query(db, "SELECT name FROM bee_sessions WHERE session_ref = ?", {session})
            db:release()
            test.eq(rows[1].name, "Durable")
            local described = harness.value(harness.session_owner(WORKSPACE):call("session_describe", {session = session}))
            test.eq(described.title, "Durable")
            test.eq(described.name, "Durable")
        end)
        test.it("returns to the automatic title when the name is cleared", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = opened(journal, "check bee status")
            local owner = caller("sessions-owner", WORKSPACE)
            value_of(reply_of(owner, "rename", {session = session, name = "Temporary", operation_key = harness.key()}))
            local cleared = value_of(reply_of(owner, "rename", {session = session, name = "", operation_key = harness.key()}))
            test.eq(cleared.title, "Claude Code · check bee status")
            test.is_nil(cleared.name)
            local shown = snapshot(owner, session)
            test.eq(shown.title, "Claude Code · check bee status")
            test.is_nil(shown.name)
        end)
        test.it("answers a repeated rename under the same key with the first receipt", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = opened(journal, nil)
            local owner = caller("sessions-owner", WORKSPACE)
            local key = harness.key()
            local first = value_of(reply_of(owner, "rename", {session = session, name = "Once", operation_key = key}))
            local second = value_of(reply_of(owner, "rename", {session = session, name = "Once", operation_key = key}))
            test.eq(second.operation, first.operation)
            test.eq(code_of(reply_of(owner, "rename", {session = session, name = "Changed", operation_key = key})), "CONFLICT")
        end)
        test.it("refuses a name with control characters or over the limit, and a caller outside the workspace", function()
            local journal = harness.session_owner(WORKSPACE)
            local session = opened(journal, nil)
            local owner = caller("sessions-owner", WORKSPACE)
            test.eq(code_of(reply_of(owner, "rename", {session = session, name = "two\nlines", operation_key = harness.key()})), "INVALID")
            test.eq(code_of(reply_of(owner, "rename", {session = session, name = string.rep("x", 129), operation_key = harness.key()})), "INVALID")
            test.eq(code_of(reply_of(caller("intruder", OTHER_WORKSPACE), "rename", {session = session, name = "Mine", operation_key = harness.key()})), "DENIED")
            test.eq(snapshot(owner, session).title, "Claude Code")
        end)
    end)
end
return test.run_cases(define_tests)
