-- SPDX-License-Identifier: MIT
local test = require("test")
local transaction = require("transaction")
local sql = require("sql")
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
end
return test.run_cases(define_tests)
