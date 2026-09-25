-- MIT. Comparison uses effective operation and scope, including template meaning.
local test = require("test")
local containment = require("capability_containment")
type Object = {[string]: unknown}
local function grant(capability: string, operation: string, resource: string, scope: Object, revision: integer): Object
    return {capability = capability, template_revision = revision, operation = operation,
        resource = resource, scope = scope, parameters = scope}
end
local function compare(old: {Object}, new: {Object}): Object
    return assert(containment.compare(old, new)) :: Object
end
local function define_tests()
    test.describe("Capability containment", function()
        test.it("classifies added, removed and prefix path narrowing without sibling leakage", function()
            local old = grant("workspace.files.read", "files.read", "workspace-1", {subpath = "docs"}, 1)
            local child = grant("workspace.files.read", "files.read", "workspace-1", {subpath = "docs/api"}, 1)
            local sibling = grant("workspace.files.read", "files.read", "workspace-1", {subpath = "docs2"}, 1)
            test.eq(#(compare({old}, {child}).narrowed :: {unknown}), 1)
            test.eq(#(compare({child}, {old}).widened :: {unknown}), 1)
            test.eq(#(compare({old}, {sibling}).added :: {unknown}), 1)
            test.eq(#(compare({old}, {sibling}).removed :: {unknown}), 1)
            test.eq(#(compare({}, {old}).added :: {unknown}), 1)
            test.eq(#(compare({old}, {}).removed :: {unknown}), 1)
        end)
        test.it("compares method and definition sets at exact identities", function()
            local old = grant("contract.call", "contract.call", "app:binding", {methods = {"get"}}, 1)
            local wide = grant("contract.call", "contract.call", "app:binding", {methods = {"get", "put"}}, 1)
            test.eq(#(compare({old}, {wide}).widened :: {unknown}), 1)
            test.eq(#(compare({wide}, {old}).narrowed :: {unknown}), 1)
            local other = grant("contract.call", "contract.call", "other:binding", {methods = {"get"}}, 1)
            test.eq(#(compare({old}, {other}).added :: {unknown}), 1)
            local agents = grant("agents.launch", "agents.launch", "workspace-1", {definitions = {"a:one"}}, 1)
            local more = grant("agents.launch", "agents.launch", "workspace-1", {definitions = {"a:one", "a:two"}}, 1)
            test.eq(#(compare({agents}, {more}).widened :: {unknown}), 1)
        end)
        test.it("compares the union of effective grants without treating redundant requests as widening", function()
            local broad = grant("workspace.files.read", "files.read", "workspace-1", {subpath = "docs"}, 1)
            local child = grant("workspace.files.read", "files.read", "workspace-1", {subpath = "docs/api"}, 1)
            local paths = compare({broad}, {broad, child})
            test.eq(#(paths.added :: {unknown}), 0)
            test.eq(#(paths.narrowed :: {unknown}), 0)
            test.is_false(paths.requires_approval)
            local both = grant("contract.call", "contract.call", "app:binding", {methods = {"get", "put"}}, 1)
            local get = grant("contract.call", "contract.call", "app:binding", {methods = {"get"}}, 1)
            local put = grant("contract.call", "contract.call", "app:binding", {methods = {"put"}}, 1)
            local split = compare({both}, {get, put})
            test.eq(#(split.added :: {unknown}), 0)
            test.eq(#(split.removed :: {unknown}), 0)
            test.eq(#(split.narrowed :: {unknown}), 0)
        end)
        test.it("treats origin changes and template revisions as changed meaning", function()
            local old = grant("http.api", "http.request", "https://one.example", {methods = {"GET"}, path_prefix = "/v1"}, 1)
            local new = grant("http.api", "http.request", "https://two.example", {methods = {"GET"}, path_prefix = "/v1"}, 1)
            test.eq(#(compare({old}, {new}).added :: {unknown}), 1)
            test.eq(#(compare({old}, {new}).removed :: {unknown}), 1)
            new.resource = old.resource
            new.template_revision = 2
            test.eq(#(compare({old}, {new}).changed :: {unknown}), 1)
            test.is_true(compare({old}, {new}).requires_approval)
        end)
        test.it("contains HTTP methods and path prefixes only within one origin", function()
            local old = grant("http.api", "http.request", "https://api.example.com",
                {methods = {"GET", "POST"}, path_prefix = "/v1"}, 1)
            local narrow = grant("http.api", "http.request", "https://api.example.com",
                {methods = {"GET"}, path_prefix = "/v1/users"}, 1)
            test.eq(#(compare({old}, {narrow}).narrowed :: {unknown}), 1)
            test.eq(#(compare({narrow}, {old}).widened :: {unknown}), 1)
            local sibling = grant("http.api", "http.request", "https://api.example.com",
                {methods = {"GET"}, path_prefix = "/v11"}, 1)
            test.eq(#(compare({old}, {sibling}).added :: {unknown}), 1)
            local other_workspace = grant("workspace.files.read", "files.read", "workspace-2",
                {subpath = "docs"}, 1)
            local first_workspace = grant("workspace.files.read", "files.read", "workspace-1",
                {subpath = "docs"}, 1)
            test.eq(#(compare({first_workspace}, {other_workspace}).added :: {unknown}), 1)
        end)
        test.it("rejects malformed sets before comparing", function()
            local bad = grant("http.api", "http.request", "https://one.example", {methods = {"GET", "GET"}}, 1)
            test.is_nil(containment.compare({bad}, {}))
            bad.scope = {path_prefix = "/api/../private", methods = {"GET"}}
            test.is_nil(containment.compare({bad}, {}))
        end)
    end)
end
return test.run_cases(define_tests)
