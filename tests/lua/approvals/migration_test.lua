local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local M = {}
local DATABASE = "bee.approvals:migration_test_db"
local function migrate(name: string)
    local id = "bee.approvals.migrations:" .. name
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end
function M.run()
    test.describe("universal approval migration", function()
        test.it("preserves legacy identities, digests, decisions and receipts without extending authority", function()
            migrate("approvals")
            migrate("complete")
            local db = assert(sql.get(DATABASE))
            local _, insert_error = db:execute([[INSERT INTO bee_approval_requests
                (approval_id,owner_node,owner_incarnation,workspace_id,requester_id,requester_key,request_digest,
                request_kind,policy,proposal_json,proposal_digest,prompt_json,response_schema_json,revision,state,
                decision,decider_id,decided_at,consumer_id,consumed_effect,consumed_at,expires_ms,expires_at,
                created_at,updated_at,effect_completed_at,effect_result_json)
                VALUES ('legacy-id','node',1,'workspace','requester','legacy-key',?,'permission','policy',?,?,
                '{"text":"Legacy"}','{}',2,'decided','approved','decider','2026-10-01T00:00:00Z','requester',
                'legacy-effect','2026-10-01T00:00:00Z',1,'2026-10-01T00:00:00Z','2026-10-01T00:00:00Z',
                '2026-10-01T00:00:00Z','2026-10-01T00:00:00Z','{"ok":true}')]],
                {string.rep("a",64), '{"kind":"operation","payload":{},"ref":"test:effect","revision":"1"}', string.rep("b",64)})
            assert(not insert_error, tostring(insert_error))
            local _, history_error = db:execute("INSERT INTO bee_approval_history VALUES ('legacy-id',2,'decided','approved','decider','approved','2026-10-01T00:00:00Z')")
            assert(not history_error, tostring(history_error))
            migrate("universal")
            migrate("universal")
            local rows = assert(db:query("SELECT * FROM bee_approval_requests WHERE approval_id = 'legacy-id'"))
            test.eq(#rows,1)
            local row = rows[1]
            test.eq(row.request_digest,string.rep("a",64))
            test.eq(row.proposal_digest,string.rep("b",64))
            test.eq(row.reviewed_digest,row.proposal_digest)
            test.eq(row.effect_admission_ms,row.expires_ms)
            test.eq(row.consumer_id,"requester")
            test.eq(row.consumed_effect,"legacy-effect")
            test.eq(row.effect_result_json,'{"ok":true}')
            test.eq(row.contract_version,1)
            test.eq(assert(db:query("SELECT kind FROM bee_approval_decisions"))[1].kind,"allow_once")
            test.eq(assert(db:query("SELECT state FROM bee_approval_grants"))[1].state,"exhausted")
            local effect = assert(db:query("SELECT * FROM bee_approval_effects"))[1]
            test.eq(effect.effect_id,"legacy-effect")
            test.eq(effect.state,"succeeded")
            test.eq(effect.receipt_json,row.effect_result_json)
            test.eq(assert(db:query("PRAGMA foreign_key_check"))[1],nil)
            test.eq(assert(db:query("SELECT COUNT(*) AS count FROM bee_approval_history"))[1].count,1)
            test.eq(assert(db:query("SELECT COUNT(*) AS count FROM bee_approval_events"))[1].count,1)
            db:release()
        end)
    end)
end
return M
