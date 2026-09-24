-- MIT. The desktop bridge's catalog: one page of the node workspace catalog
-- with the node's displays, identical listings answered by one read, an
-- exclusive allocation, and deadlines that never claim an unknown outcome.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local registry = require("registry")
local catalog = require("catalog")
local protocol = require("protocol")
local types = require("types")
type Channel = channel.Channel
type Object = {[string]: unknown}
local EXECUTION = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
local PROJECTS = "bee.workspace.catalog:projects_fixture"

local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs(names) do policies[#policies + 1] = assert(security.policy(name)) end
    return security.new_scope(policies)
end
-- The executor the bridge reads the catalog with, and a catalog manager that
-- creates the rows it reads.
local bridge = funcs.new():with_actor(security.new_actor("bee.hive.supervisor")):with_scope(scope({"bee:desktop_catalog_policy",
    "bee:desktop_catalog_resource_policy", "bee:workspace_catalog_read_policy", "bee.hive.desktop:catalog_call_policy"}))
local manager = funcs.new():with_actor(security.new_actor("bee.test.desktop_catalog_manager")):with_scope(scope({
    "bee.workspace.catalog:call_test_policy", "bee:workspace_catalog_read_policy", "bee:workspace_catalog_manage_policy"}))

-- The host admits the projects fixture root for catalog rows.
local function admit()
    local entry = registry.get("bee:resource_roots")
    if not entry then error("admitted roots entry") end
    local data = entry.data :: Object
    local roots = data.roots :: {Object}
    for _, root in ipairs(roots) do
        if root.root_ref == PROJECTS then return end
    end
    roots[#roots + 1] = {root_ref = PROJECTS, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit roots: " .. tostring(err)) end
end
local function create(label: string, subpath: string): string
    admit()
    local reply, err = manager:call("bee.workspace.catalog:create", {label = label, root_ref = PROJECTS, subpath = subpath, create_directory = true})
    if err or type(reply) ~= "table" or reply.ok ~= true then
        local failure = type(reply) == "table" and (reply :: Object).error or err
        error("create " .. label .. ": " .. tostring(type(failure) == "table" and (failure :: Object).message or failure))
    end
    local value = (reply :: Object).value :: Object
    return tostring(value.workspace_id)
end
local function call(id: string, operation: string): types.Call
    local value = types.decode_call({protocol_revision = types.REVISION, request_id = id, idempotency_key = id,
        owner_ref = {node_id = "fixture", service_id = protocol.SERVICE}, target = {operation_ref = operation}, input = {}})
    if not value then error("invalid test request") end
    return value
end
local function listen(): Channel<process.Message>
    local replies, err = process.listen(types.TOPIC_REPLY, {message = true})
    if not replies then error(tostring(err)) end
    return replies
end
local function receive(replies: Channel<process.Message>): types.Reply
    local selected = channel.select({replies:case_receive(), time.after("5s"):case_receive()})
    if not selected.ok or selected.channel ~= replies then error("missing catalog response") end
    local reply = types.decode_reply(selected.value:payload():data())
    if not reply then error("invalid catalog response") end
    return reply
end
local function listing(served: {[string]: boolean}, default_workspace: string?): catalog.Listing
    return {execution = EXECUTION, default_workspace = default_workspace,
        served = function(workspace_id: string): boolean return served[workspace_id] == true end}
end
local function display_id(): string
    local id = uuid.v4():gsub("-", "")
    return id
end
-- Complete the pending operation as the bridge's loop does.
local function drain(state: catalog.State, view: catalog.Listing, now: integer)
    while state.pending do
        local cases = {}
        for _, response in ipairs(catalog.channels(state)) do cases[#cases + 1] = response:case_receive() end
        local deadline = time.after("10s")
        cases[#cases + 1] = deadline:case_receive()
        local selected = channel.select(cases)
        if selected.channel == deadline then error("catalog work did not complete") end
        test.is_true(catalog.handles(state, selected.channel))
        catalog.result(state, selected.channel, view, now)
    end
end
local function define_tests()
    test.describe("Desktop bridge catalog", function()
        test.it("pages the node's workspaces by label with the node's displays", function()
            local replies = listen()
            local self = tostring(process.pid())
            local prefix = "deskcat-" .. display_id():sub(1, 12)
            local first = create(prefix .. " a", prefix .. "-a")
            local second = create(prefix .. " b", prefix .. "-b")
            local third = create(prefix .. " c", prefix .. "-c")
            local state = catalog.new()
            local view = listing({[second] = true}, first)
            catalog.list(state, bridge, self, call("page-1", protocol.LIST), {label = prefix, after = nil, limit = 2}, 100)
            drain(state, view, 1)
            local page = receive(replies)
            if not page.ok then error(tostring(page.error and page.error.message)) end
            local value = page.value :: Object
            test.eq(value.owner_execution, EXECUTION)
            test.eq(value.default_workspace, first)
            local desktops = value.desktops :: {Object}
            test.is_true(#desktops >= 1)
            test.eq(desktops[1].is_default, true)
            local rows = value.workspaces :: {Object}
            test.eq(#rows, 2)
            test.eq(rows[1].workspace_id, first)
            test.eq(rows[1].label, prefix .. " a")
            test.eq(rows[1].served, false)
            test.eq(rows[2].workspace_id, second)
            test.eq(rows[2].served, true)
            local cursor = value.next_after
            if type(cursor) ~= "string" then error("the first page has no cursor") end
            catalog.list(state, bridge, self, call("page-2", protocol.LIST), {label = prefix, after = cursor, limit = 2}, 100)
            drain(state, view, 1)
            local last = receive(replies)
            local rest = (last.value :: Object).workspaces :: {Object}
            test.eq(#rest, 1)
            test.eq(rest[1].workspace_id, third)
            test.is_nil((last.value :: Object).next_after)
            process.unlisten(replies)
        end)
        test.it("answers identical listings from one read and keeps allocation exclusive", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            local view = listing({}, nil)
            catalog.list(state, bridge, self, call("first-list", protocol.LIST), {label = nil, after = nil, limit = 5}, 100)
            catalog.list(state, bridge, self, call("second-list", protocol.LIST), {label = nil, after = nil, limit = 5}, 100)
            catalog.list(state, bridge, self, call("other-page", protocol.LIST), {label = "other", after = nil, limit = 5}, 100)
            local other = receive(replies)
            test.eq(other.request_id, "other-page")
            test.eq(other.error and other.error.code, "BUSY")
            local desktop = display_id()
            catalog.allocate(state, bridge, self, call(desktop, protocol.CREATE), desktop, 100)
            local exclusive = receive(replies)
            test.eq(exclusive.error and exclusive.error.code, "BUSY")
            drain(state, view, 1)
            local answered: {[string]: boolean} = {}
            for _ = 1, 2 do
                local reply = receive(replies)
                test.is_true(reply.ok)
                answered[reply.request_id] = true
            end
            test.is_true(answered["first-list"] == true)
            test.is_true(answered["second-list"] == true)
            process.unlisten(replies)
        end)
        test.it("allocates one node display under its own identity", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            local desktop = display_id()
            catalog.allocate(state, bridge, self, call(desktop, protocol.CREATE), desktop, 100)
            drain(state, listing({}, nil), 1)
            local reply = receive(replies)
            if not reply.ok then error(tostring(reply.error and reply.error.message)) end
            local value = reply.value :: Object
            test.eq(value.owner_execution, EXECUTION)
            test.eq(value.desktop_id, desktop)
            test.is_nil(value.workspace_id)
            process.unlisten(replies)
        end)
        test.it("reports an allocation past its deadline as uncertain and a late listing as unavailable", function()
            local replies = listen()
            local self = tostring(process.pid())
            local state = catalog.new()
            local desktop = display_id()
            catalog.allocate(state, bridge, self, call(desktop, protocol.CREATE), desktop, 10)
            catalog.tick(state, 10)
            local expired = receive(replies)
            test.eq(expired.error and expired.error.code, "UNCERTAIN")
            test.is_nil(state.pending)
            test.eq(#catalog.channels(state), 0)
            catalog.list(state, bridge, self, call("late", protocol.LIST), {label = nil, after = nil, limit = 1}, 10)
            catalog.tick(state, 10)
            local late = receive(replies)
            test.eq(late.error and late.error.code, "UNAVAILABLE")
            process.unlisten(replies)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
