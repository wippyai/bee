-- MIT
local test = require("test")
local security = require("security")
local funcs = require("funcs")
local registry = require("registry")
local bounds = require("bounds")
local grants = require("grants")
local capability = require("capability")

local GROUP = "bee.security.hive:hive_exposure_scope"
local TARGET = "arbitrary.sdk:run"

local function check(): {[string]: unknown}
    local scope, err = security.named_scope(GROUP)
    if not scope then error("exposure scope: " .. tostring(err)) end
    local invoke = assert(security.policy("bee.tests.hive:probe_invocation"))
    local result, call_error = funcs.new():with_scope(scope:with(invoke)):call("bee.tests.hive:exposure_probe", {})
    if call_error then error(tostring(call_error)) end
    return assert(bounds.object(result))
end

local function define_tests()
    test.describe("Hive exposure scope", function()
        test.it("exists and denies operations without an installed grant", function()
            local result = check()
            test.eq(result.exposed, false)
            test.eq(result.registry, false)
        end)
        test.it("permits only the approved mode and operation and revokes with its installed policy", function()
            local vocabulary = assert(capability.decode(assert(registry.get("bee.capability:catalog"))))
            local proposal = assert(grants.propose(vocabulary, "bee.tests.hive:scope_owner", "arbitrary.sdk:app", {
                {id = "arbitrary.sdk:exposure", value = nil, expected_kind = "security.policy", targets = {TARGET},
                    capability_request = {capability = "hive.expose", parameters = {operations = {TARGET},
                        mode = "open", audiences = {"node-1"}}, catalog_revision = capability.revisions(vocabulary, "hive.expose"),
                        template_revision = 2, target = TARGET, path = ".security.policies +="}}}))
            local generated = proposal.policies[1]
            local changes = assert(registry.snapshot()):changes()
            changes:create({id = assert(bounds.id(generated.id)),
                kind = assert(bounds.text(generated.kind, 160)),
                meta = bounds.object(generated.meta), data = generated.data})
            assert(changes:apply())
            local result = check()
            test.eq(result.exposed, true)
            test.eq(result.other, false)
            test.eq(result.policy, false)
            test.eq(result.registry, false)
            changes = assert(registry.snapshot()):changes()
            changes:delete(tostring(generated.id))
            assert(changes:apply())
            test.eq(check().exposed, false)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
