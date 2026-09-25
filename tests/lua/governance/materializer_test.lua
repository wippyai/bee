-- MIT. Owner-local exact overlay replacement with generation conflict retry.
local test = require("test")
local materializer = require("materializer")
local artifact = require("artifact")
local admission = require("application_admission")

type Entry = {[string]: unknown}
type State = {entries: {[string]: Entry}, generation: integer, conflicts: integer}

local function admission_blob(artifact_digest: string): {[string]: unknown}
    local measured = assert(admission.measure({schema_revision = admission.SCHEMA,
        workspace_id = "workspace-a", overlay_owner = "bee.gov:overlay", source_node = "node-a",
        source_workspace = "source-a", artifact_digest = artifact_digest, policy_digest = string.rep("a", 64), bindings = {}}))
    return {bytes = measured.bytes, digest = measured.digest}
end

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
            local result, err = materializer.reconcile_with(api(state), is_conflict, "bee.gov:overlay", desired)
            if not result then error(tostring(err)) end
            test.eq(result.attempts, 1)
            test.is_true(result.changed == true)
            test.eq((state.entries["app:kept"].data :: {[string]: unknown}).value, "after")
            test.eq((state.entries["app:new"].data :: {[string]: unknown}).value, "new")
            test.is_true(state.entries["old:gone"] == nil)
            test.is_true(materializer.matches_with(api(state), "bee.gov:overlay", desired) == true)

            local stable, stable_error = materializer.reconcile_with(api(state), is_conflict, "bee.gov:overlay", desired)
            if not stable then error(tostring(stable_error)) end
            test.is_false(stable.changed == true)
            test.eq(stable.attempts, 1)
        end)

        test.it("keeps owner selection outside the artifact and returns conflicts for re-preflight", function()
            local state: State = {entries = {}, generation = 1, conflicts = 1}
            local desired = {{id = "app:item", kind = "registry.entry", data = {value = true}}}
            local result = materializer.reconcile_with(api(state), is_conflict, "bee.gov:overlay", desired)
            test.is_true(result == nil)
            test.is_true(state.entries["app:item"] == nil)
            test.is_false(materializer.matches_with(api(state), "bee.gov:overlay", desired) == true)
            local invalid = materializer.reconcile_with(api(state), is_conflict, "", desired)
            test.is_true(invalid == nil)
        end)

        test.it("reconciles and observes an exact empty overlay for cleanup", function()
            local state: State = {entries = { ["app:item"] = {
                id = "app:item", kind = "registry.entry", data = {value = true}}}, generation = 1, conflicts = 0}
            test.is_false(materializer.matches_with(api(state), "bee.gov:overlay", {}) == true)
            local result, result_error = materializer.reconcile_with(api(state), is_conflict,
                "bee.gov:overlay", {})
            if not result then error(tostring(result_error)) end
            test.is_true(result.changed == true)
            test.eq(result.entries, 0)
            test.is_true(result.artifact_digest ~= "")
            test.is_true(next(state.entries) == nil)
            test.is_true(materializer.matches_with(api(state), "bee.gov:overlay", {}) == true)
        end)

        test.it("treats empty artifact and registry metadata as the same object", function()
            local state: State = {entries = { ["app:item"] = {
                id = "app:item", kind = "registry.entry", data = {value = true},
                meta = table.create(0, 1)}}, generation = 1, conflicts = 0}
            local desired = {{id = "app:item", kind = "registry.entry", data = {value = true},
                meta = table.create(1, 0)}}
            test.is_true(materializer.matches_with(api(state), "bee.gov:overlay", desired) == true)
            local result, result_error = materializer.reconcile_with(api(state), is_conflict,
                "bee.gov:overlay", desired)
            if not result then error(tostring(result_error)) end
            test.is_false(result.changed == true)
        end)
        test.it("writes policy, requirement default and grant record in one overlay generation", function()
            local state: State = {entries = {}, generation = 1, conflicts = 0}
            local policy_id = "bee.gov.grants:policy." .. string.rep("a", 64)
            local portable = {{id = "app.notes:app", kind = "process.lua",
                meta = {type = "bee.application"}, data = {source = "return true"}},
                {id = "app.notes:threads", kind = "ns.requirement",
                    meta = {capability = "threads.read", value_kind = "security.policy"},
                    data = {targets = {{entry = "app.notes:app", path = ".security.policies +="}}}}}
            local generated = {policies = {{id = policy_id, kind = "security.policy",
                data = {policy = {actions = {"funcs.call"}, resources = {"bee.threads.service:get"}, effect = "allow"}}}},
                bindings = {{requirement_id = "app.notes:threads", policy_id = policy_id}},
                record = {id = "bee.gov.grants:record." .. string.rep("b", 64),
                    kind = "registry.entry", data = {digest = string.rep("c", 64)}}}
            local applied = assert(materializer.reconcile_composed_with(api(state), is_conflict,
                "bee.gov:overlay", portable, nil, generated))
            test.eq(applied.entries, 2)
            test.eq(applied.overlay_entries, 4)
            test.eq(state.generation, 2)
            test.eq((state.entries["app.notes:threads"].data :: {[string]: unknown}).default, policy_id)
            test.not_nil(state.entries[policy_id])
            test.not_nil(state.entries[generated.record.id])
            test.is_true(materializer.matches_composed_with(api(state), "bee.gov:overlay",
                portable, nil, generated))
            local narrowed = {policies = {}, bindings = {}, record = generated.record}
            assert(materializer.reconcile_composed_with(api(state), is_conflict,
                "bee.gov:overlay", portable, nil, narrowed))
            test.is_nil(state.entries[policy_id])
            test.is_nil((state.entries["app.notes:threads"].data :: {[string]: unknown}).default)
        end)

        test.it("measures and reconciles an overlay entry near the 256 KiB artifact limit", function()
            local state: State = {entries = {}, generation = 1, conflicts = 0}
            local desired = {{id = "app:large", kind = "function.lua",
                data = {source = string.rep("x", artifact.MAX_BYTES - 2048)}}}
            local result, err = materializer.reconcile_with(api(state), is_conflict, "bee.gov:overlay", desired)
            if not result then error(tostring(err)) end
            test.is_true(result.changed == true)
            test.is_true(result.artifact_digest ~= "")
            test.is_true(materializer.matches_with(api(state), "bee.gov:overlay", desired) == true)
        end)

        test.it("stages portable entries and one derived admission in one changeset", function()
            local old = assert(artifact.create({{id = "app:old", kind = "registry.entry", data = {value = "old"}}}))
            local state: State = {entries = {}, generation = 7, conflicts = 0}
            local old_admission = admission_blob(old.digest)
            local old_entry = assert(admission.entry(old_admission.bytes, old_admission.digest))
            state.entries["app:old"] = old.entries[1]
            state.entries[old_entry.id] = old_entry
            local next_artifact = assert(artifact.create({{id = "app:new", kind = "registry.entry", data = {value = "new"}}}))
            local next_admission = admission_blob(next_artifact.digest)
            local result = assert(materializer.reconcile_composed_with(api(state), is_conflict,
                "bee.gov:overlay", next_artifact.entries, next_admission))
            test.eq(result.entries, 1)
            test.eq(result.overlay_entries, 2)
            test.eq(result.artifact_digest, next_artifact.digest)
            test.eq(state.generation, 8)
            test.is_true(state.entries["app:old"] == nil)
            test.not_nil(state.entries["app:new"])
            test.is_true(materializer.matches_composed_with(api(state), "bee.gov:overlay",
                next_artifact.entries, next_admission) == true)
        end)

        test.it("keeps a 512-entry portable artifact measured separately from admission", function()
            local entries: {Entry} = {}
            for index = 1, artifact.MAX_ENTRIES do
                entries[index] = {id = "app:e" .. tostring(index), kind = "registry.entry", data = {value = index}}
            end
            local portable = assert(artifact.create(entries))
            local state: State = {entries = {}, generation = 1, conflicts = 0}
            local result = assert(materializer.reconcile_composed_with(api(state), is_conflict,
                "bee.gov:overlay", portable.entries, admission_blob(portable.digest)))
            test.eq(result.entries, artifact.MAX_ENTRIES)
            test.eq(result.overlay_entries, artifact.MAX_ENTRIES + 1)
            test.eq(result.artifact_digest, portable.digest)
            local count = 0
            for _ in pairs(state.entries) do count = count + 1 end
            test.eq(count, artifact.MAX_ENTRIES + 1)
        end)

        test.it("refuses a portable forgery of the reserved admission prefix", function()
            local state: State = {entries = {}, generation = 1, conflicts = 0}
            local forged = {{id = admission.RESERVED_PREFIX .. "forged", kind = "registry.entry", data = {}}}
            test.is_nil(materializer.reconcile_composed_with(api(state), is_conflict,
                "bee.gov:overlay", forged, nil))
            test.is_true(next(state.entries) == nil)
        end)
    end)
end

return test.run_cases(define_tests)
