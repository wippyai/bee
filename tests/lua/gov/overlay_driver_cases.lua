-- MIT. Focused overlay resolver test cases.
local test = require("test")
local bounds = require("bounds")
local resolver = require("overlay_resolver")
local preflight = require("preflight")
local activation_measure = require("activation_measure")
local support = require("support")
type Object = support.Object
local SHA = support.SHA
local fixture = support.fixture
local resolve = support.resolve
local changes = support.changes
local driver_fixture = support.driver_fixture
local M = {}
function M.define()
    test.it("measures dependency bodies but retains only identity and references for unrelated entries", function()
        local deps, spec, observed = fixture()
        local baseline = resolve(deps, spec)
        local retained = baseline.context.entries["bee.host:db"]
        test.eq(retained.digest, nil)
        test.eq(retained.kind, "db.sql.sqlite")
        test.eq(retained.package, "bee/host")
        test.is_true(baseline.context.entries["bee.gov:protected_kernel"].digest ~= nil)
        observed.captured.entries[1].data = {value = "unrelated change"}
        test.eq(resolve(deps, spec).candidate.base_digest, baseline.candidate.base_digest)
        changes(spec, {{id = "private.app:main", kind = "function.lua",
            data = {source = "return true", imports = {db = "bee.host:db"}}}})
        local dependent = resolve(deps, spec)
        test.is_true(dependent.context.entries["bee.host:db"].digest ~= nil)
        observed.captured.entries[1].data = {value = "dependency change"}
        test.is_true(resolve(deps, spec).candidate.base_digest ~= dependent.candidate.base_digest)
    end)
    test.it("measures references in a canonically valid retained driver descriptor", function()
        local deps, spec, observed = fixture()
        local descriptor: Object = {config = "bee.host:db"}
        for _ = 1, 15 do descriptor = {nested = descriptor} end
        observed.captured.entries[#observed.captured.entries + 1] = {id = "bee.host:descriptor", kind = "registry.entry",
            registry = {owner = "bee/host"}, data = descriptor}
        local resolved = resolve(deps, spec)
        test.eq(resolved.context.entries["bee.host:descriptor"].references[1], "bee.host:db")
    end)
    test.it("admits a driver by its declared harness binding under any component name", function()
        for _, base in ipairs({"bee.driver.stub", "acme.adapter"}) do
            local deps, spec = driver_fixture(nil, nil, base)
            local facts = resolve(deps, spec)
            test.eq(#facts.candidate.requirements, 0)
            test.is_true(assert(preflight.check(facts.candidate, facts.context)).ready)
        end
        local refused_deps, refused_spec = driver_fixture(nil, "exec.run", "acme.adapter")
        local candidate, _, problem = resolver.resolve_with(refused_deps, refused_spec)
        test.is_nil(candidate)
        test.is_true(tostring(problem):find("descriptor", 1, true) ~= nil)
    end)
    test.it("measures a driver's activation evidence from its binding alone", function()
        local deps, spec = driver_fixture()
        local facts = resolve(deps, spec)
        spec.plan_digest, spec.revision, spec.selection_revision = SHA, 1, 1
        spec.selected, spec.review_status = true, "accepted"
        local measured, problem = activation_measure.measure(spec, facts.candidate, facts.context)
        if not measured then error(tostring(problem)) end
        local report = assert(bounds.object(measured.report))
        test.is_true(report.ready)
        test.eq(report.base_revision, 0)
    end)
    test.it("refuses a driver requirement that selects into host activation", function()
        for _, path in ipairs({".bindings +=", ".bindings"}) do
            local deps, spec = driver_fixture(path)
            local candidate, _, problem = resolver.resolve_with(deps, spec)
            test.is_nil(candidate)
            test.is_true(tostring(problem):find("activates through its approved harness binding", 1, true) ~= nil, tostring(problem))
        end
    end)
    test.it("refuses editing the protected host entry", function()
        local deps, spec = driver_fixture()
        local facts = resolve(deps, spec)
        local protected = assert(facts.context.entries["bee.harness.launch:harness_activation"])
        local edited: Object = {}
        for field, value in pairs(facts.candidate.entries[1]) do edited[field] = value end
        edited.id, edited.kind = protected.id, protected.kind
        facts.candidate.entries[#facts.candidate.entries + 1] = edited
        local verdict = assert(preflight.check(facts.candidate, facts.context))
        test.is_false(verdict.ready)
        local refused = false
        for _, diagnostic in ipairs(verdict.diagnostics) do
            if diagnostic.code == "PROTECTED_KERNEL" and diagnostic.target == protected.id then refused = true end
        end
        test.is_true(refused)
    end)
    test.it("refuses executable authority disguised as descriptor access", function()
        local deps, spec = driver_fixture(nil, "exec.run")
        local candidate, _, problem = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_true(tostring(problem):find("only read registry", 1, true) ~= nil)
    end)
end
return M
