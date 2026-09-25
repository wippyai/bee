local bounds = require("bounds")
local migrations = require("migrations")
local claims = require("claims")
local subscriptions = require("subscriptions")
local waits = require("waits")
local recap = require("recap")
local notices = require("notices")
local M = {}
M.REVISION = "bee.threads.capabilities@1"
type Migration = {id: integer, name: string, rebuild: boolean}
type Contract = {contract: string, methods: {string}}
type Limits = {
    max_record_bytes: integer,
    max_page_records: integer,
    max_thread_records: integer,
    max_thread_members: integer,
    max_thread_actions: integer,
    max_thread_attempts: integer,
    max_thread_turns: integer,
    max_thread_obligations: integer,
    max_thread_subscriptions: integer,
    max_array_items: integer,
    max_json_depth: integer,
    max_title_bytes: integer,
    claim_ttl_seconds: integer,
    max_wait_ms: integer,
    wait_budget_margin_ms: integer,
    max_waiters_per_thread: integer,
    max_waiters: integer,
    recap_summary_lines: integer,
    recap_line_bytes: integer,
    max_pending_notices_per_thread: integer,
}
type Delivery = {
    channels: {string},
    self_service_only: boolean,
    delegated_replies: boolean,
    cross_thread_replies: boolean,
    cross_node_send: boolean,
    telemetry_subscribe: boolean,
    outstanding_pages_per_subscription: integer,
    transport_budget: {ceiling_ms: integer, caller_may_shorten: boolean, caller_may_extend: boolean},
}
type Report = {
    revision: string,
    record_schema: string,
    recap_schema: string,
    record_kinds: {string},
    record_sources: {string},
    outcomes: {string},
    migrations: {Migration},
    contracts: {Contract},
    limits: Limits,
    delivery: Delivery,
}
local function copy(list: {string}): {string}
    local result: {string} = {}
    for index, item in ipairs(list) do result[index] = item end
    return result
end
local function contract(id: string, methods: {string}): Contract
    return {contract = id, methods = copy(methods)}
end
function M.contracts(): {Contract}
    return {
        contract("bee.threads:journal", {"claim", "append", "read_after"}),
        contract("bee.threads:authority", {"create", "get", "list", "list_workspace", "join", "leave", "close", "record", "read_after", "send", "send_status", "notify"}),
        contract("bee.threads:lifecycle", {"admit_action", "prepare_attempt", "start_attempt", "request_turn", "end_turn", "receipt"}),
        contract("bee.threads:delivery", {"claim", "dispatch", "ack", "release", "expire", "reconcile", "subscribe", "page", "ack_page", "unsubscribe", "resume", "close_subscription", "forget_subscription", "wait", "watch"}),
        contract("bee.threads:projection", {"recap_read", "recap_update", "recap_rebuild", "status_read", "status_update", "status_rebuild"}),
        contract("bee.threads:carrier", {"claim", "commit", "checkpoint", "cancel_intent"}),
        contract("bee.threads:approvals", {"append"}),
    }
end
function M.describe(): Report
    local carried: {Migration} = {}
    for index, migration in ipairs(migrations.all()) do
        carried[index] = {id = migration.id, name = migration.name, rebuild = migration.rebuild}
    end
    return {
        revision = M.REVISION,
        record_schema = bounds.SCHEMA_REVISION,
        recap_schema = recap.SCHEMA,
        record_kinds = copy(bounds.KINDS),
        record_sources = copy(bounds.SOURCES),
        outcomes = copy(bounds.OUTCOMES),
        migrations = carried,
        contracts = M.contracts(),
        limits = {
            max_record_bytes = bounds.MAX_RECORD_BYTES,
            max_page_records = bounds.MAX_PAGE_RECORDS,
            max_thread_records = bounds.MAX_THREAD_RECORDS,
            max_thread_members = bounds.MAX_THREAD_MEMBERS,
            max_thread_actions = bounds.MAX_THREAD_ACTIONS,
            max_thread_attempts = bounds.MAX_THREAD_ATTEMPTS,
            max_thread_turns = bounds.MAX_THREAD_TURNS,
            max_thread_obligations = bounds.MAX_THREAD_OBLIGATIONS,
            max_thread_subscriptions = subscriptions.MAX_THREAD_SUBSCRIPTIONS,
            max_array_items = bounds.MAX_ARRAY_ITEMS,
            max_json_depth = bounds.MAX_JSON_DEPTH,
            max_title_bytes = bounds.MAX_TITLE_BYTES,
            claim_ttl_seconds = claims.CLAIM_TTL_SECONDS,
            max_wait_ms = waits.MAX_WAIT_MS,
            wait_budget_margin_ms = waits.BUDGET_MARGIN_MS,
            max_waiters_per_thread = waits.MAX_WAITERS_PER_THREAD,
            max_waiters = waits.MAX_WAITERS,
            recap_summary_lines = recap.MAX_SUMMARY_LINES,
            recap_line_bytes = recap.MAX_LINE_BYTES,
            max_pending_notices_per_thread = notices.MAX_PENDING_PER_WATCHER,
        },
        delivery = {
            channels = copy(claims.CHANNELS),
            self_service_only = true,
            delegated_replies = false,
            cross_thread_replies = false,
            cross_node_send = false,
            telemetry_subscribe = false,
            outstanding_pages_per_subscription = 1,
            transport_budget = {ceiling_ms = waits.MAX_WAIT_MS, caller_may_shorten = true, caller_may_extend = false},
        },
    }
end
return M
