local test = require("test")
local schema = require("schema")
local grants = require("grants")
local clock = require("clock")
local function define_tests()
    test.describe("Trait grant fencing",function()
        test.it("fences subscriptions and intervals atomically on revocation and expiry",function()
            local db = schema.open("bee.tests.approvals:trait_test_db","bee.approvals.migrations")
            db:release()
            db = schema.open("bee.tests.approvals:trait_test_db","bee.threads.migrations")
            local now = clock.milliseconds()
            for _, ending in ipairs({"revoke","expire"}) do
                local tx = assert(db:begin())
                local record: grants.Grant = {grant_id = ending,domain = "gateway_access",owner_node = "node",workspace_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",requester_id = "subject",granted_by = "person",subject = {},scope = {parameters = {payload = {declarations = {{id = "trait"}}}}},terms = {kind = "bounded"},provenance = {kind = "consent"},metadata = {},state = "active",revision = 1,used = 0,reserved = 0,until_ms = now + 100,created_at = clock.stamp(now)}
                assert(not grants.create(tx,record))
                assert(tx:execute("INSERT INTO bee_thread_heads(thread_id,owner_actor,title,state,revision,head_sequence,created_at) VALUES ('thread','person','Thread','open',1,7,?)",{clock.stamp(now)}))
                assert(tx:execute("INSERT INTO bee_sessions(session_ref,thread_id,workspace_id,owner_actor,title,state,revision,created_at,updated_at) VALUES ('session','thread','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','person','Session','active',1,?,?)",{clock.stamp(now),clock.stamp(now)}))
                assert(tx:execute("INSERT INTO bee_session_traits VALUES ('session','trait','thread','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','{}',?,1,1)",{ending}))
                assert(tx:execute("INSERT INTO bee_session_trait_intervals VALUES ('session','trait',1,1,'{}',NULL)"))
                assert(tx:execute([[INSERT INTO bee_thread_subscriptions VALUES ('subscription','thread','person','consumer','digest','{"session_ref":"session","trait_id":"trait"}','durable',0,1,1,?,NULL)]],{clock.stamp(now)}))
                assert(tx:execute("INSERT INTO bee_thread_subscription_pages VALUES ('page','subscription',1,0,7,'digest',0,?)",{clock.stamp(now)}))
                assert(tx:commit())
                for _, rollback in ipairs({true,false}) do
                    tx = assert(db:begin())
                    record = assert(grants.read(tx,ending))
                    local err: string? = nil
                    if ending == "revoke" then err = grants.revoke(tx,record,record.revision,"person",now)
                    else err = grants.expire(tx,record,now + 100) end
                    assert(not err,err)
                    test.eq(assert(tx:query("SELECT selected FROM bee_session_traits"))[1].selected,0)
                    test.eq(assert(tx:query("SELECT end_sequence FROM bee_session_trait_intervals"))[1].end_sequence,7)
                    test.eq(assert(tx:query("SELECT acknowledged FROM bee_thread_subscription_pages"))[1].acknowledged,1)
                    test.not_nil(assert(tx:query("SELECT closed_at FROM bee_thread_subscriptions"))[1].closed_at)
                    if rollback then
                        assert(tx:rollback())
                        test.eq(assert(grants.read(db,ending)).state,"active")
                        test.eq(assert(db:query("SELECT selected FROM bee_session_traits"))[1].selected,1)
                    else assert(tx:commit()) end
                end
                for _, name in ipairs({"bee_thread_subscription_pages","bee_thread_subscriptions","bee_session_trait_intervals","bee_session_traits","bee_sessions","bee_thread_heads"}) do assert(db:execute("DELETE FROM " .. name)) end
            end
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
