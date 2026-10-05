-- MIT. The migrations create the Threads schema in the node database and its
-- constraints hold what the authority relies on.
local test = require("test")
local sql = require("sql")
local harness = require("harness")

local TABLES = {"bee_thread_actions", "bee_thread_app_alias", "bee_thread_attempts", "bee_thread_inbox_epochs", "bee_thread_inbox_items",
    "bee_thread_inbox_outbox", "bee_thread_inbox_rules", "bee_thread_carrier_events", "bee_thread_carriers", "bee_thread_cancel_intents",
    "bee_thread_claim_batches", "bee_thread_commands", "bee_thread_deliveries", "bee_thread_dispatches", "bee_thread_heads", "bee_thread_members",
    "bee_thread_notices", "bee_thread_obligations", "bee_thread_owner", "bee_thread_projections", "bee_thread_records", "bee_thread_settlements",
    "bee_thread_subscription_pages", "bee_thread_subscriptions", "bee_thread_turns"}

table.sort(TABLES)

-- The Sessions journal Threads keeps for the Sessions owner.
local SESSION_TABLES = {"bee_session_operations", "bee_session_turns", "bee_session_work", "bee_session_work_cancellations", "bee_sessions"}

local function refused(db: sql.DB, statement: string, params: {unknown}): boolean
    local _, err = db:execute(statement, params)
    return err ~= nil
end

local function define_tests()
    test.describe("Threads schema", function()
        test.it("creates every table in the node database", function()
            local db = harness.open()
            local rows = harness.query(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'bee_thread_%' ORDER BY name")
            db:release()
            local found: {string} = {}
            for _, row in ipairs(rows) do found[#found + 1] = tostring(row.name) end
            test.eq(table.concat(found, ","), table.concat(TABLES, ","))
        end)

        test.it("creates the Sessions journal tables in the node database", function()
            local db = harness.open()
            local rows = harness.query(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'bee_session%' ORDER BY name")
            db:release()
            local found: {string} = {}
            for _, row in ipairs(rows) do found[#found + 1] = tostring(row.name) end
            test.eq(table.concat(found, ","), table.concat(SESSION_TABLES, ","))
        end)

        test.it("keeps one active owner per thread and one record per sequence", function()
            local db = harness.open()
            local thread_id = "schema-" .. harness.key()
            harness.execute(db, "INSERT INTO bee_thread_heads (thread_id, owner_actor, title, state, revision, head_sequence, created_at) VALUES (?, 'a', 't', 'open', 1, 0, 'now')", {thread_id})
            harness.execute(db, "INSERT INTO bee_thread_members (thread_id, actor, role, revision, active) VALUES (?, 'a', 'owner', 1, 1)", {thread_id})
            test.is_true(refused(db, "INSERT INTO bee_thread_members (thread_id, actor, role, revision, active) VALUES (?, 'b', 'owner', 1, 1)", {thread_id}))
            harness.execute(db, "INSERT INTO bee_thread_members (thread_id, actor, role, revision, active) VALUES (?, 'b', 'owner', 1, 0)", {thread_id})
            local record = "INSERT INTO bee_thread_records (record_id, thread_id, sequence, schema_revision, kind, producer_id, source, record_json, committed_at) " ..
                "VALUES (?, ?, ?, 'bee.thread-record@1', ?, 'p', 'bee', '{}', 'now')"
            harness.execute(db, record, {"r-" .. harness.key(), thread_id, 1, "message"})
            test.is_true(refused(db, record, {"r-" .. harness.key(), thread_id, 1, "message"}))
            test.is_true(refused(db, record, {"r-" .. harness.key(), thread_id, 2, "unknown.kind"}))
            db:release()
        end)

        test.it("accepts any workspace identifier up to the identifier bound and nothing longer", function()
            local db = harness.open()
            local insert = "INSERT INTO bee_thread_heads (thread_id, owner_actor, title, state, revision, head_sequence, created_at, workspace_id) VALUES (?, 'a', 't', 'open', 1, 0, 'now', ?)"
            harness.execute(db, insert, {"schema-" .. harness.key(), "0199c4a0-0000-7000-8000-000000000001"})
            test.is_true(refused(db, insert, {"schema-" .. harness.key(), ""}))
            test.is_true(refused(db, insert, {"schema-" .. harness.key(), string.rep("w", 161)}))
            db:release()
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
