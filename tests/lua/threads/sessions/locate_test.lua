-- MIT. Locate returns honest readiness and invalidates cached probes whenever
-- its host-selected binding or observed environment changes.
local test = require("test")
local bounds = require("bounds")
local locate = require("locate")

local function clock(): (locate.Clock, {now: integer})
    local state = {now = 1000}
    return {
        now_ms = function(): integer return state.now end,
        format = function(_ms: integer): string return "2026-09-29T00:00:00.000Z" end,
    }, state
end

local function candidate(): locate.CandidateInput
    return {
        ref = "research:claude",
        kind = "definition",
        title = "Claude review",
        revision = nil,
        target = "bee.harness.permission.external",
        binding_ref = "bee.drivers.claude.binding:binding",
        binding_digest = "sha256:binding-a",
        profile_digest = "sha256:profile-a",
        runtime_identity = "linux-amd64",
        availability_revision = "login-r1",
    }
end

local function observation(status: locate.Status): locate.LocateObservation
    return {status = status, reasons = {}, features = {}, actions = {}}
end

local function define_tests()
    test.describe("Executor location", function()
        test.it("carries complete capability inventories and bounds the feature list", function()
            local features: {string} = {}
            for index = 1, 128 do features[index] = "feature:" .. tostring(index) end
            local cache = assert(locate.new(1000, clock()))
            local probe: locate.Probe = function(_input: locate.CandidateInput): (locate.LocateObservation?, string?)
                return {status = "ready", reasons = {}, features = features, actions = {}}, nil
            end
            local result, err = locate.locate(cache, candidate(), probe)
            assert(result, tostring(err))
            test.eq(#result.features, 128)
            test.not_nil(locate.page({result}, true, {}))
            features[129] = "feature:129"
            test.is_nil(locate.reprobe(cache, candidate(), probe))
            test.is_nil(locate.page({result}, true, {}))
        end)

        test.it("returns the catalog candidate shape for explicit readiness states", function()
            local clock_value = clock()
            for _, status in ipairs({"ready", "missing", "unconfigured", "incompatible", "unknown"}) do
                local cache = assert(locate.new(1000, clock_value))
                local result = assert(locate.locate(cache, candidate(), function(): locate.LocateObservation?
                    return observation(status)
                end))
                test.eq(result.ref, "research:claude")
                test.eq(result.kind, "definition")
                test.eq(result.status, status)
                test.eq(result.title, "Claude review")
                test.eq(result.checked_at, "2026-09-29T00:00:00.000Z")
                test.is_nil((assert(bounds.object(result))).expires_at)
                test.eq(#result.reasons, status == "ready" and 0 or 1)
                test.eq(#result.features, 0)
                test.eq(#result.actions, 0)
            end
        end)

        test.it("caches by target, binding, profile, runtime and availability revision", function()
            local clock_value = clock()
            local cache = assert(locate.new(1000, clock_value))
            local calls = 0
            local probe = function(): locate.LocateObservation
                calls = calls + 1
                return observation("ready")
            end
            test.eq(assert(locate.locate(cache, candidate(), probe)).status, "ready")
            test.eq(assert(locate.locate(cache, candidate(), probe)).status, "ready")
            test.eq(calls, 1)
            local changed = candidate()
            changed.binding_digest = "sha256:binding-b"
            test.eq(assert(locate.locate(cache, changed, probe)).status, "ready")
            changed = candidate()
            changed.runtime_identity = "linux-arm64"
            test.eq(assert(locate.locate(cache, changed, probe)).status, "ready")
            changed = candidate()
            changed.availability_revision = "login-r2"
            test.eq(assert(locate.locate(cache, changed, probe)).status, "ready")
            test.eq(calls, 4)
        end)

        test.it("reprobes on request and after a host availability event", function()
            local clock_value = clock()
            local cache = assert(locate.new(1000, clock_value))
            local calls = 0
            local probe = function(): locate.LocateObservation
                calls = calls + 1
                return observation(calls == 1 and "unconfigured" or "ready")
            end
            test.eq(assert(locate.locate(cache, candidate(), probe)).status, "unconfigured")
            test.eq(assert(locate.reprobe(cache, candidate(), probe)).status, "ready")
            test.is_true(locate.invalidate(cache, candidate().target, "login"))
            test.eq(assert(locate.locate(cache, candidate(), probe)).status, "ready")
            test.eq(calls, 3)
        end)

        test.it("reprobes after a cached observation expires", function()
            local clock_value, state = clock()
            local cache = assert(locate.new(1000, clock_value))
            local calls = 0
            local probe = function(): locate.LocateObservation
                calls = calls + 1
                return observation("ready")
            end
            test.eq(assert(locate.locate(cache, candidate(), probe)).status, "ready")
            state.now = 2000
            test.eq(assert(locate.locate(cache, candidate(), probe)).status, "ready")
            test.eq(calls, 2)
        end)

        test.it("reports failed probes as unknown without inferring readiness", function()
            local cache = assert(locate.new(1000, clock()))
            local result = assert(locate.locate(cache, candidate(), function(): (nil, string)
                return nil, "provider probe unavailable"
            end))
            test.eq(result.status, "unknown")
            test.eq(result.reasons[1], "Readiness probe unavailable.")
        end)

        test.it("preserves partial discovery and counts unavailable candidates", function()
            local page = assert(locate.page({
                {ref = "one", kind = "definition", title = "One", status = "ready", checked_at = "2026-09-29T00:00:00.000Z", reasons = {}, features = {}, actions = {}},
                {ref = "two", kind = "definition", title = "Two", status = "unknown", checked_at = "2026-09-29T00:00:00.000Z", reasons = {"probe unavailable"}, features = {}, actions = {}},
            }, false, {{code = "UNAVAILABLE", message = "partial registry snapshot", retry = "reconcile"}}))
            test.is_false(page.complete)
            test.eq(page.unavailable_count, 1)
            test.eq(#page.diagnostics, 1)
        end)
        test.it("refuses catalog candidates whose observation time violates the shared protocol", function()
            test.is_nil(locate.page({
                {ref = "one", kind = "definition", title = "One", status = "ready", checked_at = "now", reasons = {}, features = {}, actions = {}},
            }, true, {}))
        end)
    end)
end

return test.run_cases(define_tests)
