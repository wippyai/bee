-- MIT. Unread publications belong to the case that started their broker.
local test = require("test")
local bounds = require("bounds")
local fixture = require("fixture")
local appearance = require("appearance")
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local registry = require("registry")
local WORKSPACE = string.rep("f", 32)
local ADMISSION = "bee.security:application_admission"
local function broker(scope: fixture.State): string
    local owner = tostring(process.pid())
    local pid = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
        ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({
            assert(security.policy("bee.security.desktop:broker_policy")),
            assert(security.policy("bee.security:core_spawn_boundary"))}))
        :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {})))
    scope.brokers[pid] = true
    return pid
end
local function define_tests()
    test.describe("Application fixture ownership", function()
        test.it("ends the previous broker and its unread catalog before the next case, including after failure", function()
            local previous: fixture.State? = nil
            local ok, fault = pcall(fixture.case(function(scope: fixture.State)
                previous = scope
                local snap = registry.snapshot()
                local original = assert(bounds.object(assert(snap:get(ADMISSION))))
                local meta = assert(bounds.object(original.meta))
                local function restore()
                    local changes = registry.snapshot():changes()
                    changes:update({id = ADMISSION, kind = "registry.entry", meta = meta, data = original.data,
                        dependency_root = original.dependency_root == true})
                    assert(changes:apply())
                end
                scope.cleanup[#scope.cleanup + 1] = restore
                local pid = broker(scope)
                test.eq(tostring(scope.catalogs:receive():from()), pid)
                local data = assert(bounds.object(original.data))
                local bindings = assert(bounds.array(data.bindings, 64))
                bindings[#bindings + 1] = bindings[1]
                local changes = snap:changes()
                changes:update({id = ADMISSION, kind = "registry.entry", meta = meta, data = {bindings = bindings}})
                assert(changes:apply())
                assert(process.send(pid, "bee.app.request", {version = 1, op = "open", request_id = "fixture-refusal",
                    workspace_id = WORKSPACE, definition_id = "bee.apps:welcome", arguments = {}}))
                local deadline = time.after("30s")
                while true do
                    local selected = channel.select({scope.replies:case_receive(), deadline:case_receive()})
                    assert(selected.ok and selected.channel == scope.replies, "refused open did not reply")
                    local reply = assert(bounds.object(selected.value:payload():data()))
                    if reply.request_id == "fixture-refusal" then
                        test.eq(reply.error_code, "not_admitted")
                        break
                    end
                end
                -- Restore and request a fresh read while the empty catalog is
                -- still unread: the second publication exceeds its one slot.
                restore()
                assert(process.send(pid, "bee.app.request", {version = 1, op = "open", request_id = "fixture-restored",
                    workspace_id = WORKSPACE, definition_id = "bee.apps:missing", arguments = {}}))
                deadline = time.after("30s")
                while true do
                    local selected = channel.select({scope.replies:case_receive(), deadline:case_receive()})
                    assert(selected.ok and selected.channel == scope.replies, "restored open did not reply")
                    local reply = assert(bounds.object(selected.value:payload():data()))
                    if reply.request_id == "fixture-restored" then
                        test.eq(reply.error_code, "not_admitted")
                        break
                    end
                end
                error("intentional fixture failure")
            end))
            test.is_false(ok)
            test.is_true(tostring(fault):find("intentional fixture failure", 1, true) ~= nil)
            fixture.case(function(scope: fixture.State)
                local pid = broker(scope)
                test.eq(tostring(scope.catalogs:receive():from()), pid, "previous case's catalog escaped its scope")
            end)()
            test.is_true(next(assert(previous).brokers) == nil)
        end)
    end)
end
return test.run_cases(define_tests)
