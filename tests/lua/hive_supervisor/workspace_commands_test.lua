-- MIT. The bee workspace commands: an enrolled local client names one of the
-- workspace operations of its own node, and the supervisor's worker runs the
-- catalog operation under the policies the host attached to that worker, not
-- the client's or the supervisor's own. Catalog answers become Hive replies.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local types = require("types")
local commands = require("commands")
type Object = {[string]: unknown}
local PROJECTS = "bee.workspace.catalog:projects_fixture"
local NODE = "owner-node"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end
-- The supervisor holds only the call to the worker; the worker holds the catalog grants.
local supervisor = funcs.new():with_actor(security.new_actor("bee.hive.supervisor")):with_scope(scope({"bee.security.hive:workspace_command_policy"}))

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

local function call(operation: string, input: Object?, target: types.Target?, owner: types.OwnerRef?): types.Call
    return {protocol_revision = types.REVISION, request_id = "request-1", idempotency_key = "key-1",
        owner_ref = owner or {node_id = NODE, service_id = commands.SERVICE}, target = target or {operation_ref = operation}, input = input or {}}
end

local function run(operation: string, input: unknown): types.Reply
    local value, err = supervisor:call(commands.WORKER, {request_id = "exchange-1", operation = operation, idempotency_key = "key-1", input = input})
    if err then error(operation .. ": " .. tostring(err)) end
    local reply = types.decode_reply(value)
    if not reply then error(operation .. ": invalid reply") end
    return reply
end

local function define_tests()
    test.describe("Workspace commands", function()
        test.it("accepts the workspace operations of its own node only", function()
            local operation = commands.target(call("bee.workspace:create"), NODE)
            test.eq(operation, "bee.workspace:create")
            for _, name in ipairs({"bee.workspace:list", "bee.workspace:archive", "bee.workspace:restore", "bee.workspace:roots"}) do
                test.eq(commands.target(call(name), NODE), name)
            end
            local _, other = commands.target(call("bee.workspace:list", nil, nil, {node_id = "elsewhere", service_id = commands.SERVICE}), NODE)
            test.eq(other and other.code, "DENIED")
            local _, resource = commands.target(call("bee.workspace:list", nil, nil,
                {node_id = NODE, service_id = commands.SERVICE, resource_ref = "x"}), NODE)
            test.eq(resource and resource.code, "DENIED")
            local _, unknown = commands.target(call("bee.workspace:rename"), NODE)
            test.eq(unknown and unknown.code, "INVALID_ARGUMENT")
            local _, by_interface = commands.target(call("", nil, {interface_ref = "bee.workspace:list"}), NODE)
            test.eq(by_interface and by_interface.code, "INVALID_ARGUMENT")
        end)

        test.it("turns catalog answers into Hive replies with the catalog's reason", function()
            local identity: types.FaultIdentity = {operation_ref = "bee.workspace:create", idempotency_key = "key-1"}
            local done = commands.reply("r", identity, {ok = true, value = {workspace_id = "x"}})
            test.is_true(done.ok)
            test.eq((done.value :: Object).workspace_id, "x")
            local cases: {{string}} = {{"INVALID", "INVALID_ARGUMENT"}, {"UNAUTHENTICATED", "DENIED"}, {"DENIED", "DENIED"},
                {"FORBIDDEN", "DENIED"}, {"NOT_FOUND", "NOT_FOUND"}, {"CONFLICT", "CONFLICT"}, {"BUSY", "INVALID_STATE"},
                {"STORAGE", "INTERNAL"}, {"UNAVAILABLE", "UNAVAILABLE"}, {"ELSEWHERE", "INTERNAL"}}
            for _, pair in ipairs(cases) do
                local refused = commands.reply("r", identity, {ok = false, error = {code = pair[1], message = "why"}})
                test.is_false(refused.ok)
                test.eq(refused.error and refused.error.code, pair[2])
                test.eq(refused.error and refused.error.message, pair[1] .. ": why")
            end
            local unknown = commands.reply("r", identity, {ok = false, error = {code = "UNCERTAIN", message = "lost"}})
            test.eq(unknown.error and unknown.error.code, "UNCERTAIN")
            test.eq(unknown.error and unknown.error.identity and unknown.error.identity.idempotency_key, "key-1")
            test.eq(commands.reply("r", identity, "junk").error and commands.reply("r", identity, "junk").error.code, "INTERNAL")
        end)

        test.it("runs the catalog operations under the worker's host policies", function()
            admit()
            local roots = run("bee.workspace:roots", {})
            test.is_true(roots.ok)
            local found = false
            for _, root in ipairs((roots.value :: Object).roots :: {Object}) do
                if root.root_ref == PROJECTS then found = root.access == "write" end
            end
            test.is_true(found)
            local name = "command-" .. tostring(math.floor(time.now():unix_nano() / 1000))
            local created = run("bee.workspace:create", {label = "Command " .. name, root_ref = PROJECTS, subpath = name, create_directory = true})
            test.is_true(created.ok)
            test.eq(created.request_id, "exchange-1")
            local id = tostring((created.value :: Object).workspace_id)
            test.eq(#id, 32)
            test.eq(run("bee.workspace:create", {label = "Again", root_ref = PROJECTS, subpath = name}).error.code, "CONFLICT")
            local archived = run("bee.workspace:archive", {workspace_id = id})
            test.eq((archived.value :: Object).state, "archived")
            local listed = run("bee.workspace:list", {state = "archived", limit = 100})
            test.is_true(listed.ok)
            test.eq((run("bee.workspace:restore", {workspace_id = id}).value :: Object).state, "active")
            test.eq(run("bee.workspace:create", {label = "", root_ref = PROJECTS}).error.code, "INVALID_ARGUMENT")
            test.eq(run("bee.workspace:rename", {workspace_id = id, label = "No"}).error.code, "INVALID_ARGUMENT")
        end)

        test.it("refuses a caller without the host's worker grant", function()
            local outsider = funcs.new():with_actor(security.new_actor("bee.test.outsider")):with_scope(scope({}))
            local value, err = outsider:call(commands.WORKER, {request_id = "exchange-1", operation = "bee.workspace:roots", idempotency_key = "k", input = {}})
            if err then return end
            local reply = types.decode_reply(value)
            test.eq(reply and reply.error and reply.error.code, "DENIED")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
