-- MIT. Hub stops and starts a changed component service through the runtime
-- supervisor, following its status updates, and completes a start only on
-- its owner's readiness acknowledgement.
local test = require("test")
local registry = require("registry")
local system = require("system")
local lifecycle = require("lifecycle")
local service_lifecycle = require("service_lifecycle")

local SERVICE = "bee.tests.hub:lifecycle_service"
local PROCESS = "bee.tests.hub:lifecycle_process"
local HANDLER = "bee.tests.hub:lifecycle_owner"
local DIGEST = string.rep("c", 64)

local function measured(entry: lifecycle.Entry?): string
    if not entry then error("lifecycle fixture entry is missing") end
    return assert(lifecycle.fingerprint(entry))
end

-- work describes an update of the fixture service whose definitions stay as
-- installed, at phase.
local function work(phase: string): lifecycle.Work
    local state = assert(assert(registry.snapshot()):state())
    local by_id: {[string]: lifecycle.Entry} = {}
    for _, entry in ipairs(assert(lifecycle.entries(state))) do by_id[entry.id] = entry end
    local source = by_id[PROCESS]
    if not source then error("lifecycle fixture process is missing") end
    return {version = 1, phase = phase, services = {{id = SERVICE, owner = source.owner, handler = HANDLER, process = PROCESS,
        change = "update", before = measured(source), candidate = measured(source),
        handler_before = measured(by_id[HANDLER]), handler_candidate = measured(by_id[HANDLER]),
        registration_before = measured(by_id[SERVICE]), registration_candidate = measured(by_id[SERVICE]), retention = "retain"}}}
end

local function status(): string
    local state = system.supervisor.state(SERVICE)
    return state and state.status or "unknown"
end

local function define_tests()
    test.describe("Hub service lifecycle", function()
        test.it("stops a drained service once the supervisor reports it stopped", function()
            local problem = service_lifecycle.quiesce(work("quiesced"), DIGEST)
            test.is_nil(problem)
            test.is_true(status() == "stopped" or status() == "exited", status())
        end)
        test.it("starts the service again and requires its owner's readiness acknowledgement", function()
            local problem = service_lifecycle.ready(work("published"), DIGEST)
            test.eq(status(), "running")
            test.eq(problem, "owner has not verified ready for " .. SERVICE)
        end)
    end)
end

return test.run_cases(define_tests)
