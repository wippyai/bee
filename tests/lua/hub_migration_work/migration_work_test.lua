-- MIT. Migration work tests cover the measured package definition and the
-- narrow runtime receipt used during interrupted Hub publication.
local test = require("test")
local migration_work = require("migration_work")
local plan = require("plan")

local ID = "acme.app:001"
local COMPONENT = "acme/app"
local TARGET = "app:db"
local TIMESTAMP = "2026-01-01"

local function package_entry(data: unknown, meta: {[string]: unknown}?): {[string]: unknown}
    return {id = ID, kind = "function.lua", meta = meta or {type = "migration", target_db = TARGET, timestamp = TIMESTAMP}, data = data}
end

local function prepared(entry: {[string]: unknown}, displayed: {[string]: unknown}?): plan.Prepared
    local migration = displayed or {id = ID, component = COMPONENT, target_db = TARGET, timestamp = TIMESTAMP}
    return {
        plan = {request = {}, base_revision = 1, root_id = "bee.hub.deps:test", digest = "", modules = {},
            missing = {}, migrations = {migration}, starts = {}, capabilities = {}, ready = true},
        resolved = {packages = {{component = COMPONENT, version = "1.0.0", digest = "", entries = {entry},
            dependencies = {}, requirements = {requirements = {}, missing = {}}}}, missing = {}},
        installed = {version = 1, modules = {}, roots = {}},
    } :: plan.Prepared
end

local function runtime(entry: {[string]: unknown}, owner: string?): {[string]: unknown}
    return {entries = {{id = entry.id, kind = entry.kind, meta = entry.meta, data = entry.data,
        registry = {owner = owner or COMPONENT}}}}
end

local function captured(entry: {[string]: unknown}): migration_work.Work
    local work, problem = migration_work.capture(prepared(entry))
    if not work then error(problem or "migration work was not captured") end
    return work
end

local function define_tests()
    test.describe("Hub migration work", function()
        test.it("captures exact package entries, starts with no rows, and round trips receipts", function()
            local work = captured(package_entry({up = "create users", down = "drop users"}))
            test.eq(#work.entries, 1)
            test.eq(#work.rows, 0)
            test.eq(work.entries[1].id, ID)
            test.eq(work.entries[1].component, COMPONENT)
            test.eq(work.entries[1].target_db, TARGET)
            test.eq(work.entries[1].timestamp, TIMESTAMP)
            test.eq(#work.entries[1].digest, 64)
            test.not_nil(work.entries[1].digest:match("^[0-9a-f]+$"))

            local trusted = migration_work.entries(work)
            test.eq(trusted[1].id, ID)
            test.eq(trusted[1].registry.owner, COMPONENT)
            test.eq(trusted[1].meta.type, "migration")
            test.eq(trusted[1].meta.target_db, TARGET)
            test.eq(trusted[1].meta.timestamp, TIMESTAMP)

            local decoded, problem = migration_work.decode({entries = work.entries,
                rows = {{id = ID, target_db = TARGET, module = COMPONENT, status = "applied"}}})
            test.is_nil(problem)
            test.not_nil(decoded)
            if decoded then test.eq(decoded.rows[1].status, "applied") end
        end)

        test.it("verifies body, owner, target, and presence against the installed snapshot", function()
            local original = package_entry({up = "create users", down = "drop users"})
            local work = captured(original)
            local ok, problem = migration_work.verify(work, runtime(original))
            test.is_true(ok)
            test.is_nil(problem)

            local changed_body = package_entry({up = "create accounts", down = "drop users"})
            local body_ok, body_error = migration_work.verify(work, runtime(changed_body))
            test.is_false(body_ok)
            test.not_nil(body_error)

            local owner_ok, owner_error = migration_work.verify(work, runtime(original, "other/module"))
            test.is_false(owner_ok)
            test.not_nil(owner_error)

            local changed_target = package_entry(original.data, {type = "migration", target_db = "other:db", timestamp = TIMESTAMP})
            local target_ok, target_error = migration_work.verify(work, runtime(changed_target))
            test.is_false(target_ok)
            test.not_nil(target_error)

            local missing_ok, missing_error = migration_work.verify(work, {entries = {}})
            test.is_false(missing_ok)
            test.not_nil(missing_error)
        end)

        test.it("requires function.lua entries and exact displayed ownership during capture", function()
            local wrong_kind = package_entry({up = "create users"})
            wrong_kind.kind = "library.lua"
            local work, problem = migration_work.capture(prepared(wrong_kind))
            test.is_nil(work)
            test.not_nil(problem)

            local wrong_owner, owner_problem = migration_work.capture(prepared(package_entry({up = "create users"}),
                {id = ID, component = "other/module", target_db = TARGET, timestamp = TIMESTAMP}))
            test.is_nil(wrong_owner)
            test.not_nil(owner_problem)

            local missing, missing_problem = migration_work.capture(prepared({id = "acme.app:other", kind = "function.lua",
                meta = {type = "migration", target_db = TARGET, timestamp = TIMESTAMP}, data = {}}))
            test.is_nil(missing)
            test.not_nil(missing_problem)
        end)

        test.it("rejects forged or malformed receipt rows", function()
            local work = captured(package_entry({up = "create users"}))
            local invalid = {
                {entries = work.entries, rows = {{id = "other:001", target_db = TARGET, module = COMPONENT, status = "applied"}}},
                {entries = work.entries, rows = {{id = ID, target_db = "other:db", module = COMPONENT, status = "applied"}}},
                {entries = work.entries, rows = {{id = ID, target_db = TARGET, module = "other/module", status = "applied"}}},
                {entries = work.entries, rows = {{id = ID, target_db = TARGET, module = COMPONENT, status = "unknown"}}},
                {entries = work.entries, rows = {{id = ID, target_db = TARGET, module = COMPONENT, status = "applied"},
                    {id = ID, target_db = TARGET, module = COMPONENT, status = "reverted"}}},
                {entries = work.entries, rows = {{id = ID, target_db = TARGET, module = COMPONENT, status = "applied", forged = true}}},
            }
            for _, raw in ipairs(invalid) do
                local decoded = migration_work.decode(raw)
                test.is_nil(decoded)
            end
            local extra = {entries = work.entries, rows = {}, receipt = "forged"}
            test.is_nil(migration_work.decode(extra))
        end)
    end)
end

return test.run_cases(define_tests)
