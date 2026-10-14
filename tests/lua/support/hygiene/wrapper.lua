local funcs = require("funcs")
local process = require("process")
local registry = require("registry")
local ctx = require("ctx")
local json = require("json")
local bounds = require("bounds")
local time = require("time")
local system = require("system")
local function inspect(operation: string, identity: string?, elapsed: number?, body_elapsed: number?)
    local replies = assert(process.listen("bee.test.hygiene.reply", {message = true}))
    local registered = process.registry.lookup("bee.test.hygiene", process.registry.LOCAL)
    assert(registered, "hygiene startup: " .. assert(json.encode(assert(system.supervisor.state("bee.tests.support.hygiene:service")))))
    local owner = tostring(registered)
    assert(process.send(owner, "bee.test.hygiene", {operation = operation, identity = identity, elapsed = elapsed, body_elapsed = body_elapsed}))
    local reply = assert((replies:receive()))
    process.unlisten(replies)
    assert(tostring(reply:from()) == owner)
    local value = assert(bounds.object(reply:payload():data()))
    local leaks = assert(bounds.array(value.leaks, 10000))
    assert(#leaks == 0, "suite leaks: " .. assert(json.encode(leaks)))
end
local function run(args: unknown): unknown
    local started = time.now()
    inspect("begin")
    local identity = assert(bounds.object(args)).ref_id
    assert(type(identity) == "string")
    local entry = assert(registry.get(identity))
    local body = entry.meta.hygiene_body
    assert(type(body) == "string")
    local body_started = time.now()
    local future = assert(funcs.new():with_context({parent_pid = ctx.get("parent_pid"), test_topic = ctx.get("test_topic")}):async(body, args))
    future:response():receive()
    local payload, fault = future:result()
    local value = payload and payload:data()
    local elapsed = time.now():sub(started):milliseconds() / 1000
    local body_elapsed = time.now():sub(body_started):milliseconds() / 1000
    local clean, hygiene = pcall(inspect, "check", identity, elapsed, body_elapsed)
    assert(not fault and clean, tostring(fault or "") .. " " .. tostring(hygiene or ""))
    return value
end
return {run = run}
