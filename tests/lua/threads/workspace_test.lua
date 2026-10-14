-- MIT. A thread a workspace owns carries that workspace: the creator's
-- host-issued identity names it, never the request, and a workspace's
-- threads are one index range.
local test = require("test")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local harness = require("harness")
local reader = require("reader")

type Reply = harness.Reply
type Object = {[string]: unknown}

local LEFT, RIGHT = "0199c4a0-0000-7000-8000-000000000001", "0199c4a0-0000-7000-8000-000000000002"

local function scope(grants: {string}): security.Scope
    local policies: {security.Policy} = {assert(security.policy("bee.tests.threads:client_policy"))}
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
    local result, err = client:call("bee.threads.binding:" .. operation, request)
    if err then error(operation .. ": " .. tostring(err)) end
    return harness.decode_reply(result)
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
        local value = assert(bounds.object(harness.value(call(client, "list_workspace", request))))
        for _, summary in ipairs(harness.objects(value.threads, limit)) do
            test.eq(summary.workspace_id, workspace_id)
            ids[#ids + 1] = tostring(summary.thread_id)
        end
        local next_after = value.next_after_thread_id
        if next_after ~= nil and type(next_after) ~= "string" then error("invalid thread page cursor") end
        after = next_after
        if not after then return ids end
    end
    error("paging did not end")
end

local function define_tests()
    test.describe("Thread workspace attribution", function()
        test.it("attributes a thread to the workspace its creator is bound to", function()
            local app = bound("bee.application:" .. LEFT .. ":instance-1", LEFT, {"bee.threads.security:create"})
            local thread_id, created = create(app, "Left work")
            test.eq((assert(bounds.object(harness.value(created)))).workspace_id, LEFT)
            local read = assert(bounds.object(harness.value(call(app, "get", {thread_id = thread_id}))))
            test.eq((assert(bounds.object(read.summary))).workspace_id, LEFT)
            local node = bound("bee.test.node_actor", nil, {"bee.threads.security:create"})
            local _, node_created = create(node, "Node work")
            test.is_nil((assert(bounds.object(harness.value(node_created)))).workspace_id)
        end)

        test.it("never takes the workspace from the request", function()
            local app = bound("bee.application:" .. LEFT .. ":instance-2", LEFT, {"bee.threads.security:create"})
            local _, smuggled = create(app, "Smuggled", {workspace_id = RIGHT})
            test.eq(harness.code(smuggled), "INVALID_ARGUMENT")
        end)

        test.it("lists one workspace's threads in pages, for a caller the host allows", function()
            local left = bound("bee.application:" .. LEFT .. ":instance-3", LEFT, {"bee.threads.security:create"})
            local right = bound("bee.application:" .. RIGHT .. ":instance-1", RIGHT, {"bee.threads.security:create"})
            local created: {[string]: boolean} = {}
            for index = 1, 5 do created[(create(left, "Left " .. tostring(index)))] = true end
            local right_thread = create(right, "Right")
            local viewer = bound("bee.test.workspace_viewer", nil, {"bee.threads.security:workspace_list"})
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
            test.eq(harness.code(call(viewer, "list_workspace", {workspace_id = ""})), "INVALID_ARGUMENT")
        end)

        test.it("reads a workspace's threads through its index", function()
            local db = harness.open()
            local plan = harness.query(db, "EXPLAIN QUERY PLAN " .. reader.WORKSPACE_HEADS, {LEFT, "", 10})
            db:release()
            local details: {string} = {}
            for _, row in ipairs(plan) do details[#details + 1] = tostring(row.detail) end
            local text = table.concat(details, " | ")
            if not text:find("USING INDEX bee_thread_heads_workspace", 1, true) or text:find("TEMP B-TREE", 1, true) then
                error("unindexed workspace listing: " .. text)
            end
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
