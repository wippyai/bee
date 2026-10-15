-- MIT. Focused plan test cases.
local test = require("test")
local plan = require("plan")
local support = require("support")
local root = support.root
local state = support.state
local binary_identity = support.binary_identity
local baked_identity = support.baked_identity
local package = support.package
local source = support.source
local request = support.request
local module_for = support.module_for
local M = {}
function M.define()
    test.it("updates the existing Bee deployment root and resolves its pack closure", function()
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local application = {id = "bee:dependency_application", kind = "ns.dependency", registry = {owner = "bee/bee", root = true},
            data = {component = "bee/application", version = "0.1.0"}}
        local installed = state({deployment, application, root("acme/app", "1.0.0")}, {
            {name = "bee/bee", version = "0.1.0", source = "hub"},
            {name = "bee/application", version = "0.1.0", source = "hub"},
            {name = "acme/app", version = "1.0.0", source = "hub"},
        })
        local prepared, problem = plan.prepare(installed, 12,
            request({action = "update", component = "bee/bee", version = "0.2.0"}),
            source({
                ["bee/bee@0.2.0"] = package("bee/bee", "0.2.0", "a", {
                    {id = "bee:dependency_application", kind = "ns.dependency", meta = {},
                        data = {component = "bee/application", version = "0.2.0"}},
                    binary_identity("github.com/wippyai/bee/native", "v0.0.0-20260926183503-c0d6585b5fd1"),
                }),
                ["bee/application@0.2.0"] = package("bee/application", "0.2.0", "b"),
                ["acme/app@1.0.0"] = package("acme/app", "1.0.0", "c"),
            }), baked_identity("v0.0.0-20260926183503-c0d6585b5fd1"))
        test.is_nil(problem)
        test.not_nil(prepared)
        if prepared then
            test.eq(prepared.plan.root_id, "bee:deployment")
            test.eq(prepared.plan.root_operation, "update")
            local bee, application, third_party = module_for(prepared.plan.modules, "bee/bee"),
                module_for(prepared.plan.modules, "bee/application"), module_for(prepared.plan.modules, "acme/app")
            test.not_nil(bee); test.not_nil(application); test.not_nil(third_party)
            if bee then test.eq(bee.change, "update") end
            if application then test.eq(application.change, "update") end
            if third_party then test.eq(third_party.change, "keep") end
        end
    end)

    test.it("checks target packs against host binary facts rather than live root metadata", function()
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local current = "v0.0.0-20260926183503-c0d6585b5fd1"
        local identity = binary_identity("github.com/wippyai/bee/native/launch", "v0.0.0-20260925183503-c0d6585b5fd1")
        identity.registry = {owner = "bee/bee"}
        local target_identity = binary_identity("github.com/wippyai/bee/native/launch", current)
        target_identity.registry = nil
        local prepared, problem = plan.prepare(state({deployment, identity}, {
            {name = "bee/bee", version = "0.1.0", source = "hub"},
        }), 12, request({action = "update", component = "bee/bee", version = "0.2.0"}),
            source({["bee/bee@0.2.0"] = package("bee/bee", "0.2.0", "a", {target_identity})}), baked_identity(current))
        test.is_nil(problem)
        test.not_nil(prepared)
    end)

    test.it("refuses a Bee pack closure that requires a newer native binary", function()
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local current = "v0.0.0-20260926183503-c0d6585b5fd1"
        local required = "v0.0.0-20260928183503-c0d6585b5fd1"
        local root_package = package("bee/bee", "0.2.0", "d", {
            {id = "bee:definition", kind = "ns.definition", meta = {native_requirements = {
                {package = "github.com/wippyai/bee/native/launch", version = required}}}, data = {}},
            binary_identity("github.com/wippyai/bee/native/launch", current),
        })
        local installed = state({deployment, binary_identity("github.com/wippyai/bee/native/launch", current)}, {
            {name = "bee/bee", version = "0.1.0", source = "local"},
        })
        local prepared, problem = plan.prepare(installed, 12,
            request({action = "update", component = "bee/bee", version = "0.2.0"}),
            source({["bee/bee@0.2.0"] = root_package}), baked_identity(current))
        test.is_nil(prepared)
        test.eq(problem, "needs a newer Bee binary: bee/bee requires native component github.com/wippyai/bee/native/launch v0.0.0-20260928183503-c0d6585b5fd1; this binary has v0.0.0-20260926183503-c0d6585b5fd1")
    end)

    test.it("accepts a Bee pack closure within the baked native manifest", function()
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local current = "v0.0.0-20260926183503-c0d6585b5fd1"
        local root_package = package("bee/bee", "0.2.0", "e", {
            {id = "bee:definition", kind = "ns.definition", meta = {native_requirements = {
                {package = "github.com/wippyai/bee/native/launch", version = current}}}, data = {}},
            binary_identity("github.com/wippyai/bee/native/launch", current),
        })
        local installed = state({deployment, binary_identity("github.com/wippyai/bee/native/launch", current)}, {
            {name = "bee/bee", version = "0.1.0", source = "local"},
        })
        local prepared, problem = plan.prepare(installed, 12,
            request({action = "update", component = "bee/bee", version = "0.2.0"}),
            source({["bee/bee@0.2.0"] = root_package}), baked_identity(current))
        test.is_nil(problem)
        test.not_nil(prepared)
    end)

    test.it("refuses a Bee root pack built for a newer native manifest", function()
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local current = "v0.0.0-20260926183503-c0d6585b5fd1"
        local target = "v0.0.0-20260928183503-c0d6585b5fd1"
        local root_package = package("bee/bee", "0.2.0", "d", {
            binary_identity("github.com/wippyai/bee/native/launch", target),
        })
        local installed = state({deployment, binary_identity("github.com/wippyai/bee/native/launch", current)}, {
            {name = "bee/bee", version = "0.1.0", source = "hub"},
        })
        local prepared, problem = plan.prepare(installed, 12,
            request({action = "update", component = "bee/bee", version = "0.2.0"}),
            source({["bee/bee@0.2.0"] = root_package}), baked_identity(current))
        test.is_nil(prepared)
        test.eq(problem, "needs a newer Bee binary: bee/bee pack set requires native component github.com/wippyai/bee/native/launch v0.0.0-20260928183503-c0d6585b5fd1; this binary has v0.0.0-20260926183503-c0d6585b5fd1")
    end)

    test.it("updates a Bee pack that declares no native needs without the running binary's identity", function()
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local target = package("bee/bee", "0.2.0", "a", {
            {id = "bee:definition", kind = "ns.definition", meta = {}, data = {}},
        })
        local prepared, problem = plan.prepare(state({deployment}, {{name = "bee/bee", version = "0.1.0", source = "hub"}}), 12,
            request({action = "update", component = "bee/bee", version = "0.2.0"}), source({["bee/bee@0.2.0"] = target}))
        test.is_nil(problem)
        test.not_nil(prepared)
    end)

    test.it("fails closed when the running binary's identity is unavailable", function()
        local required = "v0.0.0-20260926183503-c0d6585b5fd1"
        local target = package("bee/bee", "0.2.0", "a", {
            {id = "bee:definition", kind = "ns.definition", meta = {native_requirements = {
                {package = "github.com/wippyai/bee/native/launch", version = required}}}, data = {}},
            binary_identity("github.com/wippyai/bee/native/launch", required),
        })
        local deployment = {id = "bee:deployment", kind = "ns.dependency", registry = {owner = "", root = true},
            data = {component = "bee/bee", version = "0.1.0", parameters = {}}}
        local prepared, problem = plan.prepare(state({deployment}, {{name = "bee/bee", version = "0.1.0", source = "local"}}), 12,
            request({action = "update", component = "bee/bee", version = "0.2.0"}), source({["bee/bee@0.2.0"] = target}))
        test.is_nil(prepared)
        test.eq(problem, "needs a newer Bee binary: running binary native manifest is unavailable")
    end)

end
return M
