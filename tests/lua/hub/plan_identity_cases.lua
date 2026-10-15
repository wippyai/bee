-- MIT. Focused plan test cases.
local test = require("test")
local plan = require("plan")
local identity_decoder = require("identity_decoder")

local support = require("support")
local root = support.root
local state = support.state
local package = support.package
local source = support.source
local request = support.request
local module_for = support.module_for
local M = {}
function M.define()
    test.it("reads the running identity through the host environment fact", function()
        local running, problem = identity_decoder.read_baked()
        test.is_nil(problem); test.not_nil(running)
        if running then test.eq(running.runtime_commit, "v0.1.14-0.20261007011850-2bb9e144ab06") end
    end)
    test.it("rejects malformed or inconsistent executable facts", function()
        for _, raw in ipairs({'bad json', '{}', '{"native_module":"github.com/wippyai/bee/native","native_version":"v2.0.0","native_modules":{"github.com/wippyai/bee/native":"v1.0.0"},"runtime_commit":"v1.0.0"}'}) do
            local running, problem = identity_decoder.decode_baked(raw)
            test.is_nil(running); test.not_nil(problem)
        end
    end)
    for _, changed in ipairs({false, true}) do
        test.it(changed and "requires bindings when a kept version's artifact changes" or "preserves untouched dependency requirement holes", function()
            local captured = state({root("acme/app", "1.0.0"),
                {id = "acme.app:dependency", kind = "ns.dependency", registry = {owner = "acme/app"},
                    data = {component = "acme/lib", version = "1.0.0", parameters = {}}},
            }, {{name = "acme/app", version = "1.0.0", digest = string.rep("a", 64)},
                {name = "acme/lib", version = "1.0.0", digest = string.rep("c", 64)}})
            local targets = {{entry = "acme.lib:main", path = ".database"}}
            local prepared, problem = plan.prepare(captured, 1,
                request({action = "update", component = "acme/app", version = "2.0.0"}), source({
                    ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "b", {
                        {id = "acme.app:dependency", kind = "ns.dependency", meta = {},
                            data = {component = "acme/lib", version = "1.0.0", parameters = {}}}}),
                    ["acme/lib@1.0.0"] = package("acme/lib", "1.0.0", changed and "d" or "c", {
                        {id = "acme.lib:database", kind = "ns.requirement", meta = {}, data = {targets = targets}},
                        {id = "acme.lib:main", kind = "registry.entry", meta = {}, data = {}},
                    }),
                }))
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then
                test.eq(prepared.plan.ready, not changed)
                test.eq(#prepared.plan.missing, changed and 1 or 0)
            end
        end)
    end
    for _, constraint in ipairs({"*", ">=0.4.0 <0.5.0", ">=0.4.6", "0.4.6"}) do
        test.it("predicts runtime installed selection for " .. constraint, function()
            local captured = state({root("acme/app", "1.0.0"),
                {id = "acme.app:test", kind = "ns.dependency", registry = {owner = "acme/app"},
                    data = {component = "wippy/test", version = "0.4.17"}},
                {id = "wippy.test:terminal", kind = "ns.dependency", registry = {owner = "wippy/test"},
                    data = {component = "wippy/terminal", version = "*"}},
            }, {{name = "acme/app", version = "1.0.0"}, {name = "wippy/test", version = "0.4.17"},
                {name = "wippy/terminal", version = "0.4.5"}})
            -- The live selection, rather than the shipped lock, is preferred.
            captured.resolution = {modules = {{name = "acme/app", version = "1.0.0"},
                {name = "wippy/test", version = "0.4.17"}, {name = "wippy/terminal", version = "0.4.5"}},
                lock = {root_module = "", modules = {{name = "wippy/terminal", version = "0.4.4"}}}}
            local artifacts = source({
                ["acme/app@2.0.0"] = package("acme/app", "2.0.0", "a", {
                    {id = "acme.app:test", kind = "ns.dependency", meta = {},
                        data = {component = "wippy/test", version = "0.4.17"}},
                    {id = "acme.app:terminal", kind = "ns.dependency", meta = {},
                        data = {component = "wippy/terminal", version = constraint}},
                }),
                ["wippy/test@0.4.17"] = package("wippy/test", "0.4.17", "b", {
                    {id = "wippy.test:terminal", kind = "ns.dependency", meta = {},
                        data = {component = "wippy/terminal", version = "*"}},
                }),
                ["wippy/terminal@0.4.5"] = package("wippy/terminal", "0.4.5", "c"),
                ["wippy/terminal@0.4.6"] = package("wippy/terminal", "0.4.6", "d"),
            })
            local lists = 0
            artifacts.versions = function(_: string, _: integer): ({string}?, boolean?, string?)
                lists = lists + 1; return {"0.4.6", "0.4.5"}, false, nil
            end
            local prepared, problem = plan.prepare(captured, 4,
                request({action = "update", component = "acme/app", version = "2.0.0"}), artifacts)
            test.is_nil(problem); test.not_nil(prepared)
            if prepared then
                local terminal = module_for(prepared.plan.modules, "wippy/terminal")
                test.not_nil(terminal)
                if terminal then
                    local kept = constraint == "*" or constraint == ">=0.4.0 <0.5.0"
                    test.eq(terminal.version, kept and "0.4.5" or "0.4.6")
                    test.eq(terminal.change, kept and "keep" or "update")
                    if kept then test.eq(lists, 0) end
                end
            end
        end)
    end
end
return M
