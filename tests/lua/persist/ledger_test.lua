-- SPDX-License-Identifier: MIT
local test = require("test")
local sql = require("sql")
local ledger = require("ledger")
local transaction = require("transaction")
local function open(): sql.DB
    return assert(sql.get("bee.persist:ledger_test_db"))
end
local function options(name: string, batch: boolean, timestamp: boolean, freshness: string?): ledger.Ledger
    return {table = name, label = "test", transaction = batch and "batch" or nil,
        applied_at = timestamp, freshness_table = freshness}
end
local function migrations(name: string): {ledger.Migration}
    return {
        {id = 1, name = "create", sql = "CREATE TABLE " .. name .. " (value TEXT NOT NULL); INSERT INTO " .. name .. " VALUES ('saved')"},
        {id = 2, name = "extend", sql = "ALTER TABLE " .. name .. " ADD COLUMN next TEXT"},
    }
end
local function define_tests()
    test.describe("SQLite result-code classification", function()
        test.it("uses primary busy and locked codes regardless of message text", function()
            for _, code in ipairs({5, 6}) do
                local err = errors.new({message = "writer refused", details = {sqlite_code = code, sqlite_extended_code = code + 256}})
                test.is_true(transaction.busy(err))
                test.eq(transaction.sql_failure(err, "commit").code, "BUSY")
            end
        end)
        test.it("keeps misleading text and non-SQLite failures internal", function()
            for _, err in ipairs({errors.new({message = "database locked", details = {sqlite_code = 19}}),
                errors.new("resource busy"), "database is locked"}) do
                test.is_false(transaction.busy(err))
                test.eq(transaction.sql_failure(err, "write").code, "INTERNAL")
            end
            test.is_false(transaction.busy(nil))
        end)
        test.it("preserves native SQLite constraint details and diagnostic text", function()
            local db = assert(sql.get("bee.persist:ledger_test_db"))
            assert(db:execute("CREATE TABLE busy_locked_constraint (value INTEGER UNIQUE)"))
            assert(db:execute("INSERT INTO busy_locked_constraint VALUES (1)"))
            local result, err = db:execute("INSERT INTO busy_locked_constraint VALUES (1)")
            test.is_nil(result)
            assert(err)
            test.eq(err:details().sqlite_code, 19)
            test.eq(err:details().sqlite_extended_code, 2067)
            local failure = transaction.sql_failure(err, "insert")
            test.eq(failure.code, "INTERNAL")
            test.contains(failure.message or "", "UNIQUE constraint failed")
            test.contains(failure.message or "", "insert:")
            assert(db:release())
        end)
    end)
    test.describe("Shared migration runner", function()
        test.it("opens a fresh batch and replays the timestamp-free legacy shape", function()
            local db = open()
            local config = options("client_ledger", true, false, nil)
            local expected = migrations("client_rows")
            assert(ledger.apply(db, config, {expected[1]}))
            local before = assert(ledger.rows(db, config))
            assert(ledger.apply(db, config, expected))
            test.eq(#assert(db:query("PRAGMA table_info(client_ledger)")), 3)
            test.eq(assert(ledger.rows(db, config))[1].checksum, before[1].checksum)
            test.eq(assert(db:query("SELECT value FROM client_rows"))[1].value, "saved")
            assert(ledger.apply(db, config, expected))
            test.eq(#assert(ledger.rows(db, config)), 2)
            db:release()
        end)
        test.it("rolls back an entire failed batch and recovers with the original list", function()
            local db = open()
            local config = options("batch_ledger", true, true, nil)
            local expected = migrations("batch_rows")
            local broken: {ledger.Migration} = {expected[1], {id = 2, name = "broken", sql = "INSERT INTO absent VALUES (1)"}}
            local ok, err = ledger.apply(db, config, broken)
            test.is_false(ok)
            test.contains(tostring(err), "apply test migration broken:")
            test.contains(tostring(err), "no such table: absent")
            test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE name IN ('batch_ledger', 'batch_rows')")), 0)
            assert(ledger.apply(db, config, expected))
            test.eq(#assert(ledger.rows(db, config)), 2)
            db:release()
        end)
        test.it("retains committed steps after a separate-step failure", function()
            local db = open()
            local config = options("step_ledger", false, true, nil)
            local expected = migrations("step_rows")
            local broken: {ledger.Migration} = {expected[1], {id = 2, name = "broken", sql = "INSERT INTO absent VALUES (1)"}}
            test.is_false(ledger.apply(db, config, broken))
            test.eq(#assert(ledger.rows(db, config)), 1)
            test.eq(assert(db:query("SELECT value FROM step_rows"))[1].value, "saved")
            assert(ledger.apply(db, config, expected))
            test.eq(#assert(ledger.rows(db, config)), 2)
            db:release()
        end)
        test.it("captures freshness before the batch and resets it on connection reuse", function()
            local db = open()
            local config = options("fresh_ledger", true, true, "fresh_run")
            local expected: {ledger.Migration} = {
                {id = 1, name = "capture", sql = "CREATE TABLE freshness (fresh INTEGER); INSERT INTO freshness SELECT fresh FROM temp.fresh_run"},
                {id = 2, name = "capture_again", sql = "INSERT INTO freshness SELECT fresh FROM temp.fresh_run"},
            }
            assert(ledger.apply(db, config, expected))
            local rows = assert(db:query("SELECT fresh FROM freshness"))
            test.eq(rows[1].fresh, 1); test.eq(rows[2].fresh, 1)
            assert(ledger.apply(db, config, expected))
            test.eq(assert(db:query("SELECT fresh FROM temp.fresh_run"))[1].fresh, 0)
            test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE name = 'fresh_run'")), 0)
            db:release()
        end)
        test.it("reports an old database as nonfresh through its pending upgrade", function()
            local db = open()
            local config = options("old_ledger", true, true, "old_run")
            local expected: {ledger.Migration} = {
                {id = 1, name = "capture", sql = "CREATE TABLE old_freshness (fresh INTEGER); INSERT INTO old_freshness SELECT fresh FROM temp.old_run"},
                {id = 2, name = "upgrade", sql = "INSERT INTO old_freshness SELECT fresh FROM temp.old_run"},
            }
            assert(ledger.apply(db, config, {expected[1]}))
            assert(ledger.apply(db, config, expected))
            local rows = assert(db:query("SELECT fresh FROM old_freshness"))
            test.eq(rows[1].fresh, 1); test.eq(rows[2].fresh, 0)
            db:release()
        end)
        test.it("upgrades a nine-applied workspace ledger with an immutable shipped SQL variant", function()
            local db = open()
            local config: ledger.Ledger = {table = "workspace_schema_migrations", label = "workspace",
                transaction = "batch", freshness_table = "workspace_migration_run"}
            local expected: {ledger.Migration} = {}
            for id = 1, 12 do
                expected[id] = {id = id, name = "workspace_" .. tostring(id),
                    sql = id == 1 and "CREATE TABLE workspace_history (revision INTEGER); INSERT INTO workspace_history VALUES (1)"
                        or "INSERT INTO workspace_history VALUES (" .. tostring(id) .. ")"}
            end
            local original: {ledger.Migration} = {}
            for id = 1, 9 do original[id] = expected[id] end
            original[9] = {id = 9, name = expected[9].name, sql = "INSERT INTO workspace_history VALUES (9); SELECT 1"}
            assert(ledger.apply(db, config, original))
            local before = assert(ledger.rows(db, config))
            expected[9].historical_sql = {original[9].sql}
            assert(ledger.apply(db, config, expected))
            local after = assert(ledger.rows(db, config))
            test.eq(#after, 12)
            for id = 1, 9 do test.eq(after[id].checksum, before[id].checksum) end
            test.eq(#assert(db:query("SELECT revision FROM workspace_history")), 12)
            test.eq(assert(db:query("SELECT fresh FROM temp.workspace_migration_run"))[1].fresh, 0)
            assert(ledger.apply(db, config, expected))
            assert(db:execute("UPDATE workspace_schema_migrations SET checksum = 'unknown' WHERE id = 9"))
            local ok, err = ledger.apply(db, config, expected)
            test.is_false(ok); test.contains(tostring(err), "checksum changed")
            db:release()
        end)
        test.it("rejects changed checksums before applying pending SQL", function()
            local db = open()
            local config = options("checksum_ledger", true, true, nil)
            local expected = migrations("checksum_rows")
            assert(ledger.apply(db, config, {expected[1]}))
            assert(db:execute("UPDATE checksum_ledger SET checksum = 'changed'"))
            local ok, err = ledger.apply(db, config, expected)
            test.is_false(ok)
            test.eq(err, "test migration 1 (create) checksum changed: expected " .. assert(ledger.checksum(expected[1])) .. ", found changed")
            test.eq(#assert(db:query("PRAGMA table_info(checksum_rows)")), 1)
            db:release()
        end)
        test.it("rejects invalid freshness and batch rebuild configuration before writing", function()
            local db = open()
            local expected = migrations("invalid_rows")
            test.is_false(ledger.apply(db, options("invalid_ledger", false, true, "run"), expected))
            test.is_false(ledger.apply(db, options("invalid_ledger", true, true, "run; DROP TABLE x"), expected))
            expected[1].rebuild = true
            test.is_false(ledger.apply(db, options("invalid_ledger", true, true, nil), expected))
            test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE name = 'invalid_ledger'")), 0)
            db:release()
        end)
        test.it("preserves the native ledger read failure", function()
            local db = open()
            local rows, err = ledger.rows(db, options("absent_ledger", true, true, nil))
            test.is_nil(rows)
            test.contains(tostring(err), "read test migration ledger:")
            test.contains(tostring(err), "no such table: absent_ledger")
            db:release()
        end)
        for _, batch in ipairs({false, true}) do
            test.it("appends rollback failure after SQLite aborts a " .. (batch and "batch" or "step"), function()
                local db = open()
                local name = batch and "abort_batch" or "abort_step"
                local config = options(name .. "_ledger", batch, true, nil)
                local broken: {ledger.Migration} = {{id = 1, name = "abort", sql =
                    "CREATE TABLE " .. name .. " (value INTEGER); CREATE TRIGGER " .. name .. "_trigger BEFORE INSERT ON " .. name ..
                    " BEGIN SELECT RAISE(ROLLBACK, 'native migration abort'); END; INSERT INTO " .. name .. " VALUES (1)"}}
                local ok, err = ledger.apply(db, config, broken)
                test.is_false(ok)
                test.contains(tostring(err), "apply test migration abort:")
                test.contains(tostring(err), "native migration abort")
                test.contains(tostring(err), "; rollback migration:")
                test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE name = ?", {name})), 0)
                db:release()
            end)
        end
        test.it("preserves a deferred constraint commit failure and its rollback error", function()
            local db = open()
            assert(db:execute("PRAGMA foreign_keys = ON"))
            local config = options("commit_ledger", true, true, nil)
            local broken: {ledger.Migration} = {{id = 1, name = "deferred", sql = [[
CREATE TABLE commit_parent (id INTEGER PRIMARY KEY);
CREATE TABLE commit_child (parent_id INTEGER REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED);
INSERT INTO commit_child VALUES (1)
]]}}
            local ok, err = ledger.apply(db, config, broken)
            test.is_false(ok)
            test.contains(tostring(err), "commit test migration:")
            test.contains(tostring(err), "FOREIGN KEY constraint failed")
            test.contains(tostring(err), "; rollback migration:")
            test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE name = 'commit_child'")), 0)
            db:release()
        end)
        test.it("restores foreign keys after a rebuild statement failure", function()
            local db = open()
            assert(db:execute("PRAGMA foreign_keys = ON"))
            local broken: {ledger.Migration} = {{id = 1, name = "rebuild", rebuild = true, sql = "INSERT INTO absent_rebuild VALUES (1)"}}
            local ok, err = ledger.apply(db, options("rebuild_ledger", false, true, nil), broken)
            test.is_false(ok)
            test.contains(tostring(err), "apply test migration rebuild:")
            test.contains(tostring(err), "no such table: absent_rebuild")
            test.eq(assert(db:query("PRAGMA foreign_keys"))[1].foreign_keys, 1)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
