-- SPDX-License-Identifier: MIT
local test = require("test")
local migrations = require("migrations")
local ledger = require("ledger")
local persist = require("persist")
local database = require("database")
local function define_tests()
    test.describe("Sync upgrades from main", function()
        test.it("preserves applied checksums and distribution progress through the profile migrations", function()
            local expected: {string} = {
                "7e729debcf4bd573cf29965b0da6f0e9be4a9f60eaaa6ccf788cfb79820aa11a",
                "d8419d5920c9eccf315cb4f0766362109145e74f2b1cc3b63028ad78c668ba21",
                "b828e59603d4d5165e3d289f748a84da1dce319cc0b392af68e44dd1cf7cebd3",
                "3225e422d2bcb78940544cc868c426859d65bc11bbc1e2136c56af988237f288",
            }
            local all = migrations.all()
            local applied: {migrations.Migration} = {}
            for index, value in ipairs(expected) do
                local checksum, err = ledger.checksum(all[index])
                test.is_nil(err)
                test.eq(checksum, value)
                applied[index] = all[index]
            end
            local db = assert(persist.open({resource = "bee.sync:migration_test_db", ledger = database.LEDGER, migrations = applied}))
            local _, insert_error = db:execute("INSERT INTO bee_sync_distribution_cursors VALUES (?, ?, ?, ?)", {"source", "feed", "destination", 7})
            test.is_nil(insert_error)
            db:release()
            local upgraded = assert(database.open("bee.sync:migration_test_db"))
            local rows = assert(upgraded:query("SELECT cursor FROM bee_sync_distribution_cursors WHERE source_owner = ?", {"source"}))
            test.eq(rows[1].cursor, 7)
            test.eq(#assert(ledger.rows(upgraded, database.LEDGER)), 11)
            upgraded:release()
        end)
    end)
end
return test.run_cases(define_tests)
