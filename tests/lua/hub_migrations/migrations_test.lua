-- MIT. The Hub migration adapter is tested through its own typed runner surface.
local test = require("test")
local migrations = require("migrations")

type Call = {operation: string, target_db: string, ids: {string}, count: integer?}

local function entry(id: string, owner: string, target_db: string, at: string): migrations.Entry
    return {id = id, meta = {type = "migration", target_db = target_db, timestamp = at}, registry = {owner = owner}}
end

local function allowed_ids(options: {[string]: unknown}): {string}
    local raw = options.allowed_ids
    if type(raw) ~= "table" then return {} end
    local values = raw :: {[number]: unknown}
    local ids: {string} = {}
    for _, value in ipairs(values) do if type(value) == "string" then ids[#ids + 1] = value end end
    return ids
end

local function source(entries: {migrations.Entry}, applied: {[string]: boolean}, calls: {Call}): migrations.Source
    return {
        entries = entries,
        runner = {
            setup = function(target_db: string): (migrations.DatabaseRunner?, string?)
                local database: migrations.DatabaseRunner = {
                    run_next = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                        local ids = allowed_ids(options)
                        calls[#calls + 1] = {operation = "up", target_db = target_db, ids = ids}
                        return {migrations = {{id = ids[1], status = "applied"}}}
                    end,
                    rollback = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                        local ids = allowed_ids(options)
                        local count = type(options.count) == "number" and math.floor(options.count) or nil
                        calls[#calls + 1] = {operation = "down", target_db = target_db, ids = ids, count = count}
                        local rows: {unknown} = {}
                        for _, id in ipairs(ids) do rows[#rows + 1] = {id = id, status = "reverted"} end
                        return {migrations = rows}
                    end,
                }
                return database, nil
            end,
        },
        is_applied = function(target_db: string, id: string): (boolean?, string?)
            return applied[target_db .. "\n" .. id] == true, nil
        end,
    }
end

local function define_tests()
    test.describe("Hub migrations", function()
        test.it("uses captured registry ownership and native runner ordering", function()
            local calls: {Call} = {}
            local result, problem = migrations.execute(source({
                entry("acme.app:20_second", "acme/app", "app:db", "2026-01-02"),
                entry("acme.app:10_first", "acme/app", "app:db", "2026-01-01"),
                entry("acme.lib:01_other", "acme/lib", "other:db", "2026-01-01"),
            }, {}, calls), {operation = "up", components = {"acme/app", "acme/lib"},
                entry_ids = {"acme.app:20_second", "acme.lib:01_other", "acme.app:10_first"}})
            test.is_nil(problem)
            test.not_nil(result)
            if not result then return end
            test.eq(result.rows[1].id, "acme.app:10_first")
            test.eq(result.rows[2].id, "acme.app:20_second")
            test.eq(result.rows[3].id, "acme.lib:01_other")
            local first_call, third_call = calls[1], calls[3]
            if not first_call or not third_call then error("runner call sequence is incomplete") end
            test.eq(first_call.ids[1], "acme.app:10_first")
            test.eq(third_call.target_db, "other:db")
        end)

        test.it("refuses authored ownership claims and an owner outside the plan before execution", function()
            local calls: {Call} = {}
            local forged = entry("acme.evil:01", "acme/evil", "app:db", "2026-01-01")
            forged.meta.owner = "acme/app"
            local result, problem = migrations.execute(source({forged}, {}, calls),
                {operation = "up", components = {"acme/app"}, entry_ids = {"acme.evil:01"}})
            test.is_nil(result)
            test.not_nil(problem)
            test.eq(#calls, 0)
        end)

        test.it("requires ledger evidence before treating an omitted runner row as already applied", function()
            local calls: {Call} = {}
            local id = "acme.app:01"
            local result, problem = migrations.execute(source({entry(id, "acme/app", "app:db", "2026-01-01")},
                {["app:db\n" .. id] = true}, calls), {operation = "up", components = {"acme/app"}, entry_ids = {id}})
            test.is_nil(problem)
            test.not_nil(result)
            if result then test.eq(result.rows[1].reason, "already_applied") end
            test.eq(#calls, 0)

            local missing = source({entry(id, "acme/app", "app:db", "2026-01-01")}, {}, {})
            missing.runner.setup = function(_: string): (migrations.DatabaseRunner?, string?)
                return {
                    run_next = function(_: migrations.DatabaseRunner, _: {[string]: unknown}): migrations.RunnerResult
                        return {migrations = {}}
                    end,
                    rollback = function(_: migrations.DatabaseRunner, _: {[string]: unknown}): migrations.RunnerResult
                        return {migrations = {}}
                    end,
                }, nil
            end
            local incomplete, incomplete_problem = migrations.execute(missing,
                {operation = "up", components = {"acme/app"}, entry_ids = {id}})
            test.not_nil(incomplete)
            test.not_nil(incomplete_problem)
            if incomplete then test.eq(#incomplete.rows, 0) end
        end)

        test.it("uses runner rollback for the applied subset and preserves its down semantics", function()
            local calls: {Call} = {}
            local one, two = "acme.app:01", "acme.app:02"
            local result, problem = migrations.execute(source({
                entry(one, "acme/app", "app:db", "2026-01-01"), entry(two, "acme/app", "app:db", "2026-01-02"),
            }, {["app:db\n" .. one] = true, ["app:db\n" .. two] = true}, calls),
                {operation = "down", components = {"acme/app"}, entry_ids = {one, two}})
            test.is_nil(problem)
            test.not_nil(result)
            if result then test.eq(result.rows[1].status, "reverted") end
            test.eq(#calls, 1)
            local rollback = calls[1]
            if not rollback then error("runner rollback is missing") end
            test.eq(rollback.operation, "down")
            test.eq(rollback.count, 2)
        end)

        test.it("returns completed rows when a later runner result cannot prove execution", function()
            local first, second = "acme.app:01", "acme.app:02"
            local partial = source({
                entry(first, "acme/app", "app:db", "2026-01-01"), entry(second, "acme/app", "app:db", "2026-01-02"),
            }, {}, {})
            partial.runner.setup = function(_: string): (migrations.DatabaseRunner?, string?)
                return {
                    run_next = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                        local ids = allowed_ids(options)
                        if ids[1] == first then return {migrations = {{id = first, status = "applied"}}} end
                        return {migrations = {}}
                    end,
                    rollback = function(_: migrations.DatabaseRunner, _: {[string]: unknown}): migrations.RunnerResult
                        return {migrations = {}}
                    end,
                }, nil
            end
            local result, problem = migrations.execute(partial,
                {operation = "up", components = {"acme/app"}, entry_ids = {first, second}})
            test.not_nil(result)
            test.not_nil(problem)
            if result then test.eq(result.rows[1].id, first) end
        end)
    end)
end

return test.run_cases(define_tests)
