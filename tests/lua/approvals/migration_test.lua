local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local hash = require("hash")
local clock = require("clock")
local service = require("service")
local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local DATABASE = "bee.approvals:migration_test_db"
local function migrate(name: string)
    local id = "bee.approvals.migrations:" .. name
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end
local function define_tests()
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
                {string.rep("a",64), '{"kind":"operation","payload":{},"ref":"bee.test:effect","revision":"1"}', string.rep("b",64)})
            assert(not insert_error, tostring(insert_error))
            local _, failed_error = db:execute([[INSERT INTO bee_approval_requests
                (approval_id,owner_node,owner_incarnation,workspace_id,requester_id,requester_key,request_digest,
                request_kind,policy,proposal_json,proposal_digest,prompt_json,response_schema_json,revision,state,
                decision,decider_id,decided_at,consumer_id,consumed_effect,consumed_at,expires_ms,expires_at,
                created_at,updated_at,effect_completed_at,effect_result_json)
                SELECT 'legacy-failed',owner_node,owner_incarnation,workspace_id,requester_id,'failed-key',request_digest,
                request_kind,policy,proposal_json,proposal_digest,prompt_json,response_schema_json,revision,state,
                decision,decider_id,decided_at,consumer_id,'failed-effect',consumed_at,expires_ms,expires_at,
                created_at,updated_at,effect_completed_at,'{"ok":false}' FROM bee_approval_requests WHERE approval_id = 'legacy-id']])
            assert(not failed_error, tostring(failed_error))
            local proposal = '{"kind":"operation","payload":{},"ref":"bee.test:effect","revision":"1"}'
            local created_at = clock.now()
            local deadline = clock.milliseconds() + 600000
            local _, unused_error = db:execute([[INSERT INTO bee_approval_requests
                (approval_id,owner_node,owner_incarnation,workspace_id,requester_id,requester_key,request_digest,
                request_kind,policy,proposal_json,proposal_digest,prompt_json,response_schema_json,revision,state,
                decision,decider_id,decided_at,expires_ms,expires_at,created_at,updated_at)
                SELECT 'legacy-unused',owner_node,owner_incarnation,workspace_id,requester_id,'unused-key',request_digest,
                request_kind,policy,proposal_json,?,prompt_json,response_schema_json,revision,state,
                decision,decider_id,?,?,?,?,?
                FROM bee_approval_requests WHERE approval_id = 'legacy-id']],
                {assert(hash.sha256(proposal)), created_at, deadline, clock.stamp(deadline), created_at, created_at})
            assert(not unused_error, tostring(unused_error))
            local _, authority_error = db:execute("INSERT INTO bee_approval_authority VALUES ('node',1,'2026-10-01T00:00:00Z')")
            assert(not authority_error, tostring(authority_error))
            local _, history_error = db:execute("INSERT INTO bee_approval_history VALUES ('legacy-id',2,'decided','approved','decider','approved','2026-10-01T00:00:00Z')")
            assert(not history_error, tostring(history_error))
            local _, failed_history_error = db:execute("INSERT INTO bee_approval_history SELECT 'legacy-failed',revision,state,decision,actor_id,reason,at FROM bee_approval_history WHERE approval_id = 'legacy-id'")
            assert(not failed_history_error, tostring(failed_history_error))
            local _, unused_history_error = db:execute("INSERT INTO bee_approval_history SELECT 'legacy-unused',revision,state,decision,actor_id,reason,at FROM bee_approval_history WHERE approval_id = 'legacy-id'")
            assert(not unused_history_error, tostring(unused_history_error))
            assert(db:execute("INSERT INTO bee_approval_window_grants VALUES ('legacy-id','node','workspace','requester','policy',?,'decider',NULL,1,'2026-10-01T00:00:00Z',2,'2026-10-01T00:00:01Z',NULL)",{string.rep("c",64)}))
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
            test.eq(assert(db:query("SELECT kind FROM bee_approval_decisions WHERE approval_id = 'legacy-id'"))[1].kind,"allow_once")
            test.eq(assert(db:query("SELECT state FROM bee_approval_grants WHERE approval_id = 'legacy-id'"))[1].state,"exhausted")
            local effect = assert(db:query("SELECT * FROM bee_approval_effects WHERE approval_id = 'legacy-id'"))[1]
            test.eq(effect.effect_id,"legacy-effect")
            test.eq(effect.state,"succeeded")
            test.eq(effect.receipt_json,row.effect_result_json)
            test.eq(assert(db:query("PRAGMA foreign_key_check"))[1],nil)
            test.eq(assert(db:query("SELECT COUNT(*) AS count FROM bee_approval_history"))[1].count,3)
            test.eq(assert(db:query("SELECT COUNT(*) AS count FROM bee_approval_events"))[1].count,3)
            migrate("effect_routes")
            local routed = assert(db:query("SELECT * FROM bee_approval_effects WHERE approval_id = 'legacy-id'"))[1]
            test.eq(routed.destination, "fixture.effect")
            test.eq(routed.effect_id, "legacy-effect")
            test.eq(routed.receipt_json, row.effect_result_json)
            local event = assert(db:query("SELECT * FROM bee_approval_events WHERE destination = 'fixture.effect' AND approval_id = 'legacy-id'"))[1]
            test.eq(event.acknowledged_at, row.effect_completed_at)
            test.eq(assert(db:query("SELECT kind FROM bee_approval_events WHERE destination = 'requester:requester' AND approval_id = 'legacy-id'"))[1].kind, "approval.decided")
            local failed = assert(db:query("SELECT * FROM bee_approval_effects WHERE approval_id = 'legacy-failed'"))[1]
            test.eq(failed.effect_id, "failed-effect")
            test.eq(failed.receipt_json, '{"ok":false}')
            test.eq(failed.state, "failed")
            local unused = assert(db:query("SELECT * FROM bee_approval_effects WHERE approval_id = 'legacy-unused'"))[1]
            test.eq(unused.effect_id, "legacy-unused")
            assert(db:execute("INSERT INTO bee_approval_runtime_leases VALUES ('legacy-failed','node','requester','workspace','Bash',?, ?,2,'2026-10-01T00:00:01Z',?)",{string.rep("e",64),deadline,string.rep("b",64)}))
            local use_digest = assert(hash.sha256(assert(canonical.encode({subject = "requester",workspace_id = "workspace",tool = "Bash",input_digest = string.rep("e",64)}))))
            assert(db:execute("INSERT INTO bee_approval_runtime_lease_uses VALUES ('legacy-failed','old-use',?)",{use_digest}))
            migrate("grants")
            migrate("grants")
            local window = assert(db:query("SELECT * FROM bee_approval_grants WHERE grant_id = 'legacy-id'"))[1]
            test.eq(window.domain,"approval_window")
            test.eq(window.until_ms,2)
            test.eq(window.max_uses,nil)
            test.eq(window.provenance_json,'{"kind":"legacy","source":"approval_window","approval_id":"legacy-id"}')
            test.eq(assert(db:query("SELECT COUNT(*) AS n FROM bee_approval_grants WHERE approval_id = 'legacy-id'"))[1].n,1)
            test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'bee_approval_window_grants'")),0)
            migrate("runtime_grants")
            migrate("runtime_grants")
            local runtime = assert(db:query("SELECT * FROM bee_approval_grants WHERE grant_id = 'legacy-failed:grant'"))[1]
            test.eq(runtime.domain,"runtime_lease")
            test.eq(runtime.used,1); test.eq(runtime.max_uses,2); test.eq(runtime.until_ms,deadline)
            test.eq(runtime.state,"revoked")
            test.eq(assert(bounds.object(json.decode(runtime.provenance_json))).kind,"legacy")
            test.eq(#assert(db:query("SELECT name FROM sqlite_master WHERE name IN ('bee_approval_runtime_leases','bee_approval_runtime_lease_uses')")),0)
            test.eq(assert(db:query("SELECT request_digest FROM bee_approval_grant_uses WHERE grant_id = 'legacy-failed:grant'"))[1].request_digest,use_digest)
            local claim = {operation = "claim", approval_id = "legacy-unused", proposal_digest = assert(hash.sha256(proposal)),
                effect_key = "existing-domain-effect", owner_incarnation = 1}
            local claimed = service.execute(db, "requester", "effect", claim, nil, nil)
            test.is_true(claimed.ok, tostring(claimed.code) .. ": " .. tostring(claimed.message))
            test.eq(assert(bounds.object(claimed.value)).consumed_effect, "existing-domain-effect")
            test.eq(service.execute(db, "requester", "effect", claim, deadline + 1, nil).replayed, true)
            claim.effect_key = "different-domain-effect"
            test.eq(service.execute(db, "requester", "effect", claim, nil, nil).code, "CONFLICT")
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
