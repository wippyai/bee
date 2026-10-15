-- MIT. Focused plan test cases.
local test = require("test")
local plan = require("plan")
local review = require("review")
local graph = require("graph")
local inspect = require("inspect")
local requirements = require("requirements")
local identity_decoder = require("identity_decoder")

local support = require("support")
local root = support.root
local state = support.state
local binary_identity = support.binary_identity
local package = support.package
local source = support.source
local request = support.request
local module_for = support.module_for
local function define_tests()
    test.describe("Hub dependency plan", function()
        test.it("summarizes running migrations and changed permissions without rewriting the plan", function()
            local db = {id = "acme:db", kind = "db.sql.sqlite", meta = {}, data = {file = "fixture.db"}, registry = {owner = "acme/app"}}
            local reader = {id = "acme:reader", kind = "security.policy", meta = {}, data = {policy = {actions = {"read"}, resources = {"acme:*"}}}, registry = {owner = "acme/app"}}
            local installed = state({root("acme/app", "1.0.0"), db, reader}, {{name = "acme/app", version = "1.0.0", source = "hub"}})
            local artifacts = source({["acme/app@2.0.0"] = package("acme/app", "2.0.0", "a", {
                {id = "acme:db", kind = "db.sql.sqlite", meta = {}, data = {file = "fixture.db"}},
                {id = "acme:reader", kind = "security.policy", meta = {}, data = reader.data},
                {id = "acme:writer", kind = "security.policy", meta = {}, data = {policy = {actions = {"write"}, resources = {"acme:*"}}}},
                {id = "acme:logic", kind = "library.lua", meta = {}, data = {source = "changed"}},
                {id = "acme:old", kind = "function.lua", meta = {type = "migration", target_db = "acme:db", timestamp = "1"}, data = {}},
                {id = "acme:new", kind = "function.lua", meta = {type = "migration", target_db = "acme:db", timestamp = "2"}, data = {}},
            })})
            for _, policy in ipairs({"none", "up"}) do
                local prepared = assert(plan.prepare(installed, 1, request({action = "update", component = "acme/app", version = "2.0.0", migration_policy = policy}), artifacts))
                local digest, definitions = prepared.plan.digest, #prepared.plan.migrations
                local calls = 0
                local summary = assert(review.summarize(prepared, prepared.baseline, function(_: string, id: string): (boolean?, string?)
                    calls = calls + 1; return id == "acme:old", nil
                end))
                test.eq(#summary.migration_runs, policy == "up" and 1 or 0)
                test.eq(calls, policy == "up" and 2 or 0)
                if policy == "up" then test.eq(summary.migration_runs[1].id, "acme:new") end
                test.eq(#summary.policy_changes, 1)
                test.eq(summary.policy_changes[1].id, "acme:writer")
                test.eq(summary.other_entries, 1)
                test.eq(prepared.plan.digest, digest)
                test.eq(#prepared.plan.migrations, definitions)
                if policy == "up" then
                    local failed, problem = review.summarize(prepared, prepared.baseline, function(_: string, _: string): (boolean?, string?) return nil, "ledger denied" end)
                    test.is_nil(failed); test.eq(problem, "ledger denied")
                end
            end
        end)
        test.it("revalidates registry state using the verified artifact definitions", function()
            local selected = package("vendor/widget", "1.0.0", "a", {
                {id = "widget:value", kind = "registry.entry", meta = {}, data = {value = "approved"}},
            })
            local reads = 0
            local original = source({["vendor/widget@1.0.0"] = selected})
            local read_artifact = original.artifact
            original.artifact = function(component: string, version: string): (inspect.Inspection?, string?)
                reads = reads + 1
                return read_artifact(component, version)
            end
            local req = request({action = "install", component = "vendor/widget", version = "1.0.0"})
            local prepared = assert(plan.prepare(state({}), 1, req, original))
            local fresh = state({
                {id = "receipt:operation", kind = "registry.entry", meta = {}, data = {}, registry = {owner = ""}},
            })
            local rebased = assert(plan.rebase(prepared, fresh, 2))
            test.eq(rebased.baseline, fresh)
            test.eq(assert(review.summarize(rebased, rebased.baseline, function(_: string, _: string): (boolean?, string?)
                return false, nil
            end)).other_entries, 1)
            test.eq(reads, 1)
            test.eq(rebased.plan.base_revision, 2)
            test.eq(rebased.resolved.packages[1].digest, prepared.resolved.packages[1].digest)
            local data = rebased.resolved.packages[1].entries[1].data
            assert(type(data) == "table")
            test.eq(data.value, "approved")
            test.is_true(rebased.plan.digest ~= prepared.plan.digest)
            local unavailable = plan.rebase(prepared, state({root("vendor/other", "1.0.0")}, {
                {name = "vendor/other", version = "1.0.0", digest = string.rep("b", 64)},
            }), 3)
            test.is_nil(unavailable)
            test.eq(reads, 1)
        end)
        for _, matches in ipairs({true, false}) do
            test.it(matches and "plans a pack matching decoded executable facts" or "refuses another runtime commit from executable facts", function()
                local running, decode_error = identity_decoder.decode_baked('{"native_module":"github.com/wippyai/bee/native","native_version":"v1.0.0","native_modules":{"github.com/wippyai/bee/native":"v1.0.0"},"runtime_commit":"v0.1.14-0.20261007011850-2bb9e144ab06"}')
                test.is_nil(decode_error); test.not_nil(running)
                local entry = binary_identity("github.com/wippyai/bee/native", "v1.0.0")
                entry.data.runtime_commit = matches and "v0.1.14-0.20261007011850-2bb9e144ab06" or "v0.1.14-0.20261004132348-0ba471579107"
                local prepared, problem = plan.prepare(state({root("bee/bee", "1.0.0")}), 1,
                    request({action = "update", component = "bee/bee", version = "2.0.0"}),
                    source({["bee/bee@2.0.0"] = package("bee/bee", "2.0.0", "a", {entry})}), running)
                if matches then test.is_nil(problem); test.not_nil(prepared)
                else test.is_nil(prepared); test.is_true(tostring(problem):find("needs a newer Bee binary", 1, true) ~= nil) end
            end)
        end
        require("plan_identity_cases").define()
        test.it("reselects an installed candidate when a later diamond constraint rejects it", function()
            local artifacts = source({
                ["acme/root@1.0.0"] = package("acme/root", "1.0.0", "a", {
                    {id = "acme.root:shared", kind = "ns.dependency", meta = {}, data = {component = "acme/shared", version = "*"}},
                    {id = "acme.root:z", kind = "ns.dependency", meta = {}, data = {component = "acme/z", version = "1.0.0"}},
                }),
                ["acme/z@1.0.0"] = package("acme/z", "1.0.0", "b", {
                    {id = "acme.z:shared", kind = "ns.dependency", meta = {}, data = {component = "acme/shared", version = ">=2.0.0"}},
                }),
                ["acme/shared@1.0.0"] = package("acme/shared", "1.0.0", "c", {
                    {id = "acme.shared:old", kind = "ns.dependency", meta = {}, data = {component = "acme/old", version = "1.0.0"}},
                }),
                ["acme/shared@2.0.0"] = package("acme/shared", "2.0.0", "d"),
                ["acme/old@1.0.0"] = package("acme/old", "1.0.0", "e"),
            })
            artifacts.versions = function(_: string, _: integer): ({string}?, boolean?, string?) return {"2.0.0", "1.0.0"}, false, nil end
            local resolved, problem = graph.resolve({{component = "acme/root", version = "1.0.0", parameters = {}}},
                artifacts, {["acme/shared"] = "1.0.0"})
            test.is_nil(problem); test.not_nil(resolved)
            if resolved then
                test.eq(#resolved.packages, 3)
                test.eq(resolved.packages[2].component, "acme/shared")
                test.eq(resolved.packages[2].version, "2.0.0")
            end
        end)
        test.it("uses runtime stable-release preference and does not backtrack a parent to satisfy its children", function()
            local artifacts = source({
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a"),
                ["acme/app@2.0.0-beta"] = package("acme/app", "2.0.0-beta", "b"),
                ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "c", {
                    {id = "acme.app:child", kind = "ns.dependency", meta = {}, data = {component = "acme/child", version = "1.0.0"}},
                }),
            })
            artifacts.versions = function(name: string, _: integer): ({string}?, boolean?, string?)
                if name == "acme/app" then return {"2.0.0-beta", "1.0.0"}, false, nil end
                return {}, false, nil
            end
            local resolved, problem = graph.resolve({{component = "acme/app", version = ">=1.0.0 || >=2.0.0-beta", parameters = {}}}, artifacts)
            test.is_nil(problem); test.not_nil(resolved)
            if resolved then test.eq(resolved.packages[1].version, "1.0.0") end
            artifacts.versions = function(name: string, _: integer): ({string}?, boolean?, string?)
                if name == "acme/app" then return {"2.0.0", "1.0.0"}, false, nil end
                return {}, false, nil
            end
            -- Only the lower parent has a satisfiable closure. Runtime still
            -- chooses 2.0.0 and reports its missing child rather than downgrading.
            test.is_nil((graph.resolve({{component = "acme/app", version = "*", parameters = {}}}, artifacts)))
        end)
        test.it("measures a large policy closure without the message encoder limit", function()
            local entries: {inspect.Entry} = {}
            for index = 1, 200 do
                entries[index] = {id = "acme.large:policy_" .. tostring(index), kind = "security.policy",
                    meta = {}, data = {policy = {actions = {"registry.get"}, resources = {"acme.large:*"}, effect = "allow"}}}
            end
            local selected = request({action = "install", component = "acme/large", version = "1.0.0"})
            local prepared, problem = plan.prepare(state({}), 1, selected,
                source({["acme/large@1.0.0"] = package("acme/large", "1.0.0", "a", entries)}))
            test.is_nil(problem)
            test.not_nil(prepared)
            if not prepared then return end
            test.eq(#prepared.plan.policy_changes, 200)
            test.eq(#prepared.plan.digest, 64)
            entries[200].data = {policy = {actions = {"registry.apply"}, resources = {"acme.large:*"}, effect = "allow"}}
            local changed, changed_error = plan.prepare(state({}), 1, selected,
                source({["acme/large@1.0.0"] = package("acme/large", "1.0.0", "a", entries)}))
            test.is_nil(changed_error)
            test.not_nil(changed)
            if changed then test.eq(changed.plan.digest == prepared.plan.digest, false) end
        end)

        require("plan_components_cases").define()
        require("plan_native_cases").define()
        test.it("binds digest to the captured base revision and selected artifact", function()
            local req = request({action = "install", component = "acme/app", version = "1.0.0"})
            local first, first_problem = plan.prepare(state({}), 7, req,
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            local moved, moved_problem = plan.prepare(state({}), 8, req,
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a")}))
            local changed, changed_problem = plan.prepare(state({}), 7, req,
                source({["acme/app@1.0.0"] = package("acme/app", "1.0.0", "b")}))
            test.is_nil(first_problem); test.is_nil(moved_problem); test.is_nil(changed_problem)
            test.not_nil(first); test.not_nil(moved); test.not_nil(changed)
            if first and moved and changed then
                test.eq(first.plan.base_revision, 7)
                test.eq(moved.plan.base_revision, 8)
                test.neq(first.plan.digest, moved.plan.digest)
                test.neq(first.plan.digest, changed.plan.digest)
            end
        end)

        test.it("preserves other Hub roots across update and uninstall", function()
            local app_root = root("acme/app", "1.0.0")
            local other_root = root("acme/other", "1.0.0")
            local installed = state({app_root, other_root}, {
                {name = "acme/app", version = "1.0.0", source = "hub"},
                {name = "acme/other", version = "1.0.0", source = "hub"},
            })
            local artifacts = source({
                ["acme/app@1.1.0"] = package("acme/app", "1.1.0", "a"),
                ["acme/other@1.0.0"] = package("acme/other", "1.0.0", "b"),
            })
            local update, update_problem = plan.prepare(installed, 3,
                request({action = "update", component = "acme/app", version = "1.1.0"}), artifacts)
            local uninstall, uninstall_problem = plan.prepare(installed, 3,
                request({action = "uninstall", component = "acme/app"}), artifacts)
            test.is_nil(update_problem); test.is_nil(uninstall_problem)
            test.not_nil(update); test.not_nil(uninstall)
            if update then
                local app, other = module_for(update.plan.modules, "acme/app"), module_for(update.plan.modules, "acme/other")
                test.not_nil(app); test.not_nil(other)
                if app then test.eq(app.change, "update") end
                if other then test.eq(other.change, "keep") end
            end
            if uninstall then
                local removed, retained = module_for(uninstall.plan.modules, "acme/app"), module_for(uninstall.plan.modules, "acme/other")
                test.not_nil(removed); test.not_nil(retained)
                if removed then test.eq(removed.change, "remove") end
                if retained then test.eq(retained.change, "keep") end
            end
        end)

        test.it("lists the security policies an update and an uninstall add, replace and remove", function()
            local function policy(id: string, owner: string, actions: {string}, resources: unknown): {[string]: unknown}
                return {id = id, kind = "security.policy", registry = {owner = owner, root = false},
                    data = {policy = {actions = actions, resources = resources, effect = "allow"}}}
            end
            local installed = state({
                root("acme/app", "1.0.0"),
                root("acme/other", "1.0.0"),
                policy("acme.app:reader", "acme/app", {"fs.get"}, {"acme.app:files"}),
                policy("acme.app:legacy", "acme/app", {"registry.get"}, "*"),
                policy("acme.other:reader", "acme/other", {"fs.get"}, {"acme.other:files"}),
            }, {
                {name = "acme/app", version = "1.0.0", source = "hub"},
                {name = "acme/other", version = "1.0.0", source = "hub"},
            })
            local artifacts = source({
                ["acme/app@1.1.0"] = package("acme/app", "1.1.0", "a", {
                    {id = "acme.app:reader", kind = "security.policy", meta = {},
                        data = {policy = {actions = {"fs.get", "fs.list"}, resources = {"acme.app:files"}, effect = "allow"}}},
                    {id = "acme.app:writer", kind = "security.policy.expr", meta = {},
                        data = {policy = {actions = {"fs.put"}, resources = "*", expression = "true", effect = "allow"}}},
                }),
                ["acme/other@1.0.0"] = package("acme/other", "1.0.0", "b", {
                    {id = "acme.other:reader", kind = "security.policy", meta = {},
                        data = {policy = {actions = {"fs.get"}, resources = {"acme.other:files"}, effect = "allow"}}},
                }),
            })
            local update, update_problem = plan.prepare(installed, 4,
                request({action = "update", component = "acme/app", version = "1.1.0"}), artifacts)
            test.is_nil(update_problem)
            test.not_nil(update)
            if update then
                local changes = update.plan.policy_changes
                test.eq(#changes, 3)
                test.eq(changes[1].id, "acme.app:legacy"); test.eq(changes[1].change, "remove")
                test.eq(changes[1].resources[1], "*"); test.eq(changes[1].actions[1], "registry.get")
                test.eq(changes[2].id, "acme.app:reader"); test.eq(changes[2].change, "update")
                test.eq(changes[2].actions[2], "fs.list"); test.eq(changes[2].component, "acme/app")
                test.eq(changes[3].id, "acme.app:writer"); test.eq(changes[3].change, "add")
                test.is_true(changes[3].expression)
            end
            local uninstall, uninstall_problem = plan.prepare(installed, 4,
                request({action = "uninstall", component = "acme/app"}), artifacts)
            test.is_nil(uninstall_problem)
            test.not_nil(uninstall)
            if uninstall then
                local changes = uninstall.plan.policy_changes
                test.eq(#changes, 2)
                test.eq(changes[1].id, "acme.app:legacy"); test.eq(changes[1].change, "remove")
                test.eq(changes[2].id, "acme.app:reader"); test.eq(changes[2].change, "remove")
            end
        end)

        test.it("refuses package entries that collide with another registry owner", function()
            local prepared, problem = plan.prepare(state({
                {id = "acme.app:entry", kind = "library.lua", registry = {owner = "other/module", root = false}},
            }), 1, request({action = "install", component = "acme/app", version = "1.0.0"}), source({
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a",
                    {{id = "acme.app:entry", kind = "library.lua", meta = {}, data = {}}}),
            }))
            test.is_nil(prepared)
            test.not_nil(problem)
        end)

        test.it("carries requested parameters into the selected package requirements", function()
            local prepared, problem = plan.prepare(state({}), 1,
                request({action = "install", component = "acme/app", version = "1.0.0",
                    parameters = {{name = "acme.app:port", value = 8080}}}), source({
                    ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "a", {
                        {id = "acme.app:port", kind = "ns.requirement", meta = {},
                            data = {targets = {{entry = "acme.app:main", path = "settings.port"}}}},
                        {id = "acme.app:main", kind = "library.lua", meta = {}, data = {}},
                    }, {requirements = {{
                        id = "acme.app:port", has_default = false, has_selected = false,
                        targets = {{entry = "acme.app:main", path = "settings.port"}},
                    }}, missing = {"acme.app:port"}}),
                }))
            test.is_nil(problem)
            test.not_nil(prepared)
            if prepared then
                local item = prepared.plan.modules[1]
                test.eq(item.requirements.requirements[1].id, "acme.app:port")
                test.is_true(item.requirements.requirements[1].has_selected)
                test.eq(item.requirements.requirements[1].selected, 8080)
                test.is_true(prepared.plan.ready)
            end
        end)
    end)
end

return test.run_cases(define_tests)
