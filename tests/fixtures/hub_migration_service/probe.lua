-- MIT. Real facade, private worker, dependency publication and migration ledger.
local funcs = require("funcs")
local registry = require("registry")
local logger = require("logger")
local sql = require("sql")
local function call(operation, request, digest)
    local reply, err = funcs.call("bee.hub:call", {operation = operation, request = request, expected_digest = digest})
    assert(not err, tostring(err))
    assert(type(reply) == "table", "no facade reply")
    return reply
end
local function apply(request)
    local planned = call("plan", request)
    assert(planned.ok, "plan: " .. tostring(planned.message))
    local result = call("apply", request, planned.value.digest)
    return result, planned.value.digest
end
local function complete(result)
    assert(result.ok and result.value.state == "complete", "apply: " .. tostring(result.code) .. " " .. tostring(result.message or (result.value and result.value.message)))
end
local function run(mode)
    local installed, digest = apply({action = "install", component = "acme/app", version = "1.0.0", migration_policy = mode == "applied" and "up" or "none"})
    complete(installed)
    if mode == "applied" then
        assert(#installed.value.migration_work.rows == 1 and installed.value.migration_work.rows[1].status == "applied", "no verified migration result")
        local replay = call("apply", {action = "install", component = "acme/app", version = "1.0.0", migration_policy = "up"}, digest)
        complete(replay); assert(replay.replayed, "completed install did not replay")
    end
    local revision = assert(registry.snapshot()):version():id()
    local removed = apply({action = "uninstall", component = "acme/app"})
    if mode == "absent" then complete(removed)
    else
        local code = mode == "applied" and "BLOCKED" or "UNAVAILABLE"
        assert(not removed.ok and removed.code == code, "removal: " .. tostring(removed.code) .. " " .. tostring(removed.message))
        assert(assert(registry.snapshot()):version():id() == revision, "refused removal published changes")
        complete(apply({action = "uninstall", component = "acme/app", migration_policy = "leave"}))
    end
    local status = call("status", nil, digest)
    complete(status)
    logger:info("HUB_MIGRATION_SERVICE_PASS " .. mode)
end
local function crash()
    apply({action = "install", component = "acme/app", version = "1.0.0", migration_policy = "up"})
    error("crash injection did not stop publication")
end
local function recover(tamper)
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    local receipt
    for _, entry in ipairs(state.entries) do
        if entry.id:sub(1, 19) == "bee.hub.operations:" then
            assert(not receipt, "multiple interrupted receipts")
            receipt = entry.data
        end
    end
    assert(receipt and receipt.state == "published", "no interrupted migration receipt")
    assert(#receipt.migration_work.entries == 1 and #receipt.migration_work.rows == 0, "migration work was not captured before execution")
    if tamper then
        -- A separately admitted test operator changes a published definition.
        local stored = assert(snapshot:get("acme.storage:first"))
        stored.data.source = stored.data.source .. "\n-- changed after interrupted install\n"
        local changes = assert(snapshot:changes())
        assert(changes:update({id = stored.id, kind = stored.kind, meta = stored.meta, data = stored.data}))
        assert(changes:apply())
    end
    local result = call("apply", receipt.request, receipt.digest)
    if tamper then
        assert(result.ok and result.replayed and result.value.state == "recovery_required", "changed definition was accepted")
        assert(result.value.message:find("definition digest differs", 1, true), "unexpected definition refusal: " .. tostring(result.value.message))
        assert(#result.value.migration_work.rows == 0, "changed definition recorded migration completion")
        logger:info("HUB_MIGRATION_SERVICE_PASS tamper")
        return
    end
    complete(result)
    assert(result.replayed and result.value.migration_work.rows[1].reason == "already_applied", "recovery did not reconcile committed ledger")
    logger:info("HUB_MIGRATION_SERVICE_PASS crash")
end
local function partial()
    local request = {action = "install", component = "acme/app", version = "1.1.0", migration_policy = "up"}
    local result, digest = apply(request)
    assert(result.ok and result.value.state == "recovery_required", "partial failure was not retained")
    assert(#result.value.migration_work.rows == 1 and result.value.migration_work.rows[1].status == "applied", "partial result lost committed migration")
    local status = call("status", nil, digest)
    assert(status.value.state == "recovery_required" and #status.value.migration_work.rows == 1, "partial receipt was not durable")
    -- Supply the external prerequisite, leaving both migration definitions unchanged.
    local db = assert(sql.get("probe:db"))
    assert(db:execute("CREATE TABLE fixture_gate (ready INTEGER)"))
    db:release()
    local recovered = call("apply", request, digest)
    complete(recovered)
    local rows = recovered.value.migration_work.rows
    assert(recovered.replayed and #rows == 2 and rows[1].reason == "already_applied" and rows[2].status == "applied", "partial replay did not reconcile the first commit")
    logger:info("HUB_MIGRATION_SERVICE_PASS partial")
end
local function linked()
    local request = {action = "install", component = "acme/app", version = "1.2.0", migration_policy = "up",
        parameters = {{name = "acme.storage:target_db", value = "probe:db"}}}
    local planned = call("plan", request)
    assert(planned.ok, "linked plan: " .. tostring(planned.message))
    assert(planned.value.migrations[1].target_db == "probe:db", "plan did not use selected migration database")
    local result = call("apply", request, planned.value.digest)
    complete(result)
    assert(result.value.migration_work.entries[1].target_db == "probe:db", "receipt did not capture selected database")
    logger:info("HUB_MIGRATION_SERVICE_PASS linked")
end
local function rollback()
    complete(apply({action = "install", component = "acme/app", version = "1.0.0", migration_policy = "up"}))
    local request = {action = "uninstall", component = "acme/app", migration_policy = "down"}
    local planned = call("plan", request)
    assert(planned.ok and #planned.value.migrations == 1 and planned.value.migrations[1].component == "acme/storage", "removal review omitted orphan migration")
    local digest = planned.value.digest
    local result = call("apply", request, digest)
    complete(result)
    assert(result.value.removal.published and result.value.migration_work.rows[1].status == "reverted", "rollback was not verified")
    assert(#call("installed").value.modules == 0, "orphaned dependency remains installed")
    local revision = assert(registry.snapshot()):version():id()
    complete(call("apply", request, digest))
    assert(assert(registry.snapshot()):version():id() == revision, "completed rollback replay wrote registry")
    logger:info("HUB_MIGRATION_SERVICE_PASS rollback")
end
local function rollback_partial()
    complete(apply({action = "install", component = "acme/app", version = "1.3.0", migration_policy = "up"}))
    local request = {action = "uninstall", component = "acme/app", migration_policy = "down"}
    local result, digest = apply(request)
    assert(result.ok and result.value.state == "recovery_required" and not result.value.removal.published, "partial rollback lost recovery phase")
    local rows = result.value.migration_work.rows
    assert(#rows == 1 and rows[1].id == "acme.storage:second" and rows[1].status == "reverted", "rollback order or partial result is wrong")
    assert(#call("installed").value.modules == 2, "partial rollback removed definitions")
    local status = call("status", nil, digest)
    assert(status.value.migration_work.rows[1].id == "acme.storage:second", "partial rollback receipt was not durable")
    local db = assert(sql.get("probe:db"))
    assert(db:execute("CREATE TABLE fixture_rollback_gate (ready INTEGER)"))
    db:release()
    local resumed = call("apply", request, digest)
    complete(resumed)
    assert(resumed.replayed and #resumed.value.migration_work.rows == 2, "partial rollback did not recover")
    for _, row in ipairs(resumed.value.migration_work.rows) do
        if row.id == "acme.storage:second" then assert(row.reason == "not_applied", "recovery reran reverted migration")
        else assert(row.status == "reverted", "recovery did not revert remaining migration") end
    end
    assert(#call("installed").value.modules == 0, "recovered rollback did not remove orphans")
    logger:info("HUB_MIGRATION_SERVICE_PASS rollback_partial")
end
local function rollback_recover(published, tamper)
    local listing = call("status", {page = 1})
    assert(listing.ok and #listing.value.operations == 2, "missing interrupted removal receipt")
    local receipt = listing.value.operations[1]
    assert(receipt.action == "uninstall" and receipt.removal.published == published, "wrong removal phase after restart")
    if tamper then
        local snapshot = assert(registry.snapshot())
        local stored = assert(snapshot:get("acme.storage:first"))
        stored.data.source = stored.data.source .. "\n-- changed after rollback interruption\n"
        local changes = assert(snapshot:changes())
        assert(changes:update({id = stored.id, kind = stored.kind, meta = stored.meta, data = stored.data}))
        assert(changes:apply())
    end
    local result = call("apply", receipt.request, receipt.digest)
    if tamper then
        assert(result.ok and result.value.state == "recovery_required" and result.value.message:find("definition digest differs", 1, true), "changed rollback definition accepted")
        assert(#call("installed").value.modules == 2, "refused rollback removed definitions")
        logger:info("HUB_MIGRATION_SERVICE_PASS rollback_tamper")
        return
    end
    complete(result)
    assert(result.replayed and #call("installed").value.modules == 0, "interrupted rollback did not finish removal")
    if not published then assert(result.value.migration_work.rows[1].reason == "not_applied", "restart reran reverted migration") end
    logger:info("HUB_MIGRATION_SERVICE_PASS " .. (published and "rollback_published" or "rollback_crash"))
end
local function history()
    for _ = 1, 13 do
        complete(apply({action = "install", component = "acme/app", version = "1.0.0"}))
        complete(apply({action = "uninstall", component = "acme/app"}))
    end
    local revision = assert(registry.snapshot()):version():id()
    local first = call("status", {page = 1})
    local second = call("status", {page = 2})
    assert(first.ok and second.ok, "operation history unavailable")
    assert(first.value.total == 26 and first.value.page_size == 25 and #first.value.operations == 25, "history first page is incomplete")
    assert(second.value.page == 2 and #second.value.operations == 1, "history second page is incomplete")
    assert(first.value.operations[25].baseline_revision > second.value.operations[1].baseline_revision, "operation history order is unstable")
    local latest = first.value.operations[1]
    assert(latest.request.action == "uninstall" and latest.request.version == nil and latest.request.parameters == nil, "stored uninstall request is not callable")
    complete(call("apply", latest.request, latest.digest))
    assert(not call("status", {page = 0}).ok, "invalid history page accepted")
    assert(not call("status", false).ok, "non-object history request accepted")
    assert(not call("status", {page = 1}, first.value.operations[1].digest).ok, "mixed history and exact lookup accepted")
    assert(assert(registry.snapshot()):version():id() == revision, "reading history or replaying completed work changed registry")
    logger:info("HUB_MIGRATION_SERVICE_PASS history")
end
local function other_actor()
    local history = call("status", {page = 1})
    assert(history.ok and history.value.total == 0 and #history.value.operations == 0, "history leaked another actor's operations")
    local state = assert(assert(registry.snapshot()):state())
    for _, entry in ipairs(state.entries) do
        if entry.id:sub(1, 19) == "bee.hub.operations:" then
            local denied = call("status", nil, entry.data.digest)
            assert(not denied.ok and denied.code == "DENIED", "foreign receipt was disclosed")
            logger:info("HUB_OPERATION_HISTORY_ACTOR_PASS")
            return
        end
    end
    error("no foreign operation available for actor test")
end
return {rollback_partial = rollback_partial, rollback = rollback, rollback_crash = rollback, rollback_published = rollback, rollback_tamper = rollback,
    rollback_recover = function() rollback_recover(false, false) end,
    rollback_finish = function() rollback_recover(true, false) end,
    rollback_changed = function() rollback_recover(false, true) end,
    history = history, other_actor = other_actor, linked = linked, partial = partial, crash = crash, recover = function() recover(false) end, tamper = function() recover(true) end, absent = function() run("absent") end, applied = function() run("applied") end, denied = function() run("denied") end}
