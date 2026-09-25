-- MIT. Bounded acceptance: two logical workspaces served by two hosts in one
-- runtime, against one node database. Each host serves exactly its selected
-- catalog row; neither can read or change the other's workspace state or
-- resources.
local logger = require("logger")
local process = require("process")
local channel = require("channel")
local security = require("security")
local funcs = require("funcs")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local store = require("store")
local catalog = require("catalog")
local decode = require("decode")
local recovery = require("recovery")

local NODE = "bee.workspace.db:node"
local ROOT = "bee.env:workspace_root"
type Object = {[string]: unknown}
type Channel = channel.Channel
type Hosts = {ready: Channel<process.Message>, replies: Channel<process.Message>,
    checkpoints: Channel<process.Message>, events: Channel<process.Event>, exits: {[string]: unknown},
    readiness: {[string]: Object}}

local function eq(actual: unknown, expected: unknown, what: string)
    if actual ~= expected then error(what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
end

local function host_scope(): security.Scope
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:host_spawn_policy", "bee.workspace.hosts:node_storage_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    return security.new_scope(policies)
end

local function spawn(hosts: Hosts, workspace_id: string): string
    local self = tostring(process.pid())
    local pid, err = process.with_options({}):with_context({["bee.host_owner"] = self}):with_scope(host_scope())
        :spawn_monitored("bee.host:main", "bee:workers", self, {workspace_id = workspace_id}, NODE)
    if not pid then error("spawn host: " .. tostring(err)) end
    return tostring(pid)
end

local function record_exit(hosts: Hosts, event: process.Event)
    if event.kind == process.event.EXIT then hosts.exits[tostring(event.from)] = event.result end
end

-- Readiness names the workspace the host serves and the snapshot it restored.
-- Hosts start concurrently, so readiness from any host is kept until awaited.
local function await_ready(hosts: Hosts, host: string): Object
    local deadline = time.after("10s")
    while hosts.readiness[host] == nil do
        if hosts.exits[host] ~= nil then error("host exited: " .. tostring(decode.exit_error(hosts.exits[host]))) end
        local selected = channel.select({hosts.ready:case_receive(), hosts.events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("host readiness timed out") end
        if selected.channel == hosts.events then record_exit(hosts, selected.value)
        else
            local data: unknown = selected.value:payload():data()
            if type(data) ~= "table" then error("invalid readiness") end
            hosts.readiness[tostring(selected.value:from())] = data :: Object
        end
    end
    local value = hosts.readiness[host]
    hosts.readiness[host] = nil
    if not value then error("readiness disappeared") end
    return value
end

local function await_reply(hosts: Hosts, host: string, request_id: string, op: string): decode.Reply
    local deadline = time.after("10s")
    while true do
        if hosts.exits[host] ~= nil then error("host exited: " .. tostring(decode.exit_error(hosts.exits[host]))) end
        local selected = channel.select({hosts.replies:case_receive(), hosts.events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("reply timed out: " .. op) end
        if selected.channel == hosts.events then record_exit(hosts, selected.value)
        elseif tostring(selected.value:from()) == host then
            local reply = decode.reply(selected.value:payload():data())
            if reply and reply.request_id == request_id and reply.op == op then return reply end
        end
    end
    error("reply channel closed")
end

local function await_checkpoint(hosts: Hosts, host: string, workspace_id: string): recovery.Record
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({hosts.checkpoints:case_receive(), hosts.events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("checkpoint timed out") end
        if selected.channel == hosts.events then record_exit(hosts, selected.value)
        elseif tostring(selected.value:from()) == host then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.workspace_id == workspace_id then
                local record = recovery.record(data.record)
                if record then return record end
            end
        end
    end
    error("checkpoint channel closed")
end

local function await_exit(hosts: Hosts, host: string): string?
    local deadline = time.after("10s")
    while hosts.exits[host] == nil do
        local selected = channel.select({hosts.events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("host did not exit") end
        record_exit(hosts, selected.value)
    end
    return decode.exit_error(hosts.exits[host])
end

local function request(host: string, value: Object)
    value.version = 1
    assert(process.send(host, "bee.app.request", value))
end

local function stop(hosts: Hosts, host: string, workspace_id: string)
    local id = "stop-" .. uuid.v7()
    request(host, {request_id = id, op = "shutdown", workspace_id = workspace_id})
    eq(await_reply(hosts, host, id, "shutdown").error_code, "", "shutdown reply")
    eq(await_exit(hosts, host), nil, "shutdown exit")
end

-- The workspace state row as the store serves it to that workspace alone.
local function saved_applications(workspace_id: string): integer
    local handle = assert(store.open(NODE, {workspace_id = workspace_id}))
    local encoded = handle:read()
    assert(handle:close())
    if not encoded then return 0 end
    local value: unknown = json.decode(encoded)
    if type(value) ~= "table" or type(value.applications) ~= "table" then error("corrupt workspace state") end
    return #(value.applications :: {unknown})
end

local function resources(actor: security.Actor, grants: {string}): funcs.Executor
    local policies: {security.Policy} = {assert(security.policy("bee.workspace.hosts:resource_call_policy"))}
    for _, name in ipairs(grants) do policies[#policies + 1] = assert(security.policy(name)) end
    return funcs.new():with_actor(actor):with_scope(security.new_scope(policies))
end

local function resource_call(client: funcs.Executor, method: string, value: Object): Object
    local reply, err = client:call("bee.resources.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    if type(reply) ~= "table" then error(method .. ": missing reply") end
    return reply :: Object
end

-- A catalog row in the node database, as the catalog owner operation inserts it.
local function created(label: string, subpath: string): string
    local db = assert(store.database(NODE))
    local tx = assert(db:begin())
    local row, failure = catalog.insert(tx, {label = label, root_ref = ROOT, subpath = subpath})
    if not row then
        tx:rollback(); db:release()
        error("create workspace: " .. tostring(failure and failure.message))
    end
    assert(tx:commit())
    db:release()
    return row.workspace_id
end

local function main()
    local suffix = uuid.v7()
    local left = created("left", "left-" .. suffix)
    local right = created("right", "right-" .. suffix)
    local hosts: Hosts = {ready = assert(process.listen("bee.host.ready", {message = true})),
        replies = assert(process.listen("bee.app.reply", {message = true})),
        checkpoints = assert(process.listen("bee.host.checkpoint", {message = true})),
        events = assert(process.events()), exits = {}, readiness = {}}

    local left_host, right_host = spawn(hosts, left), spawn(hosts, right)
    eq((await_ready(hosts, left_host)).workspace_id, left, "left host workspace")
    eq((await_ready(hosts, right_host)).workspace_id, right, "right host workspace")

    -- A workspace has one host: a second host for the same row is fenced.
    local duplicate = spawn(hosts, left)
    local fenced = tostring(await_exit(hosts, duplicate))
    if not fenced:find("Register workspace host", 1, true) then error("second host was not fenced: " .. fenced) end

    -- An application opened in the left workspace is checkpointed into the
    -- left row only.
    local open_id = "open-" .. uuid.v7()
    request(left_host, {request_id = open_id, op = "open", workspace_id = left,
        definition_id = "bee.settings:app", thread_id = "logical-" .. suffix})
    local opened = await_reply(hosts, left_host, open_id, "open")
    eq(opened.error_code, "", "open in the left workspace")
    eq((await_checkpoint(hosts, left_host, left)).instance_id, opened.instance_id, "left checkpoint instance")
    eq(saved_applications(left), 1, "left saved applications")
    eq(saved_applications(right), 0, "right saved applications")

    -- Each host refuses requests that name the other workspace.
    local cross = "cross-" .. uuid.v7()
    request(right_host, {request_id = cross, op = "close", workspace_id = left, id = opened.id})
    local refused = await_reply(hosts, right_host, cross, "close")
    eq(refused.error_code, "workspace_mismatch", "right host refusing a left close")
    eq(refused.workspace_id, right, "right host reply workspace")
    request(left_host, {request_id = cross, op = "open", workspace_id = right, definition_id = "bee.settings:app"})
    eq((await_reply(hosts, left_host, cross, "open")).error_code, "workspace_mismatch", "left host refusing a right open")
    eq(saved_applications(left), 1, "left saved applications after cross requests")
    eq(saved_applications(right), 0, "right saved applications after cross requests")

    -- Resources are per workspace: an application principal of the left
    -- workspace takes grants there and nowhere else.
    local manager = resources(assert(security.new_actor("workspace_hosts.logical_manager")), {"bee.security.resources:resource_manage_policy"})
    for _, workspace in ipairs({left, right}) do
        local associated = resource_call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = ROOT,
            subpath = "", allowed_access = "read"})
        eq(associated.ok, true, "associate the project resource")
    end
    local application = assert(security.new_actor("bee.application:" .. left .. ":" .. opened.instance_id, {workspace_id = left}))
    local app = resources(application, {"bee.security.resources:resource_grant_policy"})
    local audience = "workspace_hosts.logical_placement"
    local own = resource_call(app, "grant", {workspace_id = left, name = "project", access = "read", purpose = "project", audience = audience})
    eq(own.ok, true, "grant in the principal's own workspace")
    local foreign = resource_call(app, "grant", {workspace_id = right, name = "project", access = "read", purpose = "project", audience = audience})
    eq(foreign.ok, false, "grant in the other workspace")
    eq((foreign.error :: Object).code, "DENIED", "foreign grant refusal")

    -- Restarting both hosts restores each workspace from its own row.
    stop(hosts, left_host, left)
    stop(hosts, right_host, right)
    local left_again, right_again = spawn(hosts, left), spawn(hosts, right)
    local left_ready = await_ready(hosts, left_again)
    local right_ready = await_ready(hosts, right_again)
    eq(left_ready.workspace_id, left, "restarted left workspace")
    eq(right_ready.workspace_id, right, "restarted right workspace")
    eq(#(((left_ready.saved :: Object).applications) :: {unknown}), 1, "restored left applications")
    eq(#(((right_ready.saved :: Object).applications) :: {unknown}), 0, "restored right applications")
    stop(hosts, left_again, left)
    stop(hosts, right_again, right)
    for _, subscription in ipairs({hosts.ready, hosts.replies, hosts.checkpoints}) do process.unlisten(subscription) end
    logger:info("ACCEPTANCE VERIFIED: two logical workspaces served from one node database in one runtime")
end

return {main = main}
