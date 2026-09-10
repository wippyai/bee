-- MIT. Calls the authority as distinct principals with narrow scopes, so the
-- checks under test are the ones the host relies on.
local funcs = require("funcs")
local security = require("security")
local sql = require("sql")
local uuid = require("uuid")
local database = require("database")
type Reply = {ok: boolean, error: {code: string, message: string, retryable: boolean}?, value: any, replayed: boolean}
type Client = {
    id: string,
    call: (Client, string, {[string]: unknown}) -> Reply,
    start: (Client, string, {[string]: unknown}) -> any,
}
local M = {}
M.RESOURCE = "bee.threads:db"
local SERVICE = "bee.threads.service:"
local DELIVERY = {claim = true, dispatch = true, ack = true, release = true, expire = true, reconcile = true, subscribe = true, page = true, ack_page = true, unsubscribe = true, resume = true, close_subscription = true, forget_subscription = true, wait = true, watch = true}
local CLIENT_POLICY = "bee.threads:client_test_policy"
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
-- grants name host policies such as bee:thread_create_policy; the client
-- policy only permits calling the service functions.
function M.principal(id: string, grants: {string}): Client
    local actor = security.new_actor(id)
    local scope = scope_for(grants)
    local function call(self: Client, operation: string, request: {[string]: unknown}): Reply
        local target = SERVICE .. operation
        if DELIVERY[operation] then target = "bee.threads.delivery:" .. operation end
        if operation:sub(1, 6) == "recap_" or operation:sub(1, 7) == "status_" then target = "bee.threads.projection:" .. operation end
        if operation:sub(1, 8) == "carrier_" then target = "bee.threads.carrier:" .. operation:sub(9) end
        if operation == "approval_append" then target = "bee.threads.approvals:append" end
        local result, err = funcs.new():with_actor(actor):with_scope(scope):call(target, request)
        if err then error("call " .. operation .. ": " .. tostring(err)) end
        if type(result) ~= "table" then error("call " .. operation .. " returned " .. type(result)) end
        return result :: Reply
    end
    local function start(self: Client, operation: string, request: {[string]: unknown}): any
        local target = SERVICE .. operation
        if DELIVERY[operation] then target = "bee.threads.delivery:" .. operation end
        local future, err = funcs.new():with_actor(actor):with_scope(scope):async(target, request)
        if err or not future then error("async " .. operation .. ": " .. tostring(err)) end
        return future
    end
    return {id = id, call = call, start = start}
end
-- Waits for an async call and decodes its reply.
function M.await(future: any): Reply
    local channel = future:response()
    local payload, open = channel:receive()
    local value, err = future:result()
    if err then error("async call: " .. tostring(err)) end
    if not open or not payload then error("async call closed without a reply") end
    local data: unknown = value:data()
    if type(data) ~= "table" then error("async call returned " .. type(data)) end
    return data :: Reply
end
M.ALL = {"bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_lifecycle_policy"}
function M.key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
function M.value(reply: Reply): any
    if not reply.ok then error("expected success, got " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value
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
    return {binding_ref = "b", binding_digest = "d", profile_id = "batch", profile_digest = "p", placement_binding = "bee.placement.native:binding", placement_attempt_id = "placement-1", plan_digest = "plan"}
end
function M.admitted(): {[string]: unknown}
    return {request_id = "q", principal_id = "alice", binding_ref = "b", binding_digest = "d", grant_refs = {}, budget_ref = "budget", input = {text = "go"}}
end
-- Direct storage access for assertions about rows the authority never exposes.
function M.open(resource: string?): sql.DB
    local db, err = database.open(resource or M.RESOURCE)
    if not db then error("open: " .. tostring(err)) end
    return db
end
-- The bare resource without the ledger check, for tests that alter the ledger.
function M.raw(resource: string): sql.DB
    local db, err = sql.get(resource)
    if not db then error("sql.get: " .. tostring(err)) end
    return db
end
function M.query(db: sql.DB, statement: string, params: {unknown}?): {{[string]: any}}
    local rows, err = db:query(statement, params or {})
    if err or not rows then error("query: " .. tostring(err)) end
    return rows :: {{[string]: any}}
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
