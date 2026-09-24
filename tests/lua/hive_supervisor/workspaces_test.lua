-- MIT. The node's workspace catalog is an open Hive operation: any member
-- pages and searches every workspace a node holds and sees which a host
-- serves now, through the same dispatch as node telemetry.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local uuid = require("uuid")
local types = require("types")
local store = require("store")
local binding = require("binding")
type Object = {[string]: unknown}
local PROJECTS = "bee.workspace.catalog:projects_fixture"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end
local manager = funcs.new():with_actor(security.new_actor("bee.test.hive_workspaces_manager")):with_scope(scope({
    "bee.workspace.catalog:call_test_policy", "bee:workspace_catalog_read_policy", "bee:workspace_catalog_manage_policy"}))
-- The supervisor dispatches as itself under the host's Hive policies.
local supervisor = funcs.new():with_actor(security.new_actor("bee.hive.supervisor")):with_scope(scope({
    "bee:hive_catalog_policy", "bee:hive_exposure_policy", "bee:hive_dispatch_policy"}))

local function admit()
    local entry = registry.get("bee:resource_roots")
    if not entry then error("admitted roots entry") end
    local roots = (entry.data :: Object).roots :: {Object}
    for _, root in ipairs(roots) do if root.root_ref == PROJECTS then return end end
    roots[#roots + 1] = {root_ref = PROJECTS, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    assert(changes:apply())
end
local function create(label: string, subpath: string): string
    admit()
    local reply, err = manager:call("bee.workspace.catalog:create", {label = label, root_ref = PROJECTS, subpath = subpath, create_directory = true})
    if err or type(reply) ~= "table" or reply.ok ~= true then error("create " .. label .. ": " .. tostring(err)) end
    return tostring(((reply :: Object).value :: Object).workspace_id)
end
local function request(input: Object): types.Request
    local digest = assert(types.digest(input))
    local decoded, err = types.decode_request({protocol_revision = types.REVISION, request_id = "req-" .. uuid.v7(), idempotency_key = "idem",
        caller_node_id = "laptop", caller_incarnation = "inc-1", owner_ref = {node_id = "forge", service_id = "bee.hive.host"},
        operation_ref = "bee.hive.host:workspaces", operation_revision = "1", input = input, input_digest = digest,
        principal_ref = {issuer = "node:laptop", subject_id = "user-1"},
        principal_assertion = {method = types.ASSERTION_METHOD, audience = "forge", issued_at = "2026-09-08T10:00:00.000Z", expires_at = "2026-09-08T10:05:00.000Z"},
        delegation_refs = {}, deadline = "2026-09-08T10:05:00.000Z"})
    if not decoded then error("invalid request: " .. tostring(err)) end
    return decoded
end
local function dispatch(input: Object): types.Reply
    local result, err = supervisor:call("bee.hive.supervisor:dispatch_probe", request(input))
    if err then error(tostring(err)) end
    local reply = types.decode_reply(result)
    if not reply then error("invalid reply envelope") end
    return reply
end
local function define_tests()
    test.describe("Hive node workspaces", function()
        test.it("pages and searches every workspace a node holds", function()
            local prefix = "hivews-" .. uuid.v7():sub(-12)
            local first = create(prefix .. " a", prefix .. "-a")
            local second = create(prefix .. " b", prefix .. "-b")
            local third = create(prefix .. " c", prefix .. "-c")
            local page = dispatch({label = prefix, limit = 2})
            if not page.ok then error(tostring(page.error and page.error.message)) end
            local value = page.value :: Object
            local rows = value.workspaces :: {Object}
            test.eq(#rows, 2)
            test.eq(rows[1].workspace_id, first)
            test.eq(rows[1].label, prefix .. " a")
            test.eq(rows[1].served, false)
            test.eq(rows[2].workspace_id, second)
            test.is_true(type(value.node_id) == "string")
            local cursor = value.next_after
            if type(cursor) ~= "string" then error("the first page has no cursor") end
            local rest = dispatch({label = prefix, after = cursor, limit = 2})
            local last = (rest.value :: Object).workspaces :: {Object}
            test.eq(#last, 1)
            test.eq(last[1].workspace_id, third)
            test.is_nil((rest.value :: Object).next_after)
        end)
        test.it("lists the folder workspace's unnamed catalog row", function()
            -- The classic launch path creates the folder's row when it opens it.
            local folder = assert(store.open(nil, binding.classic()))
            assert(folder:close())
            local unnamed = 0
            local after: string? = nil
            repeat
                local input: Object = {limit = 50}
                if after then input.after = after end
                local page = dispatch(input)
                if not page.ok then error(tostring(page.error and page.error.message)) end
                local value = page.value :: Object
                for _, row in ipairs(value.workspaces :: {Object}) do
                    if row.label == "" then unnamed = unnamed + 1 end
                end
                local cursor = value.next_after
                after = type(cursor) == "string" and cursor or nil
            until not after
            test.eq(unnamed, 1)
        end)
        test.it("refuses input outside the declared schema", function()
            local refused = dispatch({limit = 51})
            test.is_false(refused.ok)
            test.eq(refused.error and refused.error.code, "INVALID_ARGUMENT")
            local extra = dispatch({owner = "me"})
            test.is_false(extra.ok)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
