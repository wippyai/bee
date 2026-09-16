-- MIT. Private-overlay resolution uses immutable definitions with host-owned
-- package, overlay and policy choices. These doubles expose no registry writer.
local test = require("test")
local artifact = require("artifact")
local resolver = require("overlay_resolver")
local preflight = require("preflight")

type Object = {[string]: unknown}
type Entry = {[string]: unknown}
type Policy = {node_id: string, policy_digest: string, packages: {[string]: boolean},
    namespaces: {[string]: boolean}, kinds: {[string]: boolean}, databases: {[string]: boolean},
    grants: {[string]: boolean}, modules: {[string]: boolean}, applied: {[string]: unknown},
    migration_barrier: boolean}
type Captured = {revision: integer, entries: {Entry}, overlay_ids: {[string]: boolean}?,
    owner: (Entry) -> (string?, string?)}
type Facts = {candidate: Object, context: Object}

local SHA = string.rep("a", 64)

local function entry(id: string, kind: string, value: string): Entry
    return {id = id, kind = kind, data = {source = "return '" .. value .. "'", value = value}}
end

local function fixture(policy_raw: Policy?): (Object, Object, {captured: Captured, artifact: Object})
    local made = assert(artifact.create({entry("private.app:main", "function.lua", "main")}))
    local captured: Captured = {
        revision = 19,
        entries = {
            {id = "bee.host:db", kind = "db.sql.sqlite", data = {}, registry = {owner = "bee/host"}},
            {id = "private.app:old-overlay", kind = "function.lua", data = {source = "return 'old-overlay'"},
                registry = {owner = "host/overlay"}},
        },
        overlay_ids = { ["private.app:old-overlay"] = true },
        owner = function(item: Entry): (string?, string?)
            local metadata = item.registry
            if type(metadata) == "table" and type((metadata :: Object).owner) == "string" then
                return (metadata :: Object).owner :: string, nil
            end
            return nil, "local registry owner is missing"
        end,
    }
    local policy = policy_raw or {node_id = "node-destination", policy_digest = SHA,
        packages = { ["host/private-app"] = true }, namespaces = { ["private.app"] = true },
        kinds = { ["function.lua"] = true }, databases = { ["bee.host:db"] = true },
        grants = {}, modules = {}, applied = {}, migration_barrier = false}
    local deps: Object = {
        capture = function(): (Captured?, string?) return captured, nil end,
        root = function(spec: Object): (Object?, string?)
            if spec.source_node ~= "node-source" or spec.source_workspace ~= "author/app" then
                return nil, "private artifact does not match host source mapping"
            end
            return {component = "host/private-app", version = spec.version}, nil
        end,
        policy = function(_: Object, _: Captured, _: Object): (Policy?, string?) return policy :: Policy, nil end,
    }
    local spec: Object = {owner_node = "node-destination", workspace_id = "workspace-destination",
        source_node = "node-source", source_workspace = "author/app", version = "v1",
        artifact_bytes = made.bytes, artifact_digest = made.digest}
    return deps, spec, {captured = captured, artifact = made}
end

local function resolve(deps: Object, spec: Object): Facts
    local candidate, context, err = resolver.resolve_with(deps, spec)
    if not candidate or not context then error(tostring(err)) end
    return {candidate = candidate, context = context}
end

local function changes(spec: Object, entries: {Entry})
    local made = assert(artifact.create(entries))
    spec.artifact_bytes, spec.artifact_digest = made.bytes, made.digest
end

local function define_tests()
    test.describe("private overlay artifact resolver", function()
        test.it("extracts native configuration capabilities without dropping their ceilings", function()
            local deps, spec = fixture(nil)
            changes(spec, {{id = "private.app:main", kind = "function.lua", data = {
                source = "return true", modules = {"os"}, security = {policies = {"bee.host:db"}},
                lifecycle = {auto_start = true}}}})
            local facts = resolve(deps, spec)
            local native = (facts.candidate.entries :: {Object})[1]
            test.eq((native.modules :: {string})[1], "os")
            test.eq((native.grants :: {string})[1], "bee.host:db")
            test.eq(native.auto_start, true)
            test.is_nil((facts.context.modules :: Object).os)
            test.is_nil((facts.context.grants :: Object)["bee.host:db"])
            local report, problem = preflight.check(facts.candidate :: preflight.Candidate,
                facts.context :: preflight.Context)
            if not report then error(tostring(problem)) end
            test.is_false(report.ready)
            local denied: {[string]: boolean} = {}
            for _, diagnostic in ipairs(report.diagnostics) do denied[diagnostic.code] = true end
            test.is_true(denied.MODULE_DENIED)
            test.is_true(denied.GRANT_DENIED)
        end)
        test.it("accepts the runtime's initial registry revision", function()
            local deps, spec = fixture(nil)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.revision = 0
            test.eq(resolve(deps, spec).candidate.base_revision, 0)
        end)

        test.it("preserves IDs and assigns ownership from the host-selected profile", function()
            local deps, spec = fixture(nil)
            local facts = resolve(deps, spec)
            local candidate = facts.candidate
            test.eq(candidate.destination_node, "node-destination")
            test.eq(candidate.source_node, "node-source")
            test.eq(candidate.base_revision, 19)
            test.eq(#(candidate.artifacts :: {unknown}), 1)
            local package = (candidate.artifacts :: {Object})[1]
            test.eq(package.component, "host/private-app")
            test.eq(package.digest, spec.artifact_digest)
            test.eq(((candidate.entries :: {Object})[1]).id, "private.app:main")
            test.eq(((candidate.entries :: {Object})[1]).package, "host/private-app")
            test.is_true(((facts.context.namespaces :: {[string]: boolean})["private.app"]) == true)
        end)

        test.it("allows replacing definitions from only the selected destination overlay", function()
            local deps, spec = fixture(nil)
            changes(spec, {entry("private.app:old-overlay", "function.lua", "replacement")})
            local facts = resolve(deps, spec)
            test.is_nil((facts.context.entries :: Object)["private.app:old-overlay"])
            test.is_true((facts.context.entries :: Object)["bee.host:db"] ~= nil)
            test.eq(((facts.candidate.entries :: {Object})[1]).id, "private.app:old-overlay")
        end)

        test.it("rejects an entry collision with the composed destination registry", function()
            local deps, spec = fixture(nil)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[2] = {id = "private.app:old", kind = "function.lua", data = {},
                registry = {owner = "some/other-package"}}
            changes(spec, {entry("private.app:old", "function.lua", "new")})
            local candidate, context, err = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            test.is_nil(context)
            test.is_true(tostring(err):find("entry collides", 1, true) ~= nil)
        end)

        test.it("rejects namespace collision with a definition outside the selected overlay", function()
            local deps, spec = fixture(nil)
            local captured = (deps.capture :: () -> (Captured?, string?))()
            captured.entries[2] = {id = "private.app:foreign", kind = "function.lua", data = {},
                registry = {owner = "some/other-package"}}
            changes(spec, {entry("private.app:new", "function.lua", "new")})
            local candidate, context, err = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            test.is_nil(context)
            test.is_true(tostring(err):find("namespace collides", 1, true) ~= nil)
        end)

        test.it("rejects remote registry ownership metadata instead of trusting it", function()
            local deps, spec = fixture(nil)
            local invalid, invalid_error = artifact.create({{id = "private.app:main", kind = "function.lua",
                registry = {owner = "attacker/authorized-package"}, data = {source = "return true"}}})
            test.is_nil(invalid)
            test.is_true(tostring(invalid_error):find("unknown field registry", 1, true) ~= nil)
        end)

        test.it("rejects Hub dependency directives and migration-bearing artifacts", function()
            local deps, spec = fixture(nil)
            changes(spec, {{id = "private.app:dependency", kind = "ns.dependency", data = {component = "attacker/pkg"}}})
            local candidate, _, err = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            test.is_true(tostring(err):find("dependency directives", 1, true) ~= nil)
            changes(spec, {{id = "private.app:migration", kind = "registry.entry",
                meta = {type = "migration", target_db = "bee.host:db", ordinal = 1}, data = {sql = "ALTER TABLE x"}}})
            candidate, _, err = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            test.is_true(tostring(err):find("migration-free", 1, true) ~= nil)
        end)

        test.it("retains host capability ceilings unchanged", function()
            local denied: Policy = {node_id = "node-destination", policy_digest = SHA,
                packages = {["host/private-app"] = false}, namespaces = {["private.app"] = false},
                kinds = {["function.lua"] = false}, databases = {}, grants = {}, modules = {},
                applied = {}, migration_barrier = false}
            local deps, spec = fixture(denied)
            local facts = resolve(deps, spec)
            test.is_false((facts.context.packages :: {[string]: boolean})["host/private-app"])
            test.is_false((facts.context.namespaces :: {[string]: boolean})["private.app"])
            test.is_false((facts.context.kinds :: {[string]: boolean})["function.lua"])
        end)
    end)
end

return test.run_cases(define_tests)
