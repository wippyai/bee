-- MIT. Exercise the public facade with actual actor scopes and committed SQLite state.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local bounds = require("bounds")
local WORKSPACE = "saved-profile-workspace"
local function caller(id: string, grant: string?): funcs.Executor
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.harness.profiles:test_call", grant or "bee.harness.profiles:test_call"}) do
        local policy, err = security.policy(name)
        if not policy then error(tostring(err)) end
        policies[#policies + 1] = policy
    end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(security.new_scope(policies))
end
local function call(client: funcs.Executor, request: unknown): {[string]: unknown}
    local raw, err = client:call("bee.harness.profiles:call", request)
    if err then error(tostring(err)) end
    local reply = bounds.object(raw)
    if not reply then error("malformed reply") end
    return reply
end
local function value(reply: {[string]: unknown}): {[string]: unknown}
    if reply.ok ~= true then error(tostring(reply.code) .. ": " .. tostring(reply.message)) end
    local result = bounds.object(reply.value)
    if not result then error("missing value") end
    return result
end
local function fresh(): string
    local id, err = uuid.v7()
    if not id then error(tostring(err)) end
    return id
end
local function put(id: string, revision: integer, key: string, title: string): {[string]: unknown}
    return {operation = "put", workspace_id = WORKSPACE, profile_id = id, expected_revision = revision, idempotency_key = key,
        profile = {title = title, definition_ref = "bee:codex"}}
end
local function define_tests()
    test.describe("Saved profile owner facade", function()
        test.it("denies ungranted and cross-workspace reads and writes", function()
            local outsider = caller("profile-outsider")
            local reader = caller("profile-reader", "bee.harness.profiles:test_read")
            test.eq(call(outsider, {operation = "list", workspace_id = WORKSPACE}).code, "DENIED")
            test.eq(call(reader, {operation = "list", workspace_id = "foreign"}).code, "DENIED")
            test.eq(call(reader, put(fresh(), 0, fresh(), "Denied")).code, "DENIED")
        end)
        test.it("shares committed preferences across authorized clients and fences edits", function()
            local writer = caller("profile-writer", "bee.harness.profiles:test_write")
            local reader = caller("profile-reader", "bee.harness.profiles:test_read")
            local id, key = fresh(), fresh()
            local request = put(id, 0, key, "Original")
            test.eq(value(call(writer, request)).revision, 1)
            local saved = value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = id}))
            test.eq(saved.revision, 1)
            local profile = bounds.object(saved.profile)
            if not profile then error("missing profile") end
            test.eq(profile.title, "Original")
            local replay = call(writer, request)
            test.eq(replay.replayed, true)
            test.eq(value(replay).revision, 1)
            test.eq(call(writer, put(id, 0, fresh(), "Stale")).code, "CONFLICT")
            test.eq(call(writer, put(id, 1, key, "Reused key")).code, "CONFLICT")
            test.eq(value(call(writer, put(id, 1, fresh(), "Updated"))).revision, 2)
            local remove = {operation = "remove", workspace_id = WORKSPACE, profile_id = id, expected_revision = 2, idempotency_key = fresh()}
            test.eq(value(call(writer, remove)).revision, 3)
            test.eq(call(writer, remove).replayed, true)
            local retired = value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = id}))
            test.eq(retired.tombstone, true)
            test.is_nil(retired.profile)
            local historical = call(writer, request)
            test.eq(historical.replayed, true)
            test.eq(value(historical).revision, 1)
            test.eq(value(call(reader, {operation = "get", workspace_id = WORKSPACE, profile_id = id})).tombstone, true)
        end)
        test.it("lists without an initial key and invalidates a changed continuation", function()
            local writer = caller("profile-page-writer", "bee.harness.profiles:test_write")
            local reader = caller("profile-page-reader", "bee.harness.profiles:test_read")
            value(call(writer, put(fresh(), 0, fresh(), "First")))
            value(call(writer, put(fresh(), 0, fresh(), "Second")))
            local page = value(call(reader, {operation = "list", workspace_id = WORKSPACE, limit = 1}))
            test.eq(page.complete, false)
            value(call(writer, put(fresh(), 0, fresh(), "Third")))
            local stale = call(reader, {operation = "list", workspace_id = WORKSPACE, limit = 1, after_key = page.next_key, expected_cursor = page.cursor})
            test.eq(stale.code, "RESET_REQUIRED")
            local reset = bounds.object(stale.value)
            if not reset then error("missing reset cursor") end
            test.eq(reset.workspace_id, WORKSPACE)
            test.is_nil(reset.owner_id)
        end)
    end)
end
return test.run_cases(define_tests)
