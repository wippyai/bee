-- MIT. Classification is pure: a binding with its resolved declaration and
-- methods is compatible only when every rule holds, and each broken rule
-- names itself once.
local test = require("test")
local classify = require("classify")
local permission = require("permission")
type Entry = {[string]: unknown}
local function method(id: string): Entry
    return {id = id, kind = "function.lua", meta = {}, data = {source = "file://" .. id .. ".lua"}}
end
local function methods(): {[string]: Entry?}
    return {["fake:prepare"] = method("fake:prepare"), ["fake:dispatch"] = method("fake:dispatch"), ["fake:normalize"] = method("fake:normalize")}
end
local function binding(): Entry
    return {id = "fake:binding", kind = "contract.binding", meta = {type = "harness.driver", driver_id = "fake", profiles_ref = "fake:profiles"},
        data = {contracts = {{contract = "bee.driver:driver", methods = {prepare = "fake:prepare", dispatch = "fake:dispatch", normalize = "fake:normalize"}}}}}
end
local function declaration(protocol: string?): Entry
    return {id = "fake:profiles", kind = "registry.entry", meta = {type = "harness.profile", driver_ref = "fake:binding"},
        data = {driver = {schema_revision = "bee.driver@1", kind = "harness", title = "Fake", implementation_version = "0.1.0", default_profile = "batch",
            profiles = {{id = "batch", mode = "batch", protocol = protocol or "stream-json", protocol_revision = "fake-1", answer_path = {strategy = "terminal_field", adapter_ref = "fake:protocol"}},
                {id = "window", mode = "session", protocol = protocol or "stream-json", protocol_revision = "fake-1", answer_path = {strategy = "terminal_field", adapter_ref = "fake:protocol"}}}}}}
end
local function classified(input: Entry?, entry: Entry?, table: {[string]: Entry?}?, activated: boolean?): classify.Binding
    local request: classify.Input = {binding = binding(), declaration = declaration(), methods = methods(), activated = activated == true}
    if input then request.declaration = input end
    if entry then request.binding = entry end
    if table then request.methods = table end
    return classify.binding(request)
end
local function meta_of(entry: Entry): {[string]: unknown}
    return entry.meta :: {[string]: unknown}
end
local function data_of(entry: Entry): {[string]: unknown}
    return entry.data :: {[string]: unknown}
end
local function driver_of(entry: Entry): {[string]: unknown}
    return data_of(entry).driver :: {[string]: unknown}
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
local function adapter_entry(): Entry
    return {id = "fake:permission", kind = "registry.entry", meta = {type = "harness.permission_adapter"},
        data = {adapter = {schema_revision = "bee.permission-adapter@2", event_name = "permission_request", event_revision = "fake-1",
            request = {correlation = "request_id", tool = "tool_name", input = "input"},
            response = {envelope = {type = "control_response"}, correlation_field = "request_id", decision_field = "behavior", allow_value = "allow", deny_value = "deny"},
            acknowledgment = {mode = "correlation_echo", event_type = "tool.result", field = "call_id"}, deny_acknowledgment = {mode = "unproven"}, cancellation = "deny_before_close", proof_fixture = "permission_exchange"}}}
end
local function define_tests()
    test.describe("Harness classification", function()
        test.it("admits a permission exchange only when the profile pins the adapter the snapshot measures", function()
            local entry = adapter_entry()
            local measured = assert(permission.decode("fake:permission", data_of(entry).adapter))
            local pinned = declaration()
            local profiles = driver_of(pinned).profiles :: {{[string]: unknown}}
            profiles[1].permission_exchange = {mode = "adapter", adapter_ref = "fake:permission", adapter_digest = measured.digest}
            local absent = classify.binding({binding = binding(), declaration = pinned, methods = methods(), activated = false})
            test.eq(absent.state, "incompatible")
            test.is_true(has(absent.diagnostics, "profile batch pins permission adapter fake:permission which does not exist"))
            local present = classify.binding({binding = binding(), declaration = pinned, methods = methods(), adapters = {["fake:permission"] = entry}, activated = false})
            test.eq(present.state, "compatible")
            test.is_true(present.profiles[1].permission.eligible)
            test.eq(present.profiles[1].permission.proof_fixture, "permission_exchange")
            test.is_false(present.profiles[2].permission.eligible)
            test.eq(present.profiles[2].permission.mode, "none")
            test.is_false(absent.profiles[1].permission.eligible)
            local changed = adapter_entry()
            local changed_adapter = data_of(changed).adapter :: {[string]: unknown}
            changed_adapter.cancellation = "unsupported"
            local mismatched = classify.binding({binding = binding(), declaration = pinned, methods = methods(), adapters = {["fake:permission"] = changed}, activated = false})
            test.eq(mismatched.state, "incompatible")
            test.eq(#mismatched.diagnostics, 1)
            local other = adapter_entry()
            meta_of(other).type = "registry.entry"
            local untyped = classify.binding({binding = binding(), declaration = pinned, methods = methods(), adapters = {["fake:permission"] = other}, activated = false})
            test.is_true(has(untyped.diagnostics, "profile batch: fake:permission is not a harness.permission_adapter"))
        end)
        test.it("accepts a complete binding and measures entry and declaration separately", function()
            local result = classified()
            test.eq(result.state, "compatible")
            test.eq(#result.diagnostics, 0)
            test.eq(result.binding_id, "fake:binding")
            test.eq(result.driver_id, "fake")
            test.eq(result.title, "Fake")
            test.eq(result.implementation_version, "0.1.0")
            test.eq(result.default_profile, "batch")
            test.eq(#result.profiles, 2)
            test.eq(result.profiles[2].mode, "session")
            test.is_true(result.profiles[2].supported)
            test.eq(#result.binding_digest.entry, 64)
            test.eq(result.profile_digest.scope, "entry")
            test.is_false(result.activated)
            test.is_true(classified(nil, nil, nil, true).activated)
            local again = classified()
            test.eq(again.binding_digest.entry, result.binding_digest.entry)
            test.eq(again.profile_digest.entry, result.profile_digest.entry)
            local changed = declaration()
            driver_of(changed).implementation_version = "0.2.0"
            local moved = classified(changed)
            test.neq(moved.profile_digest.entry, result.profile_digest.entry)
            test.eq(moved.binding_digest.entry, result.binding_digest.entry)
        end)
        test.it("reports a missing or foreign declaration", function()
            local without: classify.Input = {binding = binding(), declaration = nil, methods = methods(), activated = true}
            local missing = classify.binding(without)
            test.eq(missing.state, "incompatible")
            test.is_true(has(missing.diagnostics, "profiles_ref fake:profiles does not exist"))
            test.eq(#missing.profiles, 0)
            test.is_true(missing.activated)
            local foreign = declaration()
            meta_of(foreign).driver_ref = "other:binding"
            local result = classified(foreign)
            test.eq(result.state, "incompatible")
            test.is_true(has(result.diagnostics, "profiles entry names another binding: other:binding"))
            local untyped = declaration()
            meta_of(untyped).type = "registry.entry"
            test.is_true(has(classified(untyped).diagnostics, "profiles entry is not a harness.profile"))
        end)
        test.it("reports malformed declarations and unsupported protocols", function()
            local malformed = declaration()
            driver_of(malformed).schema_revision = "bee.driver@2"
            local result = classified(malformed)
            test.eq(result.state, "incompatible")
            test.is_true(has(result.diagnostics, "profiles: meta.driver.schema_revision must be bee.driver@1"))
            test.eq(result.title, "")
            local unsupported = classified(declaration("pty"))
            test.eq(unsupported.state, "incompatible")
            test.is_true(has(unsupported.diagnostics, "no profile uses a supported protocol"))
            test.is_false(unsupported.profiles[1].supported)
            local default_only = declaration()
            local profiles = driver_of(default_only).profiles :: {{[string]: unknown}}
            profiles[1].protocol = "pty"
            local partial = classified(default_only)
            test.eq(partial.state, "incompatible")
            test.is_true(has(partial.diagnostics, "the default profile uses an unsupported protocol"))
            test.is_true(partial.profiles[2].supported)
            local fixture = declaration("pty")
            meta_of(fixture).test_support = true
            local accepted = classified(fixture)
            test.eq(accepted.state, "compatible")
            test.is_true(accepted.profiles[1].supported)
        end)
        test.it("requires the driver contract with three bound functions", function()
            local other = binding()
            data_of(other).contracts = {{contract = "bee.other:contract", methods = {}}}
            test.is_true(has(classified(nil, other).diagnostics, "binding does not implement bee.driver:driver"))
            local unbound = binding()
            local contracts = data_of(unbound).contracts :: {{[string]: unknown}}
            local bound = contracts[1].methods :: {[string]: unknown}
            bound.normalize = nil
            test.is_true(has(classified(nil, unbound).diagnostics, "method normalize is not bound"))
            local absent = methods()
            absent["fake:dispatch"] = nil
            test.is_true(has(classified(nil, nil, absent).diagnostics, "method dispatch points at a missing entry fake:dispatch"))
            local wrong = methods()
            wrong["fake:prepare"] = {id = "fake:prepare", kind = "registry.entry", meta = {}, data = {}}
            test.is_true(has(classified(nil, nil, wrong).diagnostics, "method prepare points at registry.entry, not a function"))
            local untagged = binding()
            meta_of(untagged).driver_id = nil
            local result = classified(nil, untagged)
            test.is_true(has(result.diagnostics, "meta.driver_id is not an identifier"))
            test.eq(result.driver_id, "")
            local wrong_kind = binding()
            wrong_kind.kind = "registry.entry"
            test.is_true(has(classified(nil, wrong_kind).diagnostics, "binding must be a contract.binding"))
        end)
        test.it("marks compatible bindings that share a driver_id as ambiguous", function()
            local first = classified()
            local second = classified()
            second.binding_id = "fake:second"
            local third = classified()
            third.binding_id = "fake:third"
            third.driver_id = "third"
            local broken = classified(nil, nil, {})
            local list = classify.disambiguate({first, second, third, broken})
            test.eq(list[1].state, "incompatible")
            test.eq(list[2].state, "incompatible")
            test.is_true(has(list[1].diagnostics, "driver_id fake is declared by 2 compatible bindings"))
            test.eq(list[3].state, "compatible")
            test.eq(#broken.diagnostics, 3)
        end)
    end)
end
return test.run_cases(define_tests)
