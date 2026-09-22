-- MIT. Carry one real application from authoring through approval to an
-- applied, admitted registry entry, using the production governance/delivery
-- chain: author into a governed workspace, freeze, publish, discover, stage,
-- preflight, review, select, approve, consume and apply. Source and
-- destination are the same node, the same simplification the governance unit
-- suites use; the chain of calls is the one a distributed delivery drives.
local funcs = require("funcs")
local registry = require("registry")
local system = require("system")
local env = require("env")
local json = require("json")
local sql = require("sql")
local logger = require("logger")
local bounds = require("bounds")
local artifact = require("artifact")
local materializer = require("materializer")
local preflight = require("preflight")
local catalog = require("catalog")

type Object = {[string]: unknown}

local SOURCE_WORKSPACE = "app-journey-source"
local COMPONENT = "bee.app_journey_demo/app"
local OVERLAY_OWNER = "bee.app_journey_probe:activation_overlay"
local APPROVAL_POLICY = "local-app-journey"
local VERSION = "1.0.0"
local DEFINITION_ID = "bee.app_journey_demo:app"
local APP_TITLE = "App Journey"
local RETRY_EFFECT = "app-journey-second-effect"
local LOGICAL_DB = "bee.app_journey_demo:data"
local PHYSICAL_DB = "bee.app_journey_probe:shared_db"
local TABLE_PREFIX = "journey_"
local MIGRATION_ID = "bee.app_journey_demo:001"

local APP_SOURCE = [[local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local time = require("time")

type Object = {[string]: unknown}

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local thread_results = assert(process.listen("bee.application.thread.result", {message = true}))
    local rechecks = assert(process.listen("bee.app_journey_probe.recheck", {message = true}))
    local revocations = assert(process.listen("bee.app_open_probe.access.revoke.result", {message = true}))
    local stale_status = "n/a"
    local operator: string? = nil
    for _ = 1, 100 do
        operator = process.registry.lookup("bee.app_open_probe:operator")
        if operator then break end
        time.sleep("20ms")
    end
    if not operator then error("app-open operator is unavailable") end
    assert(process.send(operator, "bee.app_open_probe.credentials", {instance_id = launch.instance_id,
        launch_token = launch.launch_token, execution_generation = launch.execution_generation}))
    local count = 0
    local thread_complete = false
    if launch.resume_state ~= "" then
        local state: unknown = json.decode(launch.resume_state)
        if type(state) ~= "table" or type(state.count) ~= "number" then error("Invalid counter checkpoint") end
        count = math.floor(state.count)
        thread_complete = state.thread_complete == true
    end
    -- Access is execution-local evidence. A restored checkpoint records that
    -- the durable proof completed, but every new producer must perform a
    -- fresh request before the UI may claim current access.
    local thread_status = launch.thread_id == nil and "unbound" or "pending"
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local saved = -1
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        canvas:put(1, 1, "APP JOURNEY DELIVERED", width)
        canvas:put(1, 2, "Count: " .. tostring(count), width)
        canvas:put(1, 3, "Saved: " .. tostring(saved), width)
        canvas:put(1, 4, "Access: " .. thread_status, width)
        canvas:put(1, 5, "Stale credentials: " .. stale_status, width)
        assert(output:present(canvas:rows()))
    end
    local function checkpoint()
        assert(client.checkpoint(launch, json.encode({count = count, thread_complete = thread_complete})))
    end

    local function object(raw: unknown, label: string): Object
        if type(raw) ~= "table" then error(label .. " reply value is not an object") end
        return raw :: Object
    end
    local function exact_fields(value: Object, allowed: {string}, label: string)
        local fields: {[string]: boolean} = {}
        for _, name in ipairs(allowed) do fields[name] = true end
        for name in pairs(value) do
            if not fields[name] then error(label .. " reply has unexpected field " .. tostring(name)) end
        end
    end
    local function identifier(raw: unknown, label: string): string
        if type(raw) ~= "string" or raw == "" or #raw > 160 or raw:find("%c") then
            error(label .. " is not a bounded identifier")
        end
        return raw
    end
    local function integer(raw: unknown, label: string): integer
        if type(raw) ~= "number" or raw ~= math.floor(raw) or raw < 0 then
            error(label .. " is not a nonnegative integer")
        end
        local result: integer = math.floor(raw)
        return result
    end
    local function positive(raw: unknown, label: string): integer
        local result = integer(raw, label)
        if result < 1 then error(label .. " must be positive") end
        return result
    end
    local function boolean(raw: unknown, label: string): boolean
        if type(raw) ~= "boolean" then error(label .. " is not a boolean") end
        return raw
    end
    local function records(raw: unknown, label: string, thread_id: string): {Object}
        if type(raw) ~= "table" then error(label .. " records are not a list") end
        local list = raw :: {unknown}
        local result: {Object} = {}
        for index, item in ipairs(list) do
            local record = object(item, label .. " record")
            identifier(record.record_id, label .. " record id")
            if record.thread_id ~= thread_id or record.kind ~= "message" then
                error(label .. " returned a record from another thread or family")
            end
            positive(record.sequence, label .. " record sequence")
            result[index] = record
        end
        return result
    end

    local function run_thread_probe(thread_id: string)
        local function await(operation: string, arguments: Object): Object
            local request_id, request_error = client.thread_request(launch, operation, arguments)
            if not request_id then error(operation .. " request failed: " .. tostring(request_error)) end
            while true do
                local selected = channel.select({thread_results:case_receive(), lifecycle:case_receive()})
                if not selected.ok then error(operation .. " reply channel closed") end
                if selected.channel == lifecycle then
                    if selected.value.kind == process.event.CANCEL then error(operation .. " cancelled") end
                else
                    local message = selected.value
                    local reply = client.thread_result(launch, message:from(), message:payload():data())
                    if reply and reply.request_id == request_id then
                        if not reply.ok then
                            local failure = reply.error
                            error(operation .. " failed: " .. tostring(failure and failure.code or "unknown"))
                        end
                        return object(reply.value, operation)
                    end
                end
            end
        end

        local subscription = await("subscribe", {idempotency_key = launch.instance_id .. "-thread-subscribe", after_sequence = 0})
        exact_fields(subscription, {"subscription_id", "consumer_id", "after_sequence", "lease_generation",
            "owner_incarnation", "owner_authority", "durability", "filter_digest", "closed"}, "subscribe")
        local subscription_id = identifier(subscription.subscription_id, "subscription id")
        if subscription.consumer_id ~= "bee.application:" .. launch.workspace_id .. ":" .. launch.instance_id
            or integer(subscription.after_sequence, "subscription cursor") ~= 0
            or positive(subscription.lease_generation, "subscription lease") < 1
            or positive(subscription.owner_incarnation, "subscription owner incarnation") < 1
            or identifier(subscription.owner_authority, "subscription owner authority") == ""
            or subscription.durability ~= "durable"
            or identifier(subscription.filter_digest, "subscription filter digest") == ""
            or boolean(subscription.closed, "subscription closed") then
            error("subscribe reply shape is invalid")
        end

        local marker = await("post", {idempotency_key = launch.instance_id .. "-thread-probe-post",
            message_id = launch.instance_id .. "-thread-probe-message", message_kind = "notification",
            recipient_ids = {}, content = {text = "app-thread-probe.v1"}})
        exact_fields(marker, {"record_id", "sequence"}, "post")
        local marker_id = identifier(marker.record_id, "post record id")
        local marker_sequence = positive(marker.sequence, "post sequence")

        local read = await("read", {cursor = 0, limit = 64})
        exact_fields(read, {"records", "scanned_through", "has_more"}, "read")
        local read_records = records(read.records, "read", thread_id)
        integer(read.scanned_through, "read scanned cursor")
        boolean(read.has_more, "read has_more")
        local found_post = false
        for _, record in ipairs(read_records) do
            if record.record_id == marker_id and record.sequence == marker_sequence then found_post = true end
        end
        if not found_post then error("read did not return the posted proof") end

        local page = await("page", {subscription_id = subscription_id, limit = 64})
        exact_fields(page, {"subscription_id", "page_id", "records", "from_sequence", "scanned_through",
            "has_more", "lease_generation"}, "page")
        if page.subscription_id ~= subscription_id then error("page subscription identity changed") end
        local page_id = identifier(page.page_id, "page id")
        local page_records = records(page.records, "page", thread_id)
        boolean(page.has_more, "page has_more")
        if integer(page.from_sequence, "page from cursor") ~= 0
            or integer(page.scanned_through, "page scanned cursor") < marker_sequence
            or positive(page.lease_generation, "page lease") < 1 then
            error("page reply shape is invalid")
        end
        local found_page_post = false
        for _, record in ipairs(page_records) do
            if record.record_id == marker_id then found_page_post = true end
        end
        if not found_page_post then error("page did not return the posted proof") end

        local acknowledged = await("ack_page", {idempotency_key = launch.instance_id .. "-thread-proof-ack",
            subscription_id = subscription_id, page_id = page_id, scanned_through = page.scanned_through})
        exact_fields(acknowledged, {"subscription_id", "after_sequence"}, "ack_page")
        if acknowledged.subscription_id ~= subscription_id
            or integer(acknowledged.after_sequence, "acknowledged cursor") ~= integer(page.scanned_through, "page cursor") then
            error("ack_page reply shape is invalid")
        end

        local proof = {schema = "app-thread-proof.v1", workspace_id = launch.workspace_id,
            instance_id = launch.instance_id, thread_id = thread_id, subscribe = "ok", post = "ok",
            read = "ok", page = "ok", ack_page = "ok", execution_pid = tostring(process.pid())}
        local proof_text = json.encode(proof)
        local posted = await("post", {idempotency_key = launch.instance_id .. "-thread-proof-post",
            message_id = launch.instance_id .. "-thread-proof-message", message_kind = "notification",
            recipient_ids = {}, content = {text = proof_text}})
        exact_fields(posted, {"record_id", "sequence"}, "post")
        identifier(posted.record_id, "proof record id")
        positive(posted.sequence, "proof sequence")
    end

    local function recheck(recipient: string?)
        if not launch.thread_id then return end
        thread_status = "checking"; paint()
        local request_id, request_error = client.thread_request(launch, "read", {cursor = 0, limit = 1})
        if not request_id then error("fresh read request failed: " .. tostring(request_error)) end
        local deadline = time.after("5s")
        while true do
            local selected = channel.select({thread_results:case_receive(), lifecycle:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("fresh read result timed out") end
            if selected.channel == lifecycle then
                if selected.value.kind == process.event.CANCEL then error("fresh read cancelled") end
            else
                local message = selected.value
                local reply = client.thread_result(launch, message:from(), message:payload():data())
                if reply and reply.request_id == request_id then
                    local code = reply.error and tostring(reply.error.code) or ""
                    if reply.ok then thread_status = "active"
                    elseif code == "DENIED" then thread_status = "denied"
                    else error("fresh read failed: " .. (code == "" and "unknown" or code)) end
                    paint(); checkpoint()
                    if recipient then
                        assert(process.send(recipient, "bee.app_journey_probe.recheck.result", {
                            instance_id = launch.instance_id, access = thread_status, code = code}))
                    end
                    return
                end
            end
        end
    end

    paint(); client.ready(launch); checkpoint()
    -- APP_JOURNEY_REPLACEMENT_PROBE
    if launch.thread_id and not thread_complete then
        run_thread_probe(launch.thread_id)
        thread_complete = true
        thread_status = "active"
        paint(); checkpoint()
    end
    while true do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive(),
            rechecks:case_receive(), revocations:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == receipts then
            local message = event.value
            local data: unknown = message:payload():data()
            if message:from() == launch.broker_pid and type(data) == "table" and data.error_code == "" then
                saved = count; paint()
            end
        elseif event.channel == rechecks then
            recheck(tostring(event.value:from()))
        elseif event.channel == revocations then
            local revoked: unknown = event.value:payload():data()
            if tostring(event.value:from()) ~= operator or type(revoked) ~= "table"
                or revoked.instance_id ~= launch.instance_id or revoked.ok ~= true then
                error("host access update failed")
            end
            recheck(nil)
        elseif event.value.type == "close" then checkpoint(); break
        elseif event.value.type == "resize" then width, height = event.value.width, event.value.height; paint()
        elseif event.value.type == "key" and event.value.action ~= "release" then
            if event.value.key == "r" then recheck(nil)
            elseif event.value.key == "d" then
                thread_status = "revoking"; paint()
                assert(process.send(operator, "bee.app_open_probe.access.revoke", {instance_id = launch.instance_id}))
            else count = count + 1; paint(); checkpoint() end
        end
    end
    process.unlisten(rechecks)
    process.unlisten(revocations)
    process.unlisten(thread_results)
    output:close(); tty.stop()
end
return {main = main}
]]

local MIGRATION_SOURCE = [[local sql = require("sql")
local function run(options)
    assert(options.target_db == "bee.app_journey_demo:data")
    assert(options.database_id == "bee.app_journey_probe:shared_db")
    assert(options.table_prefix == "journey_")
    assert(options.direction == "up")
    local db = assert(sql.get(options.database_id))
    local table_name = options.table_prefix .. "items"
    local tx = assert(db:begin())
    assert(tx:execute("CREATE TABLE IF NOT EXISTS _migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"))
    assert(tx:execute("CREATE TABLE " .. table_name .. " (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"))
    assert(tx:execute("INSERT INTO " .. table_name .. " (value) VALUES ('journey')"))
    assert(tx:execute("INSERT INTO _migrations (id, applied_at) VALUES ($1, $2)",
        {options.id, "2026-09-19T19:00:00Z"}))
    assert(tx:commit())
    db:release()
    return {id = options.id, status = "applied"}
end
return {run = run}
]]

local function seed_shared_database()
    local db = assert(sql.get(PHYSICAL_DB))
    local tx = assert(db:begin())
    assert(tx:execute("CREATE TABLE IF NOT EXISTS other_items (value TEXT NOT NULL)"))
    local rows = assert(tx:query("SELECT COUNT(*) AS count FROM other_items"))
    if tonumber(rows[1].count) == 0 then
        assert(tx:execute("INSERT INTO other_items (value) VALUES ('preserved')"))
    end
    assert(tx:commit())
    db:release()
end

local function assert_shared_database()
    local db = assert(sql.get(PHYSICAL_DB))
    local migrations = assert(db:query("SELECT id FROM _migrations ORDER BY id"))
    if #migrations ~= 1 or migrations[1].id ~= MIGRATION_ID then error("physical migration ledger differs") end
    local journey = assert(db:query("SELECT value FROM journey_items ORDER BY id"))
    if #journey ~= 1 or journey[1].value ~= "journey" then error("prefixed application table differs") end
    local other = assert(db:query("SELECT value FROM other_items"))
    if #other ~= 1 or other[1].value ~= "preserved" then error("shared database row was not preserved") end
    local unprefixed = assert(db:query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'items'"))
    if #unprefixed ~= 0 then error("migration created an unprefixed items table") end
    db:release()
end

local function object(value: unknown): Object
    local decoded = bounds.object(value)
    if not decoded then error("expected object value") end
    return decoded
end

-- The reply's value carries fault detail as well as success detail: a
-- REVALIDATE fault reports the current authority incarnation there.
local function reply_of(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. " call failed: " .. tostring(err)) end
    return object(result)
end

local function call_api(target: string, request: unknown): Object
    local reply = reply_of(target, request)
    if reply.ok ~= true then
        error(target .. " returned error: " .. tostring(reply.code) .. ": " .. tostring(reply.message or json.encode(reply.error)))
    end
    local value = bounds.object(reply.value)
    if not value then error(target .. " missing value") end
    return value
end

local function fault_code(reply: Object): string
    local fault = bounds.object(reply.error)
    return tostring(fault and fault.code or reply.code)
end

local function digest_of(value: unknown, label: string): string
    local measured = bounds.id(value)
    if not measured then error(label .. " is not a digest") end
    return measured
end

local function admitted_title(workspace_id: string): string?
    for _, item in ipairs(catalog.read(workspace_id).items) do
        if item.definition_id == DEFINITION_ID then return item.title end
    end
    return nil
end

local function configure_host(workspace_id: string, local_node: string)
    local pub_entry = assert(registry.get("bee.governance:publication_profiles"))
    local pub_data = object(pub_entry.data)
    pub_data.profiles = {{workspace_id = workspace_id, source_workspace = SOURCE_WORKSPACE,
        component = COMPONENT, overlay_owner = OVERLAY_OWNER}}
    pub_entry.data = pub_data

    local act_entry = assert(registry.get("bee.governance:activation_profiles"))
    local act_data = object(act_entry.data)
    act_data.profiles = {{workspace_id = workspace_id, source_node = local_node, source_workspace = SOURCE_WORKSPACE,
        component = COMPONENT, resolver = "overlay", overlay_owner = OVERLAY_OWNER, approval_policy = APPROVAL_POLICY,
        parameters = {}, allow = {packages = {COMPONENT}, namespaces = {"bee.app_journey_demo"},
            kinds = {"process.lua", "function.lua"}, databases = {LOGICAL_DB}, grants = {},
            modules = {"tty", "process", "channel", "json", "sql", "time"}},
        database_bindings = {{target_db = LOGICAL_DB, database_id = PHYSICAL_DB, table_prefix = TABLE_PREFIX}},
        migration_policies = {"bee.app_journey_probe:migration_policy"}}}
    act_entry.data = act_data

    local policy_entry = assert(registry.get("bee:approver_policies"))
    local policy_data = object(policy_entry.data)
    local policies = policy_data.policies :: {unknown}
    policies[#policies + 1] = {name = APPROVAL_POLICY,
        approvers = {"bee.app_journey.operator", {definition_id = "bee.inbox:app"}}, max_ttl_ms = 600000}
    policy_data.policies = policies
    policy_entry.data = policy_data

    local changes = registry.snapshot():changes()
    assert(changes:update(pub_entry))
    assert(changes:update(act_entry))
    assert(changes:update(policy_entry))
    local applied, apply_error = changes:apply()
    if not applied then error("apply host delivery profiles: " .. tostring(apply_error)) end
    local selected = assert(registry.get("bee.governance.registry:activation_profiles_ref"))
    local selected_data = object(selected.data)
    if selected_data.resource_ref ~= "bee.governance:activation_profiles" then
        error("activation profile requirement did not retain the default selection")
    end
    local retained = assert(registry.get(selected_data.resource_ref :: string))
    local retained_data = object(retained.data)
    if type(retained_data.profiles) ~= "table" or #retained_data.profiles ~= 1 then
        error("activation profile update did not retain its configured data")
    end
end

local function main()
    local workspace_id = bounds.id(env.get("bee.app_journey_probe:destination_workspace"))
    if not workspace_id then error("destination workspace identity is unavailable") end
    if registry.get(DEFINITION_ID) then error("candidate must be absent before governed activation") end
    -- Admission is already bound by the host, and that binding alone admits
    -- nothing: the effective catalog carries no descriptor until the reviewed
    -- definition exists.
    if admitted_title(workspace_id) then error("admission binding admitted an application that does not exist") end

    seed_shared_database()
    local entries = {{id = DEFINITION_ID, kind = "process.lua", data = {source = APP_SOURCE, method = "main",
        modules = {"tty", "process", "channel", "json", "time"}, imports = {client = "bee.application:client"}},
        meta = {type = "bee.application", application = {api_version = 1, lifetime = "view", revision = "1",
            title = APP_TITLE, instance_policy = "multiple", resume_schema = "app-journey.v1",
            restart_policy = "automatic"}}},
        {id = MIGRATION_ID, kind = "function.lua", data = {source = MIGRATION_SOURCE, method = "run", modules = {"sql"}},
            meta = {type = "migration", target_db = LOGICAL_DB, ordinal = 1}}}
    local measured, measure_error = artifact.create(entries)
    if not measured then error("measure app entries: " .. tostring(measure_error)) end
    local artifact_digest = digest_of(measured.digest, "authored artifact digest")

    -- Author into a governed workspace and freeze it, exactly as a person
    -- editing the source tree would.
    local create_res = call_api("bee.governance.binding:overlay_call", {operation = "create",
        overlay_id = SOURCE_WORKSPACE, expected_revision = 0, idempotency_key = "create-" .. SOURCE_WORKSPACE})
    if create_res.revision ~= 1 then error("workspace create revision expected 1") end
    local put_res = call_api("bee.governance.binding:overlay_call", {operation = "put", overlay_id = SOURCE_WORKSPACE,
        expected_revision = 1, idempotency_key = "put-entries-" .. SOURCE_WORKSPACE, path = "entries.json",
        content = json.encode(measured.entries)})
    if put_res.revision ~= 2 then error("workspace put revision expected 2") end
    local freeze_res = call_api("bee.governance.binding:overlay_call", {operation = "freeze",
        overlay_id = SOURCE_WORKSPACE, expected_revision = 2, idempotency_key = "freeze-" .. SOURCE_WORKSPACE})
    local snapshot_digest = digest_of(freeze_res.digest, "frozen overlay digest")

    local local_node = assert(system.node.id())
    configure_host(workspace_id, local_node)

    local pub_res = call_api("bee.governance.binding:publication_call", {operation = "prepare", workspace_id = workspace_id,
        component = COMPONENT, version = VERSION, snapshot_digest = snapshot_digest})
    local descriptor = object(pub_res.descriptor)
    local manifest = object(descriptor.manifest)
    if manifest.artifact_digest ~= artifact_digest then
        error("descriptor artifact digest does not match the authored artifact")
    end

    local available = call_api("bee.governance.binding:destination_call", {operation = "available", workspace_id = workspace_id})
    local found = false
    for _, raw in ipairs(available.versions :: {unknown}) do
        local item = object(raw)
        if item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then error("prepared descriptor was not discoverable by the destination") end

    local stage_res = call_api("bee.governance.binding:destination_call", {operation = "stage", workspace_id = workspace_id,
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest, idempotency_key = "stage-" .. workspace_id})
    if stage_res.status ~= "staged" or stage_res.selected == true then error("staged plan is not staged-and-unselected") end

    -- The staged plan is the review surface: its exact artifact bytes and the
    -- destination's own preflight report, verified against its digest.
    local staged = call_api("bee.governance.binding:destination_call", {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION})
    local plan_digest = digest_of(staged.plan_digest, "staged plan digest")
    if staged.artifact_digest ~= artifact_digest then error("staged plan carries another artifact digest") end
    local report, report_error = preflight.decode_report(staged.preflight_bytes, staged.preflight_digest)
    if not report then error("staged preflight report: " .. tostring(report_error)) end
    if report.ready ~= true or #report.diagnostics > 0 then
        error("staged plan preflight is not ready: " .. json.encode(report.diagnostics))
    end
    if #report.pending_migrations ~= 1 or report.pending_migrations[1] ~= LOGICAL_DB .. "\n" .. MIGRATION_ID then
        error("staged plan does not report the logical pending migration")
    end

    local review_res = call_api("bee.governance.binding:destination_call", {operation = "review", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION,
        expected_revision = staged.revision, idempotency_key = "review-" .. workspace_id,
        review_status = "accepted", review_reason = "app journey acceptance review"})
    if review_res.review_status ~= "accepted" then error("plan was not reviewed accepted") end

    local select_res = call_api("bee.governance.binding:destination_call", {operation = "select", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION,
        expected_revision = review_res.revision, idempotency_key = "select-" .. workspace_id})
    if select_res.selected ~= true then error("plan was not selected") end

    local intent_id, receipt_key = "intent-" .. workspace_id, "receipt-" .. workspace_id
    local prepared = call_api("bee.governance.binding:destination_call", {operation = "prepare", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = SOURCE_WORKSPACE, version = VERSION,
        intent_id = intent_id, receipt_key = receipt_key})
    if prepared.phase ~= "approval_bound" then error("prepared activation phase expected approval_bound") end
    local approval_id = bounds.id(prepared.approval_id)
    local proposal_digest = digest_of(prepared.approval_proposal_digest, "approval proposal digest")
    if not approval_id then error("prepare omitted the approval identity") end

    -- The decision is bound to this one proposal. The approvals owner refuses
    -- a decision offered against any other digest, so a decision carried over
    -- from other evidence cannot authorize this activation.
    local misdirected = reply_of("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = 1,
        decision = "approved", proposal_digest = artifact_digest})
    if misdirected.ok == true then error("a decision on another proposal digest was accepted") end
    if fault_code(misdirected) ~= "CONFLICT" then
        error("a decision on another proposal digest was refused with " .. fault_code(misdirected) .. " instead of CONFLICT")
    end

    local pending = call_api("bee.governance.binding:destination_call", {operation = "step", workspace_id = workspace_id,
        intent_id = intent_id, receipt_key = receipt_key})
    if pending.phase == "settled" or registry.get(DEFINITION_ID) then
        error("unapproved candidate was applied")
    end

    -- The person deciding is the same operator identity in this fixture;
    -- the decision itself is the real bee.approvals.binding:decide call.
    call_api("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = 1,
        decision = "approved", proposal_digest = proposal_digest})

    local stepped: Object = prepared
    for _ = 1, 8 do
        stepped = call_api("bee.governance.binding:destination_call", {operation = "step", workspace_id = workspace_id,
            intent_id = intent_id, receipt_key = receipt_key})
        if stepped.phase == "settled" then break end
    end
    if stepped.phase ~= "settled" or stepped.outcome ~= "applied" then
        error("activation did not settle applied; phase=" .. tostring(stepped.phase) .. " outcome=" .. tostring(stepped.outcome))
    end

    -- The settled record is the fence's evidence: the composed base this
    -- overlay landed on is the one the owner reviewed and approved.
    local status = call_api("bee.governance.binding:destination_call", {operation = "status",
        workspace_id = workspace_id, intent_id = intent_id})
    if status.plan_digest ~= plan_digest then error("settled activation records another plan digest") end
    -- The proposal the owner decided binds this authorization digest, which
    -- the activation store measures over the exact plan digest, plan revision
    -- and artifact, resolution and preflight digests.
    digest_of(status.authorization_digest, "activation authorization digest")
    if status.approval_proposal_digest ~= proposal_digest then error("settled activation bound another proposal") end
    -- The owner re-preflights locally before apply and keeps that report as
    -- durable evidence, with the transient registry revision normalized away;
    -- it is a second report over the same candidate, not the source's.
    local local_report, local_report_error = preflight.decode_report(status.preflight_bytes, status.preflight_digest)
    if not local_report then error("activation preflight report: " .. tostring(local_report_error)) end
    if local_report.ready ~= true or #local_report.diagnostics > 0 then
        error("activation preflight is not ready: " .. json.encode(local_report.diagnostics))
    end
    digest_of(status.resolution_digest, "activation resolution digest")
    -- The overlay slot is the activation owner's own receipt: it names the
    -- host-configured overlay owner and the intent that observed the apply.
    if status.overlay_owner ~= OVERLAY_OWNER then error("settled activation names another overlay owner") end
    if status.observed_intent_id ~= intent_id then error("overlay slot was not observed by this activation") end
    if status.observed_outcome ~= "applied" then error("overlay slot records outcome " .. tostring(status.observed_outcome)) end
    if status.consumed_proposal_digest ~= proposal_digest then error("settled activation consumed another proposal") end
    if status.observed_artifact_digest ~= artifact_digest then error("applied overlay observed another artifact") end
    if status.outcome ~= "applied" then error("settled activation outcome is " .. tostring(status.outcome)) end
    if status.migrations_completed ~= true then error("settled activation did not complete migrations") end
    local migration_receipt = json.decode(tostring(status.migration_receipt_bytes))
    local receipt_rows = migration_receipt and migration_receipt.rows
    if type(receipt_rows) ~= "table" or #receipt_rows ~= 1 or receipt_rows[1].id ~= MIGRATION_ID
        or receipt_rows[1].target_db ~= LOGICAL_DB or receipt_rows[1].status ~= "applied" then
        error("settled activation migration receipt differs")
    end
    assert_shared_database()
    local incarnation = status.approval_owner_incarnation
    if type(incarnation) ~= "number" then error("settled activation recorded no approval incarnation") end

    -- One decision authorizes one effect. The activation owner already
    -- consumed it; no second effect may claim the same decision.
    local second = reply_of("bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = proposal_digest,
        owner_incarnation = math.floor(incarnation :: number), effect_key = RETRY_EFFECT})
    if second.ok == true then error("a second effect consumed the same decision") end
    if fault_code(second) ~= "CONFLICT" then
        error("second consume refused with " .. fault_code(second) .. " instead of CONFLICT")
    end

    local app_entry = registry.get(DEFINITION_ID)
    if not app_entry then error("resulting registry entry " .. DEFINITION_ID .. " is missing") end
    if object(app_entry.data).source ~= APP_SOURCE then error("applied app source does not match the authored bytes") end
    local matches, match_error = materializer.matches(OVERLAY_OWNER, measured.entries)
    if matches ~= true then error("applied overlay differs from the reviewed artifact: " .. tostring(match_error)) end

    -- Overlay authority is the activation owner's alone. This caller drove
    -- the whole governed chain and still cannot materialize an overlay.
    local forced, force_error = materializer.reconcile("bee.app_journey_probe:forbidden_overlay", measured.entries)
    if forced then error("a caller outside the activation owner materialized an overlay") end
    if not force_error then error("the refused overlay write reported no reason") end

    -- The same effective catalog the application broker reads now carries the
    -- approved definition, so the host admits it.
    local title = admitted_title(workspace_id)
    if title ~= APP_TITLE then error("effective catalog does not admit the applied application") end

    logger:info("APP_JOURNEY_DELIVERED", {artifact_digest = artifact_digest, snapshot_digest = snapshot_digest,
        plan_digest = plan_digest, preflight_digest = staged.preflight_digest, proposal_digest = proposal_digest,
        workspace_id = workspace_id, admitted_title = title, overlay_owner = tostring(status.overlay_owner),
        refused_overlay_write = tostring(force_error), migration_id = MIGRATION_ID,
        migration_target = LOGICAL_DB, database_id = PHYSICAL_DB, table_prefix = TABLE_PREFIX})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("APP_JOURNEY_FAILED", {error = tostring(err)})
        error(err)
    end
end}
