-- MIT. A thread a workspace owns carries that workspace: the creator's
-- host-issued identity names it, never the request, and a workspace's
-- threads are one index range. Threads from before the attribution are
-- attributed from their application owner.
local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local security = require("security")
local harness = require("harness")
local database = require("database")
local reader = require("reader")

type Reply = harness.Reply
type Object = {[string]: unknown}

local LEFT, RIGHT = string.rep("1", 32), string.rep("2", 32)

local function scope(grants: {string}): security.Scope
    local policies: {security.Policy} = {assert(security.policy("bee.threads:client_test_policy"))}
    for _, name in ipairs(grants) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end

-- A principal bound to a workspace the way the broker binds an application
-- and the gateway binds a subject: through actor metadata.
local function bound(id: string, workspace_id: string?, grants: {string}): funcs.Executor
    local meta: {[string]: string} = {}
    if workspace_id then meta.workspace_id = workspace_id end
    return funcs.new():with_actor(security.new_actor(id, meta)):with_scope(scope(grants))
end

local function call(client: funcs.Executor, operation: string, request: Object): Reply
    local result, err = client:call("bee.threads.service:" .. operation, request)
    if err then error(operation .. ": " .. tostring(err)) end
    return result :: Reply
end

local function create(client: funcs.Executor, title: string, extra: Object?): (string, Reply)
    local thread_id = "thread-" .. harness.key()
    local request: Object = {thread_id = thread_id, idempotency_key = harness.key(), title = title}
    for key, value in pairs(extra or {}) do request[key] = value end
    return thread_id, call(client, "create", request)
end

local function listed(client: funcs.Executor, workspace_id: string, limit: integer): {string}
    local ids: {string} = {}
    local after: string? = nil
    for _ = 1, 100 do
        local request: Object = {workspace_id = workspace_id, limit = limit}
        if after then request.after_thread_id = after end
        local value = harness.value(call(client, "list_workspace", request)) :: Object
        for _, summary in ipairs(value.threads :: {Object}) do
            test.eq(summary.workspace_id, workspace_id)
            ids[#ids + 1] = tostring(summary.thread_id)
        end
        after = value.next_after_thread_id :: string?
        if not after then return ids end
    end
    error("paging did not end")
end

local function define_tests()
    test.describe("Thread workspace attribution", function()
        test.it("attributes a thread to the workspace its creator is bound to", function()
            local app = bound("bee.application:" .. LEFT .. ":instance-1", LEFT, {"bee.security.threads:thread_create_policy"})
            local thread_id, created = create(app, "Left work")
            test.eq((harness.value(created) :: Object).workspace_id, LEFT)
            local read = harness.value(call(app, "get", {thread_id = thread_id})) :: Object
            test.eq((read.summary :: Object).workspace_id, LEFT)
            local node = bound("bee.test.node_actor", nil, {"bee.security.threads:thread_create_policy"})
            local _, node_created = create(node, "Node work")
            test.is_nil((harness.value(node_created) :: Object).workspace_id)
        end)

        test.it("never takes the workspace from the request", function()
            local app = bound("bee.application:" .. LEFT .. ":instance-2", LEFT, {"bee.security.threads:thread_create_policy"})
            local _, smuggled = create(app, "Smuggled", {workspace_id = RIGHT})
            test.eq(harness.code(smuggled), "INVALID_ARGUMENT")
        end)

        test.it("lists one workspace's threads in pages, for a caller the host allows", function()
            local left = bound("bee.application:" .. LEFT .. ":instance-3", LEFT, {"bee.security.threads:thread_create_policy"})
            local right = bound("bee.application:" .. RIGHT .. ":instance-1", RIGHT, {"bee.security.threads:thread_create_policy"})
            local created: {[string]: boolean} = {}
            for index = 1, 5 do created[(create(left, "Left " .. tostring(index)))] = true end
            local right_thread = create(right, "Right")
            local viewer = bound("bee.test.workspace_viewer", nil, {"bee.security.threads:thread_workspace_list_policy"})
            local ids = listed(viewer, LEFT, 2)
            local found = 0
            for index, id in ipairs(ids) do
                if created[id] then found = found + 1 end
                test.is_true(id ~= right_thread)
                if index > 1 then test.is_true(ids[index - 1] < id) end
            end
            test.eq(found, 5)
            local right_ids = listed(viewer, RIGHT, 10)
            test.eq(right_ids[#right_ids], right_thread)
            test.eq(harness.code(call(left, "list_workspace", {workspace_id = LEFT})), "DENIED")
            test.eq(harness.code(call(viewer, "list_workspace", {workspace_id = "left"})), "INVALID_ARGUMENT")
        end)

        test.it("reads a workspace's threads through its index", function()
            local db = harness.open(nil)
            local plan = harness.query(db, "EXPLAIN QUERY PLAN " .. reader.WORKSPACE_HEADS, {LEFT, "", 10})
            db:release()
            local details: {string} = {}
            for _, row in ipairs(plan) do details[#details + 1] = tostring(row.detail) end
            local text = table.concat(details, " | ")
            if not text:find("USING INDEX bee_thread_heads_workspace", 1, true) or text:find("TEMP B-TREE", 1, true) then
                error("unindexed workspace listing: " .. text)
            end
        end)

        test.it("attributes existing threads from their application owner when the store upgrades", function()
            local resource = "bee.threads:workspace_test_db"
            local before, open_error = database.open_at(resource, 9)
            if not before then error(tostring(open_error)) end
            for _, row in ipairs({
                {"owned", "bee.application:" .. LEFT .. ":instance-9"},
                {"node", "bee.test.node_actor"},
                {"malformed", "bee.application:not-a-workspace:instance"},
                {"truncated", "bee.application:" .. LEFT},
            }) do
                harness.execute(before, "INSERT INTO bee_thread_heads (thread_id, owner_actor, title, state, revision, head_sequence, created_at) " ..
                    "VALUES (?, ?, ?, 'open', 1, 0, '2026-09-24T00:00:00.000Z')", {row[1], row[2], row[1]})
            end
            before:release()
            local after, upgrade_error = database.open(resource)
            if not after then error(tostring(upgrade_error)) end
            local rows = harness.query(after, "SELECT thread_id, workspace_id FROM bee_thread_heads ORDER BY thread_id")
            after:release()
            local attributed: {[string]: unknown} = {}
            for _, row in ipairs(rows) do attributed[tostring(row.thread_id)] = row.workspace_id end
            test.eq(attributed.owned, LEFT)
            test.is_nil(attributed.node)
            test.is_nil(attributed.malformed)
            test.is_nil(attributed.truncated)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
