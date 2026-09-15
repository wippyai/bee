-- MIT. Durable surface selection belongs to a binding and uses revision CAS.
local test = require("test")
local persist = require("persist")
local migrations = require("migrations")
local store = require("store")
local function open(): sql.DB
    local db, err = persist.open({resource = "bee.gateway:surface_test_db",
        ledger = {table = "surface_test_migrations", label = "surface test"}, migrations = migrations.all()})
    if not db then error(tostring(err)) end
    return db
end
local function begin(db: sql.DB): sql.Transaction
    local tx, err = db:begin()
    if not tx then error(tostring(err)) end
    return tx
end
local function run()
    test.describe("Binding surface storage", function()
        test.it("retains selection across reopen, fences stale writes and isolates bindings", function()
            local db = open()
            for _, id in ipairs({"surface-a", "surface-b"}) do
                local _, err = db:execute([[INSERT INTO bee_gateway_bindings
                    (binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, hooks_json,
                    epoch, credential_generation, expires_at, created_at)
                    VALUES (?, 'author', ?, ?, 'thread', 1, 1, '[]', '[]', 1, 0, '2099-01-01', '2026-09-15')]], {id, id, id})
                if err then error(tostring(err)) end
            end
            local tx = begin(db)
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
            local before = store.read(tx, "surface-b")
            if not before then error("other binding missing") end
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
            db:release()
        end)
    end)
end
return test.run_cases(run)
