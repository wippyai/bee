local bounds = require("bounds")
local record_bounds = require("record_bounds")
local claims = require("claims")
local subscriptions = require("subscriptions")
local commits = require("commits")
local recap = require("recap")
local notices = require("notices")
local M = {}
M.REVISION = "bee.threads.capabilities@1"
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
        contract("bee.threads:authority", {"create", "get", "list", "list_workspace", "join", "leave", "close", "record", "search", "timeline", "read_after", "send", "send_status", "notify", "register_app_alias", "retire_app_alias", "fence_app"}),
        contract("bee.threads:lifecycle", {"admit_action", "prepare_attempt", "start_attempt", "request_turn", "end_turn", "receipt"}),
        contract("bee.threads:delivery", {"claim", "dispatch", "ack", "release", "expire", "reconcile", "subscribe", "page", "ack_page", "unsubscribe", "resume", "close_subscription", "forget_subscription", "wait", "watch"}),
        contract("bee.threads:projection", {"recap_read", "recap_update", "recap_rebuild", "status_read", "status_update", "status_rebuild"}),
        contract("bee.threads:carrier", {"claim", "commit", "checkpoint", "cancel_intent", "cancel_status"}),
        contract("bee.threads:approvals", {"append"}),
        contract("bee.threads:journal", {"session_create", "session_attach", "session_describe", "session_scan", "session_transition", "work_send", "work_describe", "work_await",
            "work_history", "work_scan", "turn_reserve", "turn_recover", "turn_pull", "turn_accept", "turn_observation", "work_settle", "work_uncertain", "work_cancel", "operation_lookup", "operation_describe", "feed_read"}),
    }
end
function M.describe(): Report
    return {
        revision = M.REVISION,
        record_schema = record_bounds.SCHEMA_REVISION,
        recap_schema = recap.SCHEMA,
        record_kinds = copy(record_bounds.KINDS),
        record_sources = copy(record_bounds.SOURCES),
        outcomes = copy(record_bounds.OUTCOMES),
        contracts = M.contracts(),
        limits = {
            max_record_bytes = record_bounds.MAX_RECORD_BYTES,
            max_page_records = record_bounds.MAX_PAGE_RECORDS,
            max_thread_records = record_bounds.MAX_THREAD_RECORDS,
            max_thread_members = record_bounds.MAX_THREAD_MEMBERS,
            max_thread_actions = record_bounds.MAX_THREAD_ACTIONS,
            max_thread_attempts = record_bounds.MAX_THREAD_ATTEMPTS,
            max_thread_turns = record_bounds.MAX_THREAD_TURNS,
            max_thread_obligations = record_bounds.MAX_THREAD_OBLIGATIONS,
            max_thread_subscriptions = subscriptions.MAX_THREAD_SUBSCRIPTIONS,
            max_array_items = bounds.MAX_ARRAY_ITEMS,
            max_json_depth = record_bounds.MAX_JSON_DEPTH,
            max_title_bytes = record_bounds.MAX_TITLE_BYTES,
            claim_ttl_seconds = claims.CLAIM_TTL_SECONDS,
            max_wait_ms = commits.MAX_WAIT_MS,
            wait_budget_margin_ms = commits.BUDGET_MARGIN_MS,
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
            transport_budget = {ceiling_ms = commits.MAX_WAIT_MS, caller_may_shorten = true, caller_may_extend = false},
        },
    }
end
return M
