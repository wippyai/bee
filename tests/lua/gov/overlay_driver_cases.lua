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
    test.it("measures an owned activation append through existing preflight", function()
        local deps, spec = driver_fixture()
        local facts = resolve(deps, spec)
        test.eq(facts.candidate.requirements[1].value, "bee.driver.stub.binding:binding")
        test.eq(facts.candidate.requirements[1].targets[1], "bee.harness.launch:harness_activation")
        local verdict = assert(preflight.check(facts.candidate, facts.context))
        test.is_true(verdict.ready)
    end)
    test.it("admits a driver by its declared harness binding under any component name", function()
        local deps, spec = driver_fixture(nil, nil, "acme.adapter")
        local facts = resolve(deps, spec)
        test.eq(facts.candidate.requirements[1].value, "acme.adapter.binding:binding")
        test.is_true(assert(preflight.check(facts.candidate, facts.context)).ready)
        test.is_true(facts.context.driver_requirements ~= nil)
        local refused_deps, refused_spec = driver_fixture(nil, "exec.run", "acme.adapter")
        local candidate, _, problem = resolver.resolve_with(refused_deps, refused_spec)
        test.is_nil(candidate)
        test.is_true(tostring(problem):find("descriptor", 1, true) ~= nil)
    end)
    test.it("retains the exact driver append while normalizing activation evidence", function()
        local deps, spec = driver_fixture()
        local facts = resolve(deps, spec)
        spec.plan_digest, spec.revision, spec.selection_revision = SHA, 1, 1
        spec.selected, spec.review_status = true, "accepted"
        local measured, problem = activation_measure.measure(spec, facts.candidate, facts.context)
        if not measured then error(tostring(problem)) end
        local report = assert(bounds.object(measured.report))
        test.is_true(report.ready)
        test.eq(report.base_revision, 0)
        facts.context.driver_requirements = nil
        test.is_nil(activation_measure.measure(spec, facts.candidate, facts.context))
    end)
    test.it("refuses a replacement of the host activation catalog", function()
        local deps, spec = driver_fixture(".bindings")
        local candidate, _, problem = resolver.resolve_with(deps, spec)
        test.is_nil(candidate)
        test.is_true(tostring(problem):find("may only append", 1, true) ~= nil)
    end)
    test.it("keeps the protected target closed without the exact host append measurement", function()
        for _, change in ipairs({"missing", "binding", "digest"}) do
            local deps, spec = driver_fixture()
            local facts = resolve(deps, spec)
            local appends = assert(facts.context.driver_requirements)
            local append = assert(appends["bee.driver.stub.binding:activation"])
            if change == "missing" then facts.context.driver_requirements = nil
            elseif change == "binding" then append.binding = "bee.driver.claude.binding:binding"
            else append.digest = string.rep("b", 64) end
            local verdict = assert(preflight.check(facts.candidate, facts.context))
            test.is_false(verdict.ready)
            local protected = false
            for _, diagnostic in ipairs(verdict.diagnostics) do
                if diagnostic.code == "PROTECTED_KERNEL" then protected = true end
            end
            test.is_true(protected)
        end
    end)
    test.it("refuses editing the protected host entry even with an admitted append", function()
        local deps, spec = driver_fixture()
        local facts = resolve(deps, spec)
        local protected = assert(facts.context.entries["bee.harness.launch:harness_activation"])
        facts.candidate.entries[#facts.candidate.entries + 1] = protected
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
