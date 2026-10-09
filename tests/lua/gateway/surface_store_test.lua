-- MIT. Durable surface selection belongs to a binding and uses revision CAS.
local test = require("test")
local schema = require("schema")
local store = require("store")
local grants = require("grants")
local grant_schema = require("grant_schema")
local clock = require("clock")
local bounds = require("bounds")
local function open(): sql.DB
    local first = schema.open("bee.gateway:surface_test_db", "bee.approvals.migrations")
    first:release()
    return schema.open("bee.gateway:surface_test_db", "bee.gateway.migrations")
end
local function begin(db: sql.DB): sql.Transaction
    local tx, err = db:begin()
    if not tx then error(tostring(err)) end
    return tx
end
local function authorize(tx: sql.Transaction, id: string, binding: string, traits: {string})
    local record: grants.Grant = {grant_id = id .. ":grant",domain = "gateway_access",owner_node = "node",workspace_id = "workspace",requester_id = "author",granted_by = "person",subject = {principal_id = "author",audience = binding},scope = {type = "exact",parameters = {}},terms = {kind = "binding",time_basis = "absolute"},provenance = {kind = "decision"},metadata = {binding_id = binding,traits = traits},state = "active",revision = 1,used = 0,reserved = 0,created_at = clock.now()}
    assert(not grants.create(tx,record))
end
local function run()
    test.describe("Binding surface storage", function()
        test.it("keeps saved consent within its exact profile while allowing host tools", function()
            local db = open()
            local tx = begin(db)
            local bee = {mcp = {{tool = "app_tools",scope = {}}}, permission_answers = "ask"}
            local record: grants.Grant = {grant_id = "saved-consent",domain = "profile_choices",owner_node = "node",workspace_id = "workspace",requester_id = "person",granted_by = "person",subject = {principal_id = "node",audience = "profile"},scope = {type = "exact",parameters = {configuration = {bee = bee}}},terms = {kind = "until_revoked",time_basis = "absolute"},provenance = {kind = "legacy"},metadata = {},state = "active",revision = 1,used = 0,reserved = 0,created_at = clock.now()}
            assert(not grants.create(tx,record))
            local declaration: {[string]: unknown} = {authority_grant_id = record.grant_id,profile = bee,base_tools = {"app_tools","thread_read"}}
            test.not_nil((store.profile_authority(tx,"binding","workspace",declaration)))
            declaration.base_tools = {"app_tools","publish"}
            local widened, scope_error = store.profile_authority(tx,"binding","workspace",declaration)
            test.is_nil(widened)
            test.eq(assert(scope_error).code,"DENIED")
            declaration.base_tools = {"app_tools"}
            declaration.profile = {mcp = {{tool = "app_tools",scope = {}}},permission_answers = "provider"}
            test.is_nil((store.profile_authority(tx,"binding","workspace",declaration)))
            declaration.profile = bee
            test.is_nil((store.profile_authority(tx,"binding","another-workspace",declaration)))
            assert(tx:execute([[INSERT INTO bee_gateway_bindings
                (binding_id,subject,action_id,attempt_id,thread_id,owner_incarnation,carrier_epoch,tools_json,hooks_json,epoch,credential_generation,expires_at,created_at)
                VALUES ('saved-binding','author','saved-action','saved-attempt','thread',1,1,'[]','[]',1,0,'2099-01-01T00:00:00.000Z','2026-09-15T00:00:00.000Z')]]))
            local initial, initialize_error = store.initialize(tx,"saved-binding",'{}','[]','{}')
            assert(initial,initialize_error and initialize_error.message)
            declaration.access = {policy = "access",traits = {"bee.app:runtime","notes"}}
            declaration.traits = {{id = "notes",tools = {"thread_message"}}}
            local missing, missing_error = store.call_authority(tx,"saved-binding","workspace",declaration,"application_open",clock.milliseconds())
            test.is_nil(missing)
            test.eq(assert(missing_error).code,"DENIED")
            authorize(tx,"runtime-access","saved-binding",{"bee.app:runtime","notes"})
            local applied, apply_error = store.grant(tx,"saved-binding","runtime-access",string.rep("a",64),'["bee.app:runtime","notes"]')
            assert(applied,apply_error and apply_error.message)
            test.eq(store.call_authority(tx,"saved-binding","workspace",declaration,"application_open",clock.milliseconds()),"runtime-access:grant")
            test.eq(store.call_authority(tx,"saved-binding","workspace",declaration,"thread_message",clock.milliseconds()),"runtime-access:grant")
            test.eq(store.call_authority(tx,"saved-binding","workspace",declaration,"app_tools",clock.milliseconds()),record.grant_id)
            local runtime = assert(grants.read(tx,"runtime-access:grant"))
            assert(not grants.revoke(tx,runtime,runtime.revision,"person",clock.milliseconds()))
            test.is_nil((store.call_authority(tx,"saved-binding","workspace",declaration,"application_open",clock.milliseconds())))
            test.eq(store.call_authority(tx,"saved-binding","workspace",declaration,"app_tools",clock.milliseconds()),record.grant_id)
            tx:rollback()
            db:release()
        end)
        test.it("retains selection across reopen, fences stale writes and isolates bindings", function()
            local db = open()
            for _, id in ipairs({"surface-a", "surface-b"}) do
                local _, err = db:execute([[INSERT INTO bee_gateway_bindings
                    (binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, hooks_json,
                    epoch, credential_generation, expires_at, created_at)
                    VALUES (?, 'author', ?, ?, 'thread', 1, 1, '[]', '[]', 1, 0, '2099-01-01T00:00:00.000Z', '2026-09-15T00:00:00.000Z')]], {id, id, id})
                if err then error(tostring(err)) end
            end
            local tx = begin(db)
            local configured = {base_tools = {"app_tools"},tools = {},traits = {},active_traits = {},fixed_context = {},dynamic_keys = {}}
            local bound, bind_error = store.bind_authority(tx,"node",nil,"author","surface-a",configured,"host:policy")
            assert(bound,bind_error and bind_error.message)
            test.not_nil((store.profile_authority(tx,"surface-a",nil,configured)))
            local common = assert(grants.read(tx,assert(bounds.id(configured.authority_grant_id))))
            test.eq(common.provenance.kind,"host_policy")
            test.eq(common.subject.audience,"surface-a")
            assert(not grants.revoke(tx,common,common.revision,"person",clock.milliseconds()))
            test.is_nil((store.profile_authority(tx,"surface-a",nil,configured)))
            local a, err = store.initialize(tx, "surface-a", '{}', '[]', '{}')
            if not a then error(tostring(err and err.message)) end
            local b = store.initialize(tx, "surface-b", '{}', '[]', '{}')
            if not b then error("initialize b") end
            local changed = store.replace(tx, "surface-a", 1, '["research:measure"]', '{"experiment":"one"}')
            if not changed then error("replace") end
            test.eq(changed.revision, 2)
            local stale, conflict = store.replace(tx, "surface-a", 1, '[]', '{}')
            test.is_nil(stale)
            if not conflict then error("expected conflict") end
            test.eq(conflict.code, "CONFLICT")
            local _, commit_error = tx:commit()
            if commit_error then error(tostring(commit_error)) end
            db:release()
            db = open()
            tx = begin(db)
            local retained = store.read(tx, "surface-a")
            local isolated = store.read(tx, "surface-b")
            if not retained or not isolated then error("read retained states") end
            test.eq(retained.active_json, '["research:measure"]')
            test.eq(retained.context_json, '{"experiment":"one"}')
            test.eq(isolated.revision, 1)
            test.eq(isolated.context_json, '{}')
            local missing, absent = store.read(tx, "missing")
            test.is_nil(missing)
            if not absent then error("absent") end
            test.eq(absent.code, "NOT_FOUND")
            tx:rollback()
            tx = begin(db)
            authorize(tx,"approval-one","surface-a",{"research:write"})
            local granted, grant_error = store.grant(tx, "surface-a", "approval-one", string.rep("a", 64), '["research:write"]')
            if not granted then error(tostring(grant_error and grant_error.message)) end
            test.eq(granted.revision, 3)
            test.eq(granted.active_json, '["research:measure","research:write"]')
            local _, grant_commit = tx:commit()
            if grant_commit then error(tostring(grant_commit)) end
            db:release()
            -- Recover a lost grant commit reply after reopening; the receipt
            -- must neither advance the revision nor affect another binding.
            db = open()
            tx = begin(db)
            local replay = store.grant(tx, "surface-a", "approval-one", string.rep("a", 64), '["research:write"]')
            if not replay then error("grant replay missing") end
            test.eq(replay.revision, 3)
            local wrong, wrong_error = store.grant(tx, "surface-a", "approval-one", string.rep("b", 64), '["research:write"]')
            test.is_nil(wrong)
            if not wrong_error then error("expected changed receipt refusal") end
            test.eq(wrong_error.code, "CONFLICT")
            local own = store.grants(tx, "surface-a")
            local other = store.grants(tx, "surface-b")
            if not own or not other then error("grant read failed") end
            test.eq(#own, 1)
            test.eq(own[1], "research:write")
            test.eq(#other, 0)
            local absent_runtime, absent_runtime_error = store.runtime_grant(tx, "surface-b", "bee.app:runtime")
            test.is_nil(absent_runtime)
            test.is_nil(absent_runtime_error)
            authorize(tx,"approval-z","surface-a",{"bee.app:runtime"})
            authorize(tx,"approval-a","surface-a",{"bee.app:runtime"})
            local later_runtime, later_runtime_error = store.grant(tx, "surface-a", "approval-z", string.rep("d", 64), '["bee.app:runtime"]')
            if not later_runtime then error(tostring(later_runtime_error and later_runtime_error.message)) end
            local first_runtime, first_runtime_error = store.grant(tx, "surface-a", "approval-a", string.rep("e", 64), '["bee.app:runtime"]')
            if not first_runtime then error(tostring(first_runtime_error and first_runtime_error.message)) end
            local selected_runtime, selected_runtime_error = store.runtime_grant(tx, "surface-a", "bee.app:runtime")
            if not selected_runtime then error(tostring(selected_runtime_error and selected_runtime_error.message)) end
            test.eq(selected_runtime.approval_id, "approval-a")
            test.eq(selected_runtime.proposal_digest, string.rep("e", 64))
            assert(tx:commit())
            tx = begin(db)
            authorize(tx,"approval-corrupt","surface-b",{"bee.app:runtime"})
            local _, corrupt_error = tx:execute("INSERT INTO bee_gateway_access_receipts (binding_id, approval_id, proposal_digest, traits_json,grant_id) VALUES ('surface-b', 'approval-corrupt', ?, 'not-json','approval-corrupt:grant')", {string.rep("f", 64)})
            if corrupt_error then error(tostring(corrupt_error)) end
            local corrupt_runtime, corrupt_runtime_error = store.runtime_grant(tx, "surface-b", "bee.app:runtime")
            test.is_nil(corrupt_runtime)
            if not corrupt_runtime_error then error("corrupt runtime receipt accepted") end
            test.eq(corrupt_runtime_error.code, "STORAGE")
            local before = store.read(tx, "surface-b")
            if not before then error("other binding missing") end
            authorize(tx,"approval-two","surface-b",{"research:write"})
            local rolled_back = store.grant(tx, "surface-b", "approval-two", string.rep("c", 64), '["research:write"]')
            if not rolled_back then error("prepare rolled-back grant") end
            tx:rollback()
            tx = begin(db)
            local after = store.read(tx, "surface-b")
            local absent_grants = store.grants(tx, "surface-b")
            if not after or not absent_grants then error("read rollback") end
            test.eq(after.revision, before.revision)
            test.eq(#absent_grants, 0)
            tx:rollback()
            tx = begin(db)
            local authority = assert(grants.read(tx,"approval-one:grant"))
            assert(not grants.revoke(tx,authority,authority.revision,"person",clock.milliseconds()))
            test.eq(#assert(store.grants(tx,"surface-a")),1)
            local historic = assert(tx:query("SELECT traits_json FROM bee_gateway_access_receipts WHERE binding_id = ? AND approval_id = ?",{"surface-a","approval-one"}))
            test.eq(#historic,1)
            test.eq(assert(store.read(tx,"surface-a")).active_json:find("research:write",1,true) ~= nil,true)
            test.eq(assert(store.runtime_grant(tx,"surface-a","bee.app:runtime")).approval_id,"approval-a")
            for _, id in ipairs({"approval-a:grant","approval-z:grant"}) do
                local record = assert(grants.read(tx,id))
                assert(not grants.revoke(tx,record,record.revision,"person",clock.milliseconds()))
            end
            test.eq(#assert(store.grants(tx,"surface-a")),0)
            test.eq(store.runtime_grant(tx,"surface-a","bee.app:runtime"),nil)
            tx:rollback()
            db:release()
        end)
    end)
end
return test.run_cases(run)
