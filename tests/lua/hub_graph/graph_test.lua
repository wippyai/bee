-- MIT. Candidate retrieval matters: exact pins must not list release history.
local test = require("test")
local graph = require("graph")
local inspect = require("inspect")
local function edge(name: string, version: string): graph.Edge
    return {component = name, version = version, parameters = {}}
end
local function artifact(name: string, version: string, dependencies: {graph.Edge}): inspect.Inspection
    local entries: {inspect.Entry} = {}
    for i, dep in ipairs(dependencies) do
        entries[#entries + 1] = {id = name:gsub("/", ".") .. ":dep" .. tostring(i), kind = "ns.dependency", meta = {}, data = dep}
    end
    return {component = name, version = version, digest = string.rep("a", 64), entries = entries,
        requirements = {requirements = {}, missing = {}}}
end
local function define_tests()
    test.describe("Hub dependency graph", function()
        test.it("opens exact pins without requesting any release history", function()
            local calls = 0
            local result, problem = graph.resolve({edge("acme/app", "1.0.0")}, {
                versions = function(name: string, page: integer): ({string}?, boolean?, string?)
                    calls = calls + 1; return nil, nil, "must not list"
                end,
                artifact = function(name: string, version: string): (inspect.Inspection?, string?)
                    return artifact(name, version, {}), nil
                end,
            })
            test.is_nil(problem); test.not_nil(result); test.eq(calls, 0)
            if result then test.eq(result.packages[1].version, "1.0.0") end
        end)
        test.it("stops paging when a compatible candidate succeeds", function()
            local calls = 0
            local result, problem = graph.resolve({edge("acme/app", "^1.0.0")}, {
                versions = function(name: string, page: integer): ({string}?, boolean?, string?)
                    calls = calls + 1
                    if page == 1 then return {"2.0.0"}, true, nil end
                    if page == 2 then return {"1.9.0", "1.8.0"}, true, nil end
                    return nil, nil, "must not fetch the rest of history"
                end,
                artifact = function(name: string, version: string): (inspect.Inspection?, string?)
                    return artifact(name, version, {}), nil
                end,
            })
            test.is_nil(problem); test.not_nil(result); test.eq(calls, 2)
            if result then test.eq(result.packages[1].version, "1.9.0") end
        end)
        test.it("backtracks a diamond and discards dependencies of the rejected version", function()
            local result, problem = graph.resolve({edge("acme/root", "1.0.0")}, {
                versions = function(name: string, page: integer): ({string}?, boolean?, string?)
                    if name == "acme/shared" then return {"2.0.0", "1.0.0"}, false, nil end
                    return nil, nil, "unexpected list " .. name
                end,
                artifact = function(name: string, version: string): (inspect.Inspection?, string?)
                    local deps: {graph.Edge} = {}
                    if name == "acme/root" then deps = {edge("acme/shared", ">=1.0.0"), edge("acme/z", "1.0.0")}
                    elseif name == "acme/z" then deps = {edge("acme/shared", "<2.0.0")}
                    elseif name == "acme/shared" and version == "2.0.0" then deps = {edge("acme/y", "1.0.0")} end
                    return artifact(name, version, deps), nil
                end,
            })
            test.is_nil(problem); test.not_nil(result)
            if not result then return end
            test.eq(#result.packages, 3)
            test.eq(result.packages[2].component, "acme/shared")
            test.eq(result.packages[2].version, "1.0.0")
        end)
        test.it("refuses incompatible exact incoming pins without downloading candidates", function()
            local reads = 0
            local result, problem = graph.resolve({edge("acme/app", "1.0.0"), edge("acme/app", "2.0.0")}, {
                versions = function(name: string, page: integer): ({string}?, boolean?, string?) return {}, false, nil end,
                artifact = function(name: string, version: string): (inspect.Inspection?, string?)
                    reads = reads + 1; return artifact(name, version, {}), nil
                end,
            })
            test.is_nil(result); test.not_nil(problem); test.eq(reads, 0)
        end)
        test.it("rejects duplicate entry ownership across a dependency closure", function()
            local result, problem = graph.resolve({edge("acme/one", "1.0.0"), edge("acme/two", "1.0.0")}, {
                versions = function(name: string, page: integer): ({string}?, boolean?, string?) return {}, false, nil end,
                artifact = function(name: string, version: string): (inspect.Inspection?, string?)
                    return {component = name, version = version, digest = string.rep("a", 64),
                        entries = {{id = "acme:collision", kind = "registry.entry", meta = {}, data = {}}},
                        requirements = {requirements = {}, missing = {}}}, nil
                end,
            })
            test.is_nil(result); test.not_nil(problem)
        end)
    end)
end
return test.run_cases(define_tests)
