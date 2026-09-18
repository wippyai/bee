-- MIT. A gateway store populated under the shipped migrations upgrades in
-- place: bindings keep their identity and their tokens as credential
-- generation 1, the listener gains an empty secret that proves nothing
-- until the next open, and the ledger refuses a downgrade.
local test = require("test")
local sql = require("sql")
local hash = require("hash")
local persist = require("persist")
local migrations = require("migrations")
local gateway = require("gateway")
local RESOURCE = "bee.gateway:upgrade_db"
type Row = {[string]: unknown}
local function reset()
    local db, err = sql.get(RESOURCE)
    if not db then error("upgrade store: " .. tostring(err)) end
    for _, statement in ipairs({"DROP TABLE IF EXISTS bee_gateway_credentials", "DROP TABLE IF EXISTS bee_gateway_bindings", "DROP TABLE IF EXISTS bee_gateway_bindings_next",
        "DROP TABLE IF EXISTS bee_gateway_listener", "DROP TABLE IF EXISTS " .. gateway.LEDGER.table}) do
        local _, drop_error = db:execute(statement)
        if drop_error then db:release(); error(statement .. ": " .. tostring(drop_error)) end
    end
    db:release()
end
local function open_with(count: integer): sql.DB
    local all = migrations.all()
    local subset: {migrations.Migration} = {}
    for index = 1, count do subset[index] = all[index] end
    local db, err = persist.open({resource = RESOURCE, ledger = gateway.LEDGER, migrations = subset})
    if not db then error("open with " .. tostring(count) .. " migrations: " .. tostring(err)) end
    return db
end
local function one(db: sql.DB, statement: string, args: {unknown}?): Row
    local rows, err = db:query(statement, args or {})
    if err or not rows or #rows ~= 1 then error(statement .. ": " .. tostring(err or ("rows " .. tostring(rows and #rows)))) end
    return rows[1] :: Row
end
local function define_tests()
    test.describe("Gateway store upgrade", function()
        test.it("carries bindings and their tokens across the credentials migration and refuses a downgrade", function()
            reset()
            local shipped = open_with(2)
            local token_hash = hash.sha256("an-earlier-token")
            local _, listener_error = shipped:execute("INSERT INTO bee_gateway_listener (singleton, epoch, address, drained, opened_at, drain_deadline_at) VALUES (1, 4, '127.0.0.1:18790', 0, '2026-09-09T00:00:00.000Z', NULL)")
            if listener_error then error(listener_error) end
            local _, binding_error = shipped:execute([[INSERT INTO bee_gateway_bindings (binding_id, token_hash, subject, action_id, attempt_id, thread_id, owner_incarnation, tools_json, epoch, expires_at, revoked_at, idempotency_key, request_digest, created_at)
                VALUES ('binding-1', ?, 'bee.owner', 'act-1', 'attempt-1', 'thread-1', 1, '["thread_read"]', 4, '2099-01-01T00:00:00.000Z', NULL, 'key-1', 'digest-1', '2026-09-09T00:00:00.000Z')]], {token_hash})
            if binding_error then error(binding_error) end
            local _, revoked_error = shipped:execute([[INSERT INTO bee_gateway_bindings (binding_id, token_hash, subject, action_id, attempt_id, thread_id, owner_incarnation, tools_json, epoch, expires_at, revoked_at, idempotency_key, request_digest, created_at)
                VALUES ('binding-2', 'other-hash', 'bee.owner', 'act-2', 'attempt-2', 'thread-1', 1, '["thread_read"]', 3, '2099-01-01T00:00:00.000Z', '2026-09-09T01:00:00.000Z', NULL, NULL, '2026-09-09T00:00:00.000Z')]])
            if revoked_error then error(revoked_error) end
            shipped:release()
            local upgraded = open_with(7)
            local ledger = one(upgraded, "SELECT COUNT(*) AS applied FROM " .. gateway.LEDGER.table)
            test.eq(tonumber(ledger.applied), 7)
            local listener = one(upgraded, "SELECT epoch, secret, drained FROM bee_gateway_listener WHERE singleton = 1")
            test.eq(tonumber(listener.epoch), 4)
            test.eq(listener.secret, "")
            local binding = one(upgraded, "SELECT carrier_epoch, credential_generation, epoch, revoked_at FROM bee_gateway_bindings WHERE binding_id = 'binding-1'")
            test.eq(tonumber(binding.carrier_epoch), 0)
            test.eq(tonumber(binding.credential_generation), 1)
            test.eq(tonumber(binding.epoch), 4)
            test.is_nil(binding.revoked_at)
            local credential = one(upgraded, "SELECT generation, token_hash, revoked_at, presented_count, last_presented_at, kind FROM bee_gateway_credentials WHERE binding_id = 'binding-1'")
            test.eq(tonumber(credential.generation), 1)
            test.eq(credential.kind, "tool")
            local hooks_column = one(upgraded, "SELECT hooks_json FROM bee_gateway_bindings WHERE binding_id = 'binding-1'")
            test.eq(hooks_column.hooks_json, "[]")
            local queue = one(upgraded, "SELECT COUNT(*) AS queued FROM bee_gateway_hooks")
            test.eq(tonumber(queue.queued), 0)
            local intake_columns, intake_error = upgraded:query("SELECT name FROM pragma_table_info('bee_gateway_hooks') WHERE name IN ('claimed_epoch', 'rejected_reason')")
            if intake_error or not intake_columns then error(tostring(intake_error)) end
            test.eq(#intake_columns, 2)
            test.eq(credential.token_hash, token_hash)
            test.is_nil(credential.revoked_at)
            test.eq(tonumber(credential.presented_count), 0)
            test.is_nil(credential.last_presented_at)
            local authorization = one(upgraded, "SELECT materialization_key_hash, materialization_expires_at FROM bee_gateway_bindings WHERE binding_id = 'binding-1'")
            test.is_nil(authorization.materialization_key_hash)
            test.is_nil(authorization.materialization_expires_at)
            local retired = one(upgraded, "SELECT revoked_at FROM bee_gateway_credentials WHERE binding_id = 'binding-2'")
            test.eq(retired.revoked_at, "2026-09-09T01:00:00.000Z")
            local columns, columns_error = upgraded:query("SELECT name FROM pragma_table_info('bee_gateway_bindings') WHERE name = 'token_hash'")
            if columns_error or not columns then error(tostring(columns_error)) end
            test.eq(#columns, 0)
            upgraded:release()
            -- The proof refuses an upgraded listener until open mints its secret.
            local _, unopened = gateway.proof("", {epoch = 4, restarts = 0}, "nonce")
            test.eq(unopened, "the listener has not been opened since the store gained its secret")
            local downgraded, downgrade_error = persist.open({resource = RESOURCE, ledger = gateway.LEDGER, migrations = {migrations.all()[1], migrations.all()[2]}})
            test.is_nil(downgraded)
            test.eq(downgrade_error, "gateway database schema is newer")
            local again = open_with(7)
            local same = one(again, "SELECT token_hash FROM bee_gateway_credentials WHERE binding_id = 'binding-1'")
            test.eq(same.token_hash, token_hash)
            again:release()
            -- Native discovery must not rotate existing credentials or erase
            -- a host's drain decision while upgrading a populated store.
            local native = open_with(8)
            local retained = one(native, "SELECT epoch, address, secret, drained, native_key FROM bee_gateway_listener WHERE singleton = 1")
            test.eq(tonumber(retained.epoch), 4)
            test.eq(retained.address, "127.0.0.1:18790")
            test.eq(retained.secret, "")
            test.eq(tonumber(retained.drained), 0)
            test.is_nil(retained.native_key)
            local preserved = one(native, "SELECT token_hash, generation FROM bee_gateway_credentials WHERE binding_id = 'binding-1'")
            test.eq(preserved.token_hash, token_hash)
            test.eq(tonumber(preserved.generation), 1)
            local _, mark_error = native:execute("UPDATE bee_gateway_listener SET native_key = 'native-execution-1', drained = 1 WHERE singleton = 1")
            if mark_error then error(mark_error) end
            native:release()
            local reopened = open_with(8)
            local unchanged = one(reopened, "SELECT epoch, native_key, drained FROM bee_gateway_listener WHERE singleton = 1")
            test.eq(tonumber(unchanged.epoch), 4)
            test.eq(unchanged.native_key, "native-execution-1")
            test.eq(tonumber(unchanged.drained), 1)
            test.eq(tonumber(one(reopened, "SELECT COUNT(*) AS applied FROM " .. gateway.LEDGER.table).applied), 8)
            reopened:release()
        end)
    end)
end
return require("test").run_cases(define_tests)
