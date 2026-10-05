-- SPDX-License-Identifier: MIT
local test = require("test")
local agents = require("agents")
local sessions = require("sessions")
local protocol = require("protocol")
local function snapshot(saved: protocol.ProfileRef?): protocol.SessionSnapshot
    return {session = "bs:n:w:s1", saved_profile = saved, workspace = "w", definition = "bee.driver.codex:definition",
        terminal = true, revision = 1, incarnation = 1, title = "Saved conversation", lifecycle = "closed",
        activity = "idle", queue_count = 0, execution = {state = "quiescent", evidence_at = "2026-10-01T00:00:00Z", stale = false},
        effective_limits = {}, continuity = {mode = "provider_resume"}, actions = {}}
end
local function define_tests()
    test.describe("New sessions from saved conversations", function()
        test.it("passes the saved profile revision and workspace to admission", function()
            local calls: {sessions.OpenOptions} = {}
            local client: sessions.Client = {
                open = function(_self: sessions.Client, options: sessions.OpenOptions): (sessions.Session?, protocol.Fault?)
                    calls[#calls + 1] = options
                    return nil, protocol.fault("CONFLICT", "saved revision changed", "never")
                end,
                call = function() return nil, nil end, send = function() return nil, nil end,
                cancel = function() return nil, nil end, close = function() return nil, nil end,
                await = function() return nil, nil end, join = function() return nil, nil end,
                get = function() return nil, nil end, work = function() return nil, nil end,
                list = function() return nil, nil end, history = function() return nil, nil end,
                catalog = function() return nil, nil end,
            }
            local opened, err = agents.reopen(client, snapshot({id = "careful", revision = 3}), "new-1")
            test.is_nil(opened)
            test.eq(err, "CONFLICT: saved revision changed")
            test.eq(#calls, 1)
            local request = calls[1]
            test.eq(request.profile and request.profile.id, "careful")
            test.eq(request.profile and request.profile.revision, 3)
            test.eq(request.definition, "bee.driver.codex:definition")
            test.eq(request.workspace, "w")
            test.eq(request.operation_key, "new-1")
            agents.reopen(client, snapshot(nil), "new-2")
            test.eq(#calls, 2)
            test.is_nil(calls[2].profile)
            local missing = snapshot(nil)
            missing.definition = nil
            test.is_nil(agents.reopen(client, missing, "new-3"))
            test.eq(#calls, 2)
        end)
    end)
end
return {run = test.run_cases(define_tests)}
