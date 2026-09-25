-- MIT. A scripted fixture agent answers three questions it could not know
-- without the platform corpus, using only the read-only docs tool through the
-- real authenticated MCP gateway. It is the acceptance for the docs tool:
-- 1. the terminal toolkit: how an application draws (one-based cells),
-- 2. a cross-node application: how subscriptions and hive exposure work,
-- 3. a runtime module: the SQL builder the application declares.
-- Every answer is asserted against text the tool actually returned, so a
-- corpus that lost a page or a tool that widened its bounds fails here.
local funcs = require("funcs")
local http_client = require("http_client")
local json = require("json")
local time = require("time")
local process = require("process")
local io = require("io")
local bounds = require("bounds")
type Object = {[string]: unknown}
local ACTOR = "bee.test.docs_agent"
local THREAD = "docs-agent-thread"
local ADDRESS = ""
local function key(): string return "k-" .. tostring(time.now():unix_nano()) end
local function call(target: string, request: Object): Object
    local reply, err = funcs.call(target, request)
    assert(not err, target .. ": " .. tostring(err))
    assert((reply :: Object).ok == true, target .. ": " .. tostring(json.encode(reply)))
    return (reply :: Object).value :: Object
end
local function endpoint(): string
    local selected, err = funcs.call("bee.gateway:address", {})
    for _ = 1, 100 do
        if not err or not tostring(err):find("gateway listener is starting", 1, true) then break end
        time.sleep("20ms")
        selected, err = funcs.call("bee.gateway:address", {})
    end
    assert(not err and type(selected) == "table", "gateway endpoint: " .. tostring(err))
    local address = (selected :: Object).address
    assert(type(address) == "string" and (address :: string):find("^127%.0%.0%.1:%d+$"), "gateway endpoint address")
    return address :: string
end
-- Admit this subject for exactly the docs tool and materialize its token once,
-- the same admission and credential path every managed Agent uses.
local function binding(): (string, string)
    local admitted = call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "docs-agent", attempt_id = "docs-agent-attempt",
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"docs"}, ttl_ms = 60000})
    local binding_id = tostring((admitted.binding :: Object).binding_id)
    assert(admitted.token == nil, "admit must not return token bytes")
    local authorized = call("bee.gateway.binding:authorize_materialization", {attempt_id = "docs-agent-attempt", carrier_epoch = 1, binding_id = binding_id})
    local materialized = call("bee.gateway.binding:materialize", {attempt_id = "docs-agent-attempt", carrier_epoch = 1,
        materialization_key = authorized.materialization_key})
    return tostring(materialized.token), binding_id
end
local function rpc(token: string, method: string, params: Object?): (number, Object?)
    local body = json.encode({jsonrpc = "2.0", id = 1, method = method, params = params or {}})
    local response, err = http_client.post("http://" .. ADDRESS .. "/mcp/docs-agent", {headers = {Authorization = "Bearer " .. token,
        ["Content-Type"] = "application/json"}, body = body, timeout = "8s"})
    assert(response, "rpc " .. method .. ": " .. tostring(err))
    local decoded: unknown = json.decode(tostring(response.body))
    return response.status_code, type(decoded) == "table" and (decoded :: Object) or nil
end
local function tool(token: string, arguments: Object): Object
    local status, reply = rpc(token, "tools/call", {name = "docs", arguments = arguments})
    assert(status == 200 and reply and reply.result, "docs status " .. tostring(status))
    local result = reply.result :: Object
    local content = (result.content :: {Object})[1]
    local text: unknown = json.decode(tostring(content.text))
    assert(type(text) == "table", "docs returned no reply")
    return text :: Object
end
local function value(reply: Object, what: string): Object
    assert(reply.ok == true, what .. " failed: " .. tostring(reply.code) .. " " .. tostring(reply.message))
    return reply.value :: Object
end
local function find(haystack: string, needle: string): boolean
    return string.find(haystack, needle, 1, true) ~= nil
end
-- Question 1: how does a Bee application draw? Search the toolkit topic, then
-- read the reference the search pointed at and take the answer from its text.
local function terminal_toolkit(token: string): string
    -- A phrase only Bee's toolkit reference carries, so search must find it.
    local found = value(tool(token, {operation = "search", query = "one-based cells", topic = "terminal", limit = 8}), "search toolkit")
    local results = found.results :: {{[string]: unknown}}
    assert(#results >= 1, "the toolkit search returned nothing")
    local selected: Object? = nil
    for _, result in ipairs(results) do if tostring(result.id) == "toolkit" then selected = result end end
    assert(selected ~= nil, "the toolkit reference was not found by search")
    assert(tostring(selected.section) ~= "", "a toolkit match must name its section")
    local read = value(tool(token, {operation = "read", id = tostring(selected.id), limit = 16384}), "read toolkit")
    local content = tostring(read.content)
    assert(find(content, "tty.canvas"), "the toolkit reference does not name tty.canvas")
    assert(find(content, "canvas:put"), "the toolkit reference does not name canvas:put")
    local first_window = content
    if not find(first_window, "one-based") then
        -- Continue the same document when the heading sits past the first window.
        while read.next_offset ~= nil and not find(first_window, "one-based") do
            read = value(tool(token, {operation = "read", id = tostring(selected.id), offset = read.next_offset, limit = 16384}), "continue toolkit")
            first_window = tostring(read.content)
        end
    end
    if tostring(selected.id) == "toolkit" then
        assert(find(first_window, "one-based") or find(first_window, "1, 1"), "the toolkit reference does not state one-based cells")
        assert(find(first_window, "client.ready"), "the toolkit reference does not name client.ready")
    end
    return "tty.canvas with one-based canvas:put, present through output:present, client.ready after the first paint"
end
-- Question 2: how do admitted nodes exchange owned projections? Search the
-- cluster topic, then read the implemented sync contract the search found.
local function cross_node_sync(token: string): string
    local found = value(tool(token, {operation = "search", query = "expected revisions", topic = "cluster", limit = 8}), "search cluster")
    local results = found.results :: {{[string]: unknown}}
    assert(#results >= 1, "the cross-node search returned nothing")
    local selected: Object? = nil
    for _, result in ipairs(results) do
        if tostring(result.id) == "docs/sync_and_inbox" then selected = result end
    end
    assert(selected ~= nil, "the sync contract was not found by search")
    local read = value(tool(token, {operation = "read", id = tostring(selected.id), limit = 16384}), "read contract")
    local content = tostring(read.content)
    assert(find(content, "bee.sync"), "the sync contract does not name bee.sync")
    assert(find(content, "explicitly admitted nodes"), "the sync contract does not state node admission")
    assert(find(content, "expected revisions"), "the sync contract does not state revision checks")
    return "bee.sync exchanges owner-local projections between explicitly admitted nodes with expected revisions"
end
-- Question 3: how does a runtime module work? Read the SQL module from the
-- corpus by the id list returned, and the terminal module by name.
local function runtime_module(token: string): string
    local listed = value(tool(token, {operation = "list", topic = "storage", limit = 64}), "list storage")
    local documents = listed.documents :: {{[string]: unknown}}
    local found = false
    for _, document in ipairs(documents) do if tostring(document.id) == "runtime/lua/storage/sql" then found = true end end
    assert(found, "the SQL module is absent from the storage topic")
    local read = value(tool(token, {operation = "read", id = "runtime/lua/storage/sql", limit = 16384}), "read sql")
    local content = tostring(read.content)
    assert(find(content, "sql.builder.select"), "the SQL reference does not name sql.builder.select")
    assert(read.eof == false and type(read.next_offset) == "number", "a bounded read must report how to continue")
    local continued = value(tool(token, {operation = "read", id = "runtime/lua/storage/sql",
        offset = read.next_offset, limit = 16384}), "continue sql")
    assert(tostring(continued.offset) == tostring(read.next_offset), "the continuation did not resume at the returned offset")
    return "sql.builder.select with the fluent builder API, read in bounded windows by offset"
end
-- The tool is bounded: an oversized read and an unknown document are refused,
-- and the refusal is a tool error rather than a widened answer.
local function bounds_hold(token: string)
    local _, refused = rpc(token, "tools/call", {name = "docs", arguments = {operation = "read", id = "toolkit", limit = 40000}})
    assert(refused and refused.error, "an oversized read was admitted")
    local missing = tool(token, {operation = "read", id = "runtime/lua/core/nope"})
    assert(missing.ok == false and tostring(missing.code) == "NOT_FOUND", "an unknown document was not refused")
    local unknown = tool(token, {operation = "list", topic = "nope"})
    assert(unknown.ok == false and tostring(unknown.code) == "INVALID", "an unknown topic was not refused")
end
local function main()
    ADDRESS = endpoint()
    call("bee.gateway.binding:open", {address = ADDRESS})
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = key(), title = "Docs agent"})
    local token, binding_id = binding()
    local status, listed = rpc(token, "tools/list", {})
    assert(status == 200 and listed and listed.result, "tools/list failed")
    local names: {[string]: boolean} = {}
    for _, advertised in ipairs((listed.result :: Object).tools :: {{[string]: unknown}}) do names[tostring(advertised.name)] = true end
    assert(names["docs"] == true, "the docs tool is not advertised to this binding")
    bounds_hold(token)
    local first = terminal_toolkit(token)
    local second = cross_node_sync(token)
    local third = runtime_module(token)
    call("bee.gateway.binding:revoke", {binding_id = binding_id})
    -- Answers only; no token bytes reach captured output.
    io.print("docs agent: " .. first .. " | " .. second .. " | " .. third)
end
return {main = main}
