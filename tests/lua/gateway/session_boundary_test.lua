-- SPDX-License-Identifier: MIT
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local registry = require("registry")
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Gateway session hook boundary", function()
        for _, endpoint in ipairs({"hook_http", "hook_mcp_http"}) do
            test.it("journals a native prompt under " .. endpoint .. " attribution scope", function()
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "boundary-attempt", operation_key = harness.key()}))
                local description = harness.value(journal:call("session_describe", {session = opened.session}))
                local entry = assert(bounds.object(registry.get("bee.gateway.api:" .. endpoint)))
                local data = assert(bounds.object(entry.data))
                local grants = assert(bounds.object(data.security))
                local references = assert(bounds.array(grants.policies, 32))
                local policies: {security.Policy} = {assert(security.policy("bee.gateway:session_boundary_probe_policy"))}
                for _, reference in ipairs(references) do
                    policies[#policies + 1] = assert(security.policy(assert(bounds.id(reference))))
                end
                local scope = security.new_scope(policies)
                local raw, err = funcs.new():with_scope(scope):call("bee.gateway:session_boundary_probe",
                    {session = opened.session, thread = description.thread_ref, event = harness.key()})
                if err then error(tostring(err)) end
                local result = assert(bounds.object(raw))
                if result.error ~= nil then error(tostring(result.error)) end
                test.not_nil(result.reply)
                local stored = harness.value(journal:call("session_describe", {session = opened.session}))
                local active = bounds.object(stored.active_turn)
                test.not_nil(active)
                local pulled = active and harness.value(journal:call("turn_pull", {turn = active.turn, claim = active.claim}))
                test.eq(pulled and pulled.phase, "accepted")
                local stale_raw, stale_error = funcs.new():with_scope(scope):call("bee.gateway:session_boundary_probe",
                    {session = opened.session, thread = description.thread_ref, event = harness.key(), attempt = "stale-attempt"})
                if stale_error then error(tostring(stale_error)) end
                local stale = assert(bounds.object(stale_raw))
                test.eq(stale.error, "hook belongs to an earlier native attachment")
                local after = harness.value(journal:call("session_describe", {session = opened.session}))
                test.eq(assert(bounds.object(after.active_turn)).turn, active and active.turn)
            end)
        end
    end)
end
return test.run_cases(define_tests)
