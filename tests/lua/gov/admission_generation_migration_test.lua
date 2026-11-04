-- MIT. An activation recorded under the retired admission generation reads as
-- the current one after the forward migration; its other columns stay.
local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local DATABASE = "bee.tests.gov:admission_generation_db"
local ID = "bee.gov.migrations:admission_generation"

local function define_tests()
    test.describe("admission generation migration", function()
        test.it("records every activation under the current admission generation", function()
            local db = assert(sql.get(DATABASE))
            assert(db:execute("DROP TABLE IF EXISTS _migrations"))
            assert(db:execute("DROP TABLE IF EXISTS bee_governance_activation_intents"))
            assert(db:execute([[CREATE TABLE bee_governance_activation_intents (intent_id TEXT PRIMARY KEY, overlay_owner TEXT NOT NULL,
                application_admission_generation TEXT NOT NULL DEFAULT 'current' CHECK(application_admission_generation IN ('current', 'prior')))]]))
            assert(db:execute("INSERT INTO bee_governance_activation_intents VALUES ('old', 'bee.governance.workspace_applications:w.todo', 'prior')"))
            assert(db:execute("INSERT INTO bee_governance_activation_intents VALUES ('new', 'bee.gov.apps:w.todo', 'current')"))
            local reply, err = funcs.call(ID, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = ID})
            assert(not err, tostring(err))
            assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
            local rows = assert(db:query("SELECT intent_id, overlay_owner, application_admission_generation AS generation FROM bee_governance_activation_intents ORDER BY intent_id"))
            test.eq(#rows, 2)
            test.eq(rows[1].intent_id, "new")
            test.eq(rows[1].generation, "current")
            test.eq(rows[2].intent_id, "old")
            test.eq(rows[2].generation, "current")
            test.eq(rows[2].overlay_owner, "bee.governance.workspace_applications:w.todo")
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
