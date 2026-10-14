local test = require("test")
local store = require("store")
local supervision = require("supervision")
local native_fixture = require("native_fixture")
local function cases()
    test.describe("Terminal completion backlog", function()
        test.it("does not poll for a process-group completion event the runtime cannot supply", function()
            local attempt = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.launch({"sh", "-c", "true"}, "process_group")))
            local db = assert(store.open())
            local ok, problem = pcall(function()
                assert(db:execute("UPDATE bee_placement_attempts SET execution_state = 'exited' WHERE attempt_id = ?", {attempt.attempt_id}))
                local rows = assert(supervision.rows(db, "native", 10000))
                local found = false
                for _, row in ipairs(rows) do if row.attempt_id == attempt.attempt_id then found = true end end
                test.is_false(found, "terminal exit must not schedule process-group scans")
                assert(store.transition(db, attempt.attempt_id, {evidence = {kind = "workdir_preparers.settled", detail = "test proof"}}).ok)
                for _, row in ipairs(assert(supervision.rows(db, "native", 10000))) do
                    test.is_false(row.attempt_id == attempt.attempt_id, "settled attempt is still pending")
                end
            end)
            assert(db:execute("UPDATE bee_placement_attempts SET cleanup_state = 'complete' WHERE attempt_id = ?", {attempt.attempt_id}))
            db:release()
            if not ok then error(tostring(problem)) end
        end)
    end)
end
return {run = native_fixture.suite(cases)}
