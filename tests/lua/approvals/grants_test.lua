local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local hash = require("hash")
local grants = require("grants")
local service = require("service")
local schema = require("schema")
local bounds = require("bounds")
local clock = require("clock")
type Object = {[string]: unknown}
local function value(result: {ok: boolean,code: string?,message: string?,value: unknown}): Object
    assert(result.ok,tostring(result.code) .. ": " .. tostring(result.message))
    return assert(bounds.object(result.value))
end
local function record(workspace: string, domain: string, now: integer): grants.Grant
    return {grant_id = assert(uuid.v4()),domain = domain,owner_node = "node",workspace_id = workspace,requester_id = "subject",granted_by = "another-person",subject = {principal_id = "subject",audience = "destination"},scope = {type = "exact",parameters = {path = "one"}},terms = {kind = "bounded",time_basis = "absolute"},provenance = {kind = "legacy",source = "test-domain"},metadata = {},state = "active",revision = 1,used = 0,reserved = 0,until_ms = now + 100,max_uses = 1,created_at = clock.stamp(now)}
end
local function define_tests()
    test.describe("common Grant authority",function()
        test.it("pages durable use history and records expiry without undoing admitted uses",function()
            local db = schema.open("bee.approvals:test_db","bee.approvals.migrations")
            local now = clock.milliseconds()
            local grant = record(assert(uuid.v4()),"runtime_lease",now)
            grant.max_uses = nil
            local tx = assert(db:begin())
            assert(not grants.create(tx,grant))
            for index = 1,70 do
                local replay, err = grants.use(tx,grant,"consume",tostring(index),string.rep("a",64),grant.revision,"subject",now)
                assert(replay == false,err)
            end
            assert(not grants.expire(tx,grant,now + 100))
            test.eq(grant.used,70)
            test.eq(grant.state,"expired")
            assert(tx:commit())
            local first = value(service.execute(db,"subject","grant",{operation = "history",grant_id = grant.grant_id},now + 100))
            test.eq(#assert(bounds.array(first.history,64)),64)
            test.eq(first.more,true)
            local second = value(service.execute(db,"subject","grant",{operation = "history",grant_id = grant.grant_id,after_revision = first.next_revision},now + 100))
            local history = assert(bounds.array(second.history,64))
            test.eq(#history,8)
            test.eq(assert(bounds.object(history[#history])).kind,"grant.expired")
            test.eq(second.more,false)
            db:release()
        end)
        test.it("keeps reservations distinct, fences competing uses, and replays only admitted effects",function()
            local db = schema.open("bee.approvals:test_db","bee.approvals.migrations")
            local now = clock.milliseconds()
            local grant = record(assert(uuid.v4()),"governance_lease",now)
            local tx = assert(db:begin())
            assert(not grants.create(tx,grant)); assert(tx:commit())
            local input: Object = {operation = "reserve",grant_id = grant.grant_id,expected_revision = 1,subject = grant.subject,scope = grant.scope,effect_key = "a"}
            value(service.execute(db,"subject","grant",input,now))
            local reserved = value(service.execute(db,"subject","grant",{operation = "read",grant_id = grant.grant_id},now))
            local current = assert(bounds.object(reserved.grant))
            test.eq(current.used,0); test.eq(current.reserved,1); test.eq(current.state,"exhausted")
            input.effect_key = "b"
            test.eq(service.execute(db,"subject","grant",input,now).ok,false)
            input.effect_key,input.operation,input.expected_revision = "a","release",2
            value(service.execute(db,"subject","grant",input,now))
            input.effect_key,input.operation,input.expected_revision = "c","reserve",3
            value(service.execute(db,"subject","grant",input,now))
            test.eq(service.execute(db,"person","grant",{operation = "revoke",grant_id = grant.grant_id,expected_revision = 3},now).code,"CONFLICT")
            value(service.execute(db,"person","grant",{operation = "revoke",grant_id = grant.grant_id,expected_revision = 4},now))
            input.operation,input.expected_revision = "admit",4
            test.eq(service.execute(db,"subject","grant",input,now).ok,false)
            local expired = record(grant.workspace_id,"governance_lease",now)
            tx = assert(db:begin()); assert(not grants.create(tx,expired)); assert(tx:commit())
            input = {operation = "reserve",grant_id = expired.grant_id,expected_revision = 1,subject = expired.subject,scope = expired.scope,effect_key = "d"}
            value(service.execute(db,"subject","grant",input,now))
            input.operation,input.expected_revision = "admit",2
            test.eq(service.execute(db,"subject","grant",input,now + 100).ok,false)
            value(service.execute(db,"subject","grant",input,now + 99))
            test.eq(service.execute(db,"subject","grant",input,now + 100).replayed,true)
            value(service.execute(db,"person","grant",{operation = "revoke",grant_id = expired.grant_id,expected_revision = 3},now + 100))
            test.eq(service.execute(db,"subject","grant",input,now + 101).replayed,true)
            input.operation,input.effect_key,input.expected_revision = "reserve","e",4
            test.eq(service.execute(db,"subject","grant",input,now + 101).ok,false)
            db:release()
        end)
        test.it("lists all workspace domains in one place with legacy provenance and revocation history",function()
            local db = schema.open("bee.approvals:test_db","bee.approvals.migrations")
            local now, workspace = clock.milliseconds(),assert(uuid.v4())
            local tx = assert(db:begin())
            for _, domain in ipairs({"follow_source","profile_choices","docker_environment","gateway_access","runtime_lease"}) do
                local grant = record(workspace,domain,now)
                assert(not grants.create(tx,grant))
            end
            assert(tx:commit())
            local listed = value(service.execute(db,"person","grant",{operation = "list",workspace_id = workspace},now))
            local rows = assert(bounds.array(listed.grants,64))
            test.eq(#rows,5)
            for _, raw in ipairs(rows) do
                local grant = assert(bounds.object(raw))
                test.eq(assert(bounds.object(grant.provenance)).kind,"legacy")
                value(service.execute(db,"person","grant",{operation = "revoke",grant_id = grant.grant_id,expected_revision = grant.revision},now))
                local detail = value(service.execute(db,"person","grant",{operation = "history",grant_id = grant.grant_id},now))
                test.eq(assert(bounds.object(detail.grant)).state,"revoked")
                test.eq(#assert(bounds.array(detail.history,64)),2)
            end
            test.eq(#assert(bounds.array(value(service.execute(db,"person","grant",{operation = "list",workspace_id = workspace},now)).grants,64)),5)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
