-- SPDX-License-Identifier: MIT
local test = require("test")
local sql = require("sql")
local ledger = require("ledger")
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
            local ok = ledger.apply(db, config, broken)
            test.is_false(ok)
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
        test.it("rejects changed checksums before applying pending SQL", function()
            local db = open()
            local config = options("checksum_ledger", true, true, nil)
            local expected = migrations("checksum_rows")
            assert(ledger.apply(db, config, {expected[1]}))
            assert(db:execute("UPDATE checksum_ledger SET checksum = 'changed'"))
            local ok, err = ledger.apply(db, config, expected)
            test.is_false(ok); test.contains(tostring(err), "checksum changed")
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
    end)
end
return test.run_cases(define_tests)
