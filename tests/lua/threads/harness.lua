-- MIT. Calls the authority as distinct principals with narrow scopes, so the
-- checks under test are the ones the host relies on.
local funcs = require("funcs")
local security = require("security")
local sql = require("sql")
local uuid = require("uuid")
local database = require("database")
local bounds = require("bounds")
local service_types = require("service_types")
local events = require("events")
local channel = require("channel")
local time = require("time")
local commits = require("commits")
type Reply = service_types.Reply
type Feed = {
    subscription: events.Subscription,
    reach: (Feed, integer) -> (),
    close: (Feed) -> (),
}
type Client = {
    id: string,
    call: (Client, string, {[string]: unknown}) -> Reply,
    start: (Client, string, {[string]: unknown}) -> funcs.Future,
}
local M = {}
function M.decode_reply(raw: unknown): Reply
    local reply = bounds.object(raw)
    if not reply or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then error("invalid thread reply") end
    local fault: service_types.Fault? = nil
    if reply.error ~= nil then
        local value = bounds.object(reply.error)
        if not value or type(value.code) ~= "string" or type(value.message) ~= "string" or type(value.retryable) ~= "boolean" then
            error("invalid thread reply fault")
        end
        fault = {code = value.code, message = value.message, retryable = value.retryable}
    end
    return {ok = reply.ok, error = fault, value = reply.value, replayed = reply.replayed}
end
-- A list of objects, bounded.
function M.objects(raw: unknown, maximum: integer): {{[string]: unknown}}
    local rows = assert(bounds.array(raw, maximum))
    local objects: {{[string]: unknown}} = {}
    for index, row in ipairs(rows) do objects[index] = assert(bounds.object(row)) end
    return objects
end
M.RESOURCE = database.RESOURCE
local SERVICE = "bee.threads.binding:"
local DELIVERY = {claim = true, dispatch = true, ack = true, release = true, expire = true, reconcile = true, subscribe = true, page = true, ack_page = true, unsubscribe = true, resume = true, close_subscription = true, forget_subscription = true, wait = true, watch = true}
local CLIENT_POLICY = "bee.tests.threads:client_policy"
local function scope_for(grants: {string}): security.Scope
    local policies: {security.Policy} = {}
    local names: {string} = {CLIENT_POLICY}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
-- grants name policies such as bee.threads.security:create; the client
-- policy only permits calling the service functions.
function M.principal(id: string, grants: {string}, workspace_id: string?): Client
    local actor = security.new_actor(id, workspace_id and {workspace_id = workspace_id} or {})
    local scope = scope_for(grants)
    local function call(self: Client, operation: string, request: {[string]: unknown}): Reply
        local target = SERVICE .. operation
        if DELIVERY[operation] then target = "bee.threads.binding:" .. (operation == "claim" and "delivery_claim" or operation) end
        if operation:sub(1, 6) == "recap_" or operation:sub(1, 7) == "status_" then target = "bee.threads.binding:" .. operation end
        if operation:sub(1, 8) == "carrier_" then target = "bee.threads.binding:" .. operation:sub(9) end
        if operation == "approval_append" then target = "bee.threads.binding:append" end
        local result, err = funcs.new():with_actor(actor):with_scope(scope):call(target, request)
        if err then error("call " .. operation .. ": " .. tostring(err)) end
        if type(result) ~= "table" then error("call " .. operation .. " returned " .. type(result)) end
        return M.decode_reply(result)
    end
    local function start(self: Client, operation: string, request: {[string]: unknown}): funcs.Future
        local target = SERVICE .. operation
        if DELIVERY[operation] then target = "bee.threads.binding:" .. (operation == "claim" and "delivery_claim" or operation) end
        local future, err = funcs.new():with_actor(actor):with_scope(scope):async(target, request)
        if err or not future then error("async " .. operation .. ": " .. tostring(err)) end
        return future
    end
    return {id = id, call = call, start = start}
end
-- Waits for an async call and decodes its reply.
function M.await(future: funcs.Future): Reply
    local channel = future:response()
    local payload, open = channel:receive()
    local value, err = future:result()
    if err or not value then error("async call: " .. tostring(err)) end
    if not open or not payload then error("async call closed without a reply") end
    local data: unknown = value:data()
    if type(data) ~= "table" then error("async call returned " .. type(data)) end
    return M.decode_reply(data)
end
-- The commits the Threads service announces on one thread. Subscribe before
-- the commits under test; reach blocks until the announcement of a record at
-- or past the sequence arrives. The service settles the notices a record
-- ends before it announces that record, so reaching it observes them.
function M.committed(thread_id: string): Feed
    local subscription, err = events.subscribe(commits.system(thread_id), commits.KIND)
    if not subscription then error("subscribe: " .. tostring(err)) end
    local function reach(_: Feed, sequence: integer)
        local source = subscription:channel()
        local deadline = time.after("20s")
        while true do
            local selected = channel.select({source:case_receive(), deadline:case_receive()})
            if selected.channel == deadline then error("no commit announced through sequence " .. tostring(sequence)) end
            if not selected.ok then error("commit subscription closed") end
            local data: unknown = selected.value.data
            if type(data) == "table" and type(data.sequence) == "number" and data.sequence >= sequence then return end
        end
    end
    local function close(_: Feed)
        subscription:close()
    end
    return {subscription = subscription, reach = reach, close = close}
end
M.ALL = {"bee.threads.security:create", "bee.threads.security:observe", "bee.threads.security:lifecycle"}
function M.session_owner(workspace_id: string?): Client
    return M.principal("sessions-owner", {"bee.threads.security:sessions_owner"}, workspace_id)
end
function M.key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
function M.value(reply: Reply): {[string]: unknown}
    if not reply.ok then error("expected success, got " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
function M.code(reply: Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
function M.thread(owner: Client, title: string): string
    local thread_id = "thread-" .. M.key()
    M.value(owner:call("create", {thread_id = thread_id, idempotency_key = M.key(), title = title}))
    return thread_id
end
function M.message(id: string, text: string): {[string]: unknown}
    return {message_id = id, message_kind = "request", recipient_ids = {}, content = {text = text}}
end
function M.request(id: string, text: string, recipients: {string}): {[string]: unknown}
    return {message_id = id, message_kind = "request", recipient_ids = recipients, content = {text = text}}
end
function M.reply(id: string, text: string, thread_id: string, record_id: string, outcome: string): {[string]: unknown}
    return {message_id = id, message_kind = "reply", recipient_ids = {}, content = {text = text}, in_reply_to = {thread_id = thread_id, record_id = record_id}, outcome = outcome}
end
function M.prepared(): {[string]: unknown}
    return {binding_ref = "b", binding_digest = "d", profile_id = "batch", profile_digest = "p", placement_binding = "bee.placement.native.binding:binding", placement_attempt_id = "placement-1", plan_digest = "plan"}
end
function M.admitted(): {[string]: unknown}
    return {request_id = "q", principal_id = "alice", binding_ref = "b", binding_digest = "d", grant_refs = {}, budget_ref = "budget", input = {text = "go"}}
end
-- Direct storage access for assertions about rows the authority never exposes.
function M.open(): sql.DB
    local db, err = database.open()
    if not db then error("open: " .. tostring(err)) end
    return db
end
function M.query(db: sql.DB, statement: string, params: {unknown}?): {{[string]: unknown}}
    local rows, err = db:query(statement, params or {})
    if err or not rows then error("query: " .. tostring(err)) end
    return rows
end
function M.execute(db: sql.DB, statement: string, params: {unknown}?)
    local _, err = db:execute(statement, params or {})
    if err then error("execute: " .. tostring(err)) end
end
function M.head_sequence(thread_id: string): integer
    local db = M.open()
    local rows = M.query(db, "SELECT head_sequence FROM bee_thread_heads WHERE thread_id = ?", {thread_id})
    db:release()
    return math.floor(tonumber(rows[1].head_sequence) or 0)
end
return M
