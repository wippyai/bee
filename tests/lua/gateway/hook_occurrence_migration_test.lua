local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local DATABASE = "bee.tests.gateway:hook_occurrence_migration_db"
local function migrate(id: string)
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end
local function define_tests()
    test.describe("hook occurrence migration", function()
        test.it("keeps the session starts a session repeats per delivery, so a queued repeat commits as its own record", function()
            local db = assert(sql.get(DATABASE))
            assert(db:execute([[CREATE TABLE bee_gateway_hooks (event_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL, event TEXT NOT NULL,
                occurrence TEXT NOT NULL, ambiguous INTEGER NOT NULL, fields_json TEXT NOT NULL, status TEXT NOT NULL)]]))
            local rows = {
                {"compact", "SessionStart", "session:s1:compact", '{"event":"SessionStart","session_id":"s1","source":"compact"}', "queued"},
                {"resume", "SessionStart", "session:s1:resume", '{"event":"SessionStart","session_id":"s1","source":"resume"}', "committed"},
                {"startup", "SessionStart", "session:s1:startup", '{"event":"SessionStart","session_id":"s1","source":"startup"}', "committed"},
                {"end", "SessionEnd", "session:s1", '{"event":"SessionEnd","session_id":"s1","reason":"other"}', "committed"},
            }
            for _, row in ipairs(rows) do
                assert(db:execute("INSERT INTO bee_gateway_hooks VALUES (?, 'b', ?, ?, 0, ?, ?)", {row[1], row[2], row[3], row[4], row[5]}))
            end
            migrate("bee.gateway.migrations:session_start_occurrences")
            local stored = assert(db:query("SELECT event_id, occurrence, ambiguous, status FROM bee_gateway_hooks ORDER BY event_id"))
            local by: {[string]: {[string]: unknown}} = {}
            for _, item in ipairs(stored) do by[tostring(item.event_id)] = item end
            test.eq(by.compact.occurrence, "session:s1")
            test.eq(by.compact.ambiguous, 1)
            test.eq(by.compact.status, "queued", "the accepted delivery stays queued for its carrier")
            test.eq(by.resume.occurrence, "session:s1")
            test.eq(by.resume.ambiguous, 1)
            test.eq(by.startup.occurrence, "session:s1:startup")
            test.eq(by.startup.ambiguous, 0)
            test.eq(by["end"].occurrence, "session:s1")
            test.eq(by["end"].ambiguous, 0)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
