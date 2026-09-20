-- MIT. Owner-local exact overlay replacement with generation conflict retry.
local test = require("test")
local materializer = require("materializer")
local artifact = require("artifact")

type Entry = {[string]: unknown}
type State = {entries: {[string]: Entry}, generation: integer, conflicts: integer}

local function copy(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(value :: table) do result[key] = copy(item) end
    return result
end

local function api(state: State): ((string) -> (unknown?, unknown?))
    return function(owner: string): (unknown?, unknown?)
        local observed = state.generation
        local snapshot = {}
        function snapshot:entries(): ({unknown}?, unknown?)
            local result: {unknown} = {}
            for _, entry in pairs(state.entries) do result[#result + 1] = copy(entry) end
            return result, nil
        end
        function snapshot:changes(): unknown
            local operations: {unknown} = {}
            local changes = {}
            function changes:create(entry: Entry): (unknown?, unknown?) operations[#operations + 1] = {"create", copy(entry)}; return true, nil end
            function changes:update(entry: Entry): (unknown?, unknown?) operations[#operations + 1] = {"update", copy(entry)}; return true, nil end
            function changes:delete(id: string): (unknown?, unknown?) operations[#operations + 1] = {"delete", id}; return true, nil end
            function changes:apply(): (unknown?, unknown?)
                if state.conflicts > 0 then state.conflicts = state.conflicts - 1; state.generation = state.generation + 1; return nil, {conflict = true} end
                if observed ~= state.generation then return nil, {conflict = true} end
                for _, raw in ipairs(operations) do
                    local operation = raw :: {unknown}
                    local verb = operation[1] :: string
                    if verb == "delete" then state.entries[operation[2] :: string] = nil
                    else
                        local entry = operation[2] :: Entry
                        if entry.meta == nil then entry.meta = {} end
                        state.entries[entry.id :: string] = entry
                    end
                end
                state.generation = state.generation + 1
                return true, nil
            end
            return changes
        end
        return snapshot, nil
    end
end

local function is_conflict(err: unknown): boolean
    return type(err) == "table" and (err :: {[string]: unknown}).conflict == true
end

local function define_tests()
    test.describe("Governance overlay materializer", function()
        test.it("replaces the complete owner overlay with one checked generation", function()
            local state: State = {entries = {
                ["old:gone"] = {id = "old:gone", kind = "registry.entry", data = {value = "old"}},
                ["app:kept"] = {id = "app:kept", kind = "registry.entry", data = {value = "before"}},
            }, generation = 4, conflicts = 0}
            local desired = {
                {id = "app:kept", kind = "registry.entry", data = {value = "after"}},
                {id = "app:new", kind = "registry.entry", data = {value = "new"}},
            }
            local result, err = materializer.reconcile_with(api(state), is_conflict, "bee.governance:overlay", desired)
            if not result then error(tostring(err)) end
            test.eq(result.attempts, 1)
            test.is_true(result.changed == true)
            test.eq((state.entries["app:kept"].data :: {[string]: unknown}).value, "after")
            test.eq((state.entries["app:new"].data :: {[string]: unknown}).value, "new")
            test.is_true(state.entries["old:gone"] == nil)
            test.is_true(materializer.matches_with(api(state), "bee.governance:overlay", desired) == true)

            local stable, stable_error = materializer.reconcile_with(api(state), is_conflict, "bee.governance:overlay", desired)
            if not stable then error(tostring(stable_error)) end
            test.is_false(stable.changed == true)
            test.eq(stable.attempts, 1)
        end)

        test.it("keeps owner selection outside the artifact and returns conflicts for re-preflight", function()
            local state: State = {entries = {}, generation = 1, conflicts = 1}
            local desired = {{id = "app:item", kind = "registry.entry", data = {value = true}}}
            local result = materializer.reconcile_with(api(state), is_conflict, "bee.governance:overlay", desired)
            test.is_true(result == nil)
            test.is_true(state.entries["app:item"] == nil)
            test.is_false(materializer.matches_with(api(state), "bee.governance:overlay", desired) == true)
            local invalid = materializer.reconcile_with(api(state), is_conflict, "", desired)
            test.is_true(invalid == nil)
        end)

        test.it("reconciles and observes an exact empty overlay for cleanup", function()
            local state: State = {entries = { ["app:item"] = {
                id = "app:item", kind = "registry.entry", data = {value = true}}}, generation = 1, conflicts = 0}
            test.is_false(materializer.matches_with(api(state), "bee.governance:overlay", {}) == true)
            local result, result_error = materializer.reconcile_with(api(state), is_conflict,
                "bee.governance:overlay", {})
            if not result then error(tostring(result_error)) end
            test.is_true(result.changed == true)
            test.eq(result.entries, 0)
            test.is_true(result.artifact_digest ~= "")
            test.is_true(next(state.entries) == nil)
            test.is_true(materializer.matches_with(api(state), "bee.governance:overlay", {}) == true)
        end)

        test.it("treats empty artifact and registry metadata as the same object", function()
            local state: State = {entries = { ["app:item"] = {
                id = "app:item", kind = "registry.entry", data = {value = true},
                meta = table.create(0, 1)}}, generation = 1, conflicts = 0}
            local desired = {{id = "app:item", kind = "registry.entry", data = {value = true},
                meta = table.create(1, 0)}}
            test.is_true(materializer.matches_with(api(state), "bee.governance:overlay", desired) == true)
            local result, result_error = materializer.reconcile_with(api(state), is_conflict,
                "bee.governance:overlay", desired)
            if not result then error(tostring(result_error)) end
            test.is_false(result.changed == true)
        end)

        test.it("measures and reconciles an overlay entry near the 256 KiB artifact limit", function()
            local state: State = {entries = {}, generation = 1, conflicts = 0}
            local desired = {{id = "app:large", kind = "function.lua",
                data = {source = string.rep("x", artifact.MAX_BYTES - 2048)}}}
            local result, err = materializer.reconcile_with(api(state), is_conflict, "bee.governance:overlay", desired)
            if not result then error(tostring(err)) end
            test.is_true(result.changed == true)
            test.is_true(result.artifact_digest ~= "")
            test.is_true(materializer.matches_with(api(state), "bee.governance:overlay", desired) == true)
        end)
    end)
end

return test.run_cases(define_tests)
