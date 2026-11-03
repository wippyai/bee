-- MIT. A CLI descriptor alone is a driver: its binding is the shared
-- implementation and its profile a window on a PTY.
local test = require("test")
local resolver = require("resolver")
local profile = require("profile")
local universal = require("universal")
local registry = require("registry")
local bounds = require("bounds")
type Object = {[string]: unknown}

local OWNER = "bee.drivers.tests:descriptor-driver"
local REF = "bee.drivers.tests.echo:cli"

local function echo_descriptor(): Object
    return {id = REF, kind = "registry.entry", meta = {type = "bee.driver.cli_descriptor"}, data = {
        schema_revision = "bee.driver.cli-descriptor@4", provider = "echo", executable = "echo-agent",
        version_probe = {argv = {"--version"}}, configure = "plain",
        options = {profiles = {"window"}, fields = {}},
        argv_templates = {window = {argv = {"--interactive"}, readiness = "none"}},
    }}
end

local function with_descriptor(body: (registry.Snapshot) -> ())
    local created = assert(registry.overlay(OWNER)):changes()
    assert(created:create(echo_descriptor()))
    assert(created:apply())
    local ok, failure = pcall(function() body(assert(registry.snapshot())) end)
    local cleanup = assert(registry.overlay(OWNER)):changes()
    assert(cleanup:delete(REF))
    assert(cleanup:apply())
    assert(ok, tostring(failure))
end

local function methods_of(binding: Object): {[string]: string}
    local mapped: {[string]: string} = {}
    for _, raw in ipairs(assert(bounds.array(assert(bounds.object(binding.data)).contracts, 8))) do
        local contract = assert(bounds.object(raw))
        for name, target in pairs(assert(bounds.object(contract.methods))) do mapped[name] = tostring(target) end
    end
    return mapped
end

local function define_tests()
    test.describe("Descriptor drivers", function()
        test.it("reads a descriptor no binding names as its own driver with the shared methods", function()
            with_descriptor(function(pinned: registry.Snapshot)
                local binding = assert(resolver.binding(pinned, REF))
                test.eq(binding.kind, "contract.binding")
                local meta = assert(bounds.object(binding.meta))
                test.eq(meta.type, "harness.driver")
                test.eq(meta.driver_id, "echo")
                test.eq(meta.descriptor_ref, REF)
                local methods = methods_of(binding)
                test.eq(methods.prepare, "bee.drivers.universal:prepare")
                test.eq(methods.dispatch, "bee.drivers.universal:dispatch")
                test.eq(methods.normalize, "bee.drivers.universal:normalize")
                test.eq(methods.configure, "bee.drivers.universal:configure")
                test.eq(methods.locate, "bee.drivers.universal:locate")
                for _, target in pairs(methods) do test.eq(assert(pinned:get(target)).kind, "function.lua") end
            end)
        end)
        test.it("declares one window profile on a PTY for a descriptor driver", function()
            with_descriptor(function(pinned: registry.Snapshot)
                local declaration = assert(resolver.declaration(pinned, assert(resolver.binding(pinned, REF))))
                local meta = assert(bounds.object(declaration.meta))
                test.eq(meta.type, "harness.profile")
                test.eq(meta.driver_ref, REF)
                local decoded = assert(profile.decode(assert(bounds.object(declaration.data)).driver))
                test.eq(decoded.default_profile, "window")
                test.eq(#decoded.profiles, 1)
                test.eq(decoded.profiles[1].mode, "window")
                test.eq(decoded.profiles[1].protocol, "pty")
                local selected = assert(profile.find(decoded, "window"))
                test.eq(selected.answer_path.strategy, "none")
            end)
        end)
        test.it("keeps a descriptor a binding names out of the drivers", function()
            local pinned = assert(registry.snapshot())
            local claimed = assert(resolver.binding(pinned, "bee.drivers.claude.descriptor:cli"))
            test.eq(claimed.kind, "registry.entry")
            with_descriptor(function(fresh: registry.Snapshot)
                local refs: {[string]: boolean} = {}
                for _, entry in ipairs(assert(resolver.drivers(fresh))) do refs[tostring(entry.id)] = true end
                test.is_true(refs[REF] == true)
                test.is_true(refs["bee.drivers.claude.binding:binding"] == true)
                test.is_nil(refs["bee.drivers.claude.descriptor:cli"])
            end)
            test.eq(table.concat(resolver.driver_refs({
                {id = "vendor.binding:binding", kind = "contract.binding", meta = {type = "harness.driver", descriptor_ref = "vendor.descriptor:cli"}},
                {id = "vendor.descriptor:cli", kind = "registry.entry", meta = {type = "bee.driver.cli_descriptor"}},
                {id = "solo.descriptor:cli", kind = "registry.entry", meta = {type = "bee.driver.cli_descriptor"}},
            }), ","), "solo.descriptor:cli,vendor.binding:binding")
        end)
        test.it("renders the launch of the descriptor a request names", function()
            with_descriptor(function(_pinned: registry.Snapshot)
                local reply = universal.prepare({descriptor_ref = REF, profile_id = "window", brief = ""})
                test.eq(reply.ok, true, tostring(reply.error))
                local launch = assert(bounds.object(reply.launch))
                test.eq(launch.executable, "echo-agent")
                test.eq(table.concat(assert(bounds.ids(launch.argv, true)), " "), "--interactive")
                local unnamed = universal.prepare({profile_id = "window", brief = ""})
                test.eq(unnamed.ok, false)
                test.eq(unnamed.error, "request names no CLI descriptor in descriptor_ref")
                local configured = universal.plain_configure({fixture = false, context = "window", descriptor = echo_descriptor().data})
                test.eq(configured.ok, true, tostring(configured.error))
                local delivery = assert(bounds.object(configured.delivery))
                test.eq(#assert(bounds.array(delivery.files, 8)), 0)
            end)
        end)
    end)
end

return test.run_cases(define_tests)
