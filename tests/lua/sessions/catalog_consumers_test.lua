-- SPDX-License-Identifier: MIT

local test = require("test")
local bounds = require("bounds")
local registry = require("registry")
local funcs = require("funcs")
local env = require("env")
local security = require("security")
local sessions = require("sessions")
local agents = require("agents")
local session_tools = require("session_tools")
local protocol = require("protocol")
local form = require("form")
local picker = require("picker")
local admission = require("admission")
local M = {}
type Object = {[string]: unknown}

function M.probe(path: string): Object
    local actor = assert(security.actor())
    local workspace = assert(bounds.id(actor:meta().workspace_id))
    if path == "modes" then
        local ref = "bee.driver.codex.profiles:research_batch"
        local resolved, resolve_error = admission.resolve(ref, nil, workspace)
        local plan = assert(resolved, tostring(resolve_error and resolve_error.error and resolve_error.error.message))
        test.eq(plan.mode, "batch")
        local forced, refusal = admission.resolve(ref, "window", workspace)
        test.is_nil(forced)
        test.eq(assert(assert(refusal).error).code, "FORBIDDEN")
        local listing = agents.visible_profiles(assert(agents.list(sessions.client(), true)), false, "")
        local choices = agents.profile_drivers(listing)
        local batch = false
        local profile_id: string? = nil
        for _, choice in ipairs(choices) do
            if choice.definition_ref == "bee.driver.codex.profiles:research_batch" then
                batch = true
                local draft = assert(form.load(workspace, choice, true))
                assert(form.save(draft))
                profile_id = draft.profile_id
            end
        end
        local admitted, refused = picker.direct(workspace, "bee.driver.codex.profiles:research_batch", nil, nil, nil, "Inspect stored memory")
        local listed, catalog_error = sessions.client():catalog({include_unavailable = true})
        local page = assert(listed, tostring(catalog_error and catalog_error.message))
        local window, window_error = picker.direct(workspace, "bee.harness.catalog:window_ready_definition")
        return {batch = batch, profile_id = profile_id, listing = listing, page = page, mode = admitted and admitted.plan.mode, error = refused,
            window_mode = window and window.plan.mode, window_error = window_error}
    end
    local saved = assert(bounds.object(assert(funcs.call("bee.harness.binding:call", {
        operation = "put", workspace_id = workspace, profile_id = "catalog-consumer-profile",
        expected_revision = 0, idempotency_key = "catalog-consumer-profile",
        profile = {schema_revision = "bee.agent-profile@3", name = "Catalog consumer profile",
            definition_ref = "bee.driver.claude.profiles:default_window",
            driver_binding_ref = "bee.driver.claude.binding:binding", provider = {},
            bee = {permission_answers = "provider"}, placement = {kind = "native", home = "machine"}},
    }))))
    assert(saved.ok == true, "save catalog consumer profile")
    if path == "ui" then
        local listing, failure = agents.list(sessions.client(), true)
        return {listing = listing, error = failure}
    elseif path == "sdk" then
        local page, failure = sessions.client():catalog({include_unavailable = true})
        return {page = page, error = failure and tostring(failure)}
    end
    local raw, transport = funcs.call("bee.threads.sessions.binding:catalog", {include_unavailable = true})
    assert(not transport, tostring(transport))
    if path == "validation" then return {reply = raw} end
    local reply, failure = session_tools.result("session_catalog", raw)
    return {reply = reply, error = failure}
end

local function through_production_catalog(path: string): Object
    local original = assert(registry.get("bee.tests.sessions:fake_catalog_owner"))
    local binding = assert(registry.get("bee.tests.sessions:fake_catalog_owner"))
    local data = assert(bounds.object(binding.data))
    local contracts = assert(bounds.array(data.contracts, 1))
    local methods = assert(bounds.object(assert(bounds.object(contracts[1])).methods))
    methods.list = "bee.threads.sessions.binding:catalog"
    local changes = assert(registry.snapshot()):changes()
    changes:update(binding)
    assert(changes:apply())
    local ok, result = pcall(function(): Object
        local workspace = path == "modes" and string.rep("d", 32) or "catalog-consumer-" .. path
        local actor = security.new_actor("catalog-consumer", {workspace_id = workspace})
        local reply, failure = funcs.new():with_actor(actor):call("bee.tests.sessions:catalog_consumers_probe", path)
        assert(not failure, tostring(failure))
        return assert(bounds.object(reply))
    end)
    local restore = assert(registry.snapshot()):changes()
    restore:update(original)
    assert(restore:apply())
    if not ok then error(tostring(result)) end
    return result
end

local function candidate_rows(page: Object): {Object}
    local rows: {Object} = {}
    for _, item in ipairs(assert(bounds.array(page.items, 64))) do rows[#rows + 1] = assert(bounds.object(item)) end
    return rows
end

local function assert_catalog(page: Object)
    local kinds: {[string]: boolean} = {}
    local codex = false
    for _, row in ipairs(candidate_rows(page)) do
        if row.ref == "bee.driver.codex.profiles:default_window" then
            local features = assert(bounds.array(row.features, 128))
            test.is_true(#features > 64)
            local history = false
            for _, feature in ipairs(features) do
                if feature == "supported:provider.options.history_persistence" then history = true end
            end
            test.is_true(history); codex = true
        end
        kinds[assert(bounds.id(row.kind))] = true
        local capabilities = assert(bounds.array(row.hook_capabilities, 4))
        test.eq(#capabilities, 4)
        local before = assert(bounds.object(capabilities[3]))
        test.eq(before.point, "tool.before")
        test.eq(type(before.supported), "boolean")
        test.not_nil(bounds.array(before.allowed_results, 4))
        test.not_nil(bounds.text(before.reason, 16384))
    end
    test.is_true(kinds.definition)
    test.is_true(kinds.profile)
    test.is_true(codex)
end

local function define_tests()
    test.describe("Production Sessions catalog consumers", function()
        test.it("lists batch-only definitions ready and opens the declared mode from the picker", function()
            local ref = "bee.driver.codex.profiles:research_batch"
            local original = assert(registry.get(ref))
            local edited = assert(registry.get(ref))
            local data = assert(bounds.object(edited.data))
            data.thread_policy = {kind = "new"}; data.credentials = {}
            data.presentation = {start_menu = true, fullscreen = false, reuse = "never"}
            local policy_ref = "bee.driver.codex.security:launch_policy_codex_batch"
            local original_policy = assert(registry.get(policy_ref))
            local policy = assert(registry.get(policy_ref))
            local policy_data = assert(bounds.object(policy.data))
            policy_data.executables = {codex = assert(env.get("BEE_FIXTURE_BIN")) .. "/codex"}
            policy_data.executable_env = {}
            local changes = registry.snapshot():changes(); changes:update(edited); changes:update(policy); assert(changes:apply())
            local ok, failure = pcall(function()
                local result = through_production_catalog("modes")
                local listing = assert(bounds.object(result.listing))
                local reasons: {string} = {}
                for _, row in ipairs(candidate_rows(assert(bounds.object(result.page)))) do
                    local raw = assert(bounds.array(row.reasons, 64))
                    reasons[#reasons + 1] = tostring(row.ref) .. ": " .. tostring(raw[1])
                end
                test.is_true(result.batch, table.concat(reasons, "\n"))
                test.is_nil(result.error, tostring(result.error))
                test.eq(result.mode, "batch")
                test.is_nil(result.window_error, tostring(result.window_error))
                test.eq(result.window_mode, "window")
                local saved = false
                for _, row in ipairs(candidate_rows(assert(bounds.object(result.page)))) do
                    if row.kind == "profile" and row.ref == result.profile_id then test.eq(row.status, "ready"); saved = true end
                end
                test.is_true(saved)
                local window = false
                for _, row in ipairs(candidate_rows(listing)) do
                    if row.ref == "bee.driver.claude.profiles:default_window" then test.eq(row.status, "ready"); window = true end
                    if row.ref == ref then test.eq(row.status, "ready") end
                end
                test.is_true(window)
            end)
            changes = registry.snapshot():changes(); changes:update(original); changes:update(original_policy); assert(changes:apply())
            assert(ok, tostring(failure))
        end)
        test.it("loads production definition and profile rows through the Agents UI client", function()
            local result = through_production_catalog("ui")
            test.is_nil(result.error, tostring(result.error))
            local listing = assert(bounds.object(result.listing))
            local kinds: {[string]: boolean} = {}
            for _, row in ipairs(candidate_rows(listing)) do kinds[assert(bounds.id(row.kind))] = true end
            test.is_true(kinds.definition)
            test.is_true(kinds.profile)
        end)
        test.it("preserves production hook capabilities through the Sessions SDK", function()
            local result = through_production_catalog("sdk")
            test.is_nil(result.error, tostring(result.error))
            assert_catalog(assert(bounds.object(result.page)))
        end)
        test.it("validates production hook capabilities through the MCP session_catalog output schema", function()
            local result = through_production_catalog("mcp")
            test.is_nil(result.error, tostring(result.error))
            local reply = assert(bounds.object(result.reply))
            test.is_true(reply.ok)
            assert_catalog(assert(bounds.object(reply.value)))
        end)
        test.it("rejects malformed hook capabilities in the shared decoder and MCP schema", function()
            local reply = assert(bounds.object(through_production_catalog("validation").reply))
            local page = assert(bounds.object(reply.value))
            test.not_nil(protocol.decode_catalog_page(page))
            test.not_nil(session_tools.result("session_catalog", reply))
            local row = candidate_rows(page)[1]
            local valid = {point = "tool.before", supported = true, allowed_results = {"pass", "deny"}, reason = "Verified response"}
            local malformed: {unknown} = {
                {{point = "tool.before", supported = "yes", allowed_results = {"pass"}, reason = "Verified"}},
                {{point = "unknown", supported = true, allowed_results = {"pass"}, reason = "Verified"}},
                {{point = "tool.before", supported = true, allowed_results = {"unknown"}, reason = "Verified"}},
                {{point = "tool.before", supported = true, allowed_results = {"pass"}, reason = 1}},
                {{point = "tool.before", supported = true, allowed_results = {"pass"}, reason = "Verified", extra = true}},
                {{point = "tool.before", supported = false, allowed_results = {"deny"}, reason = "Unsupported"}},
                {valid, valid},
                {valid, valid, valid, valid, valid},
            }
            for index, invalid in ipairs(malformed) do
                row.hook_capabilities = invalid
                test.is_nil(protocol.decode_catalog_page(page), tostring(index))
                test.is_nil(session_tools.result("session_catalog", reply), tostring(index))
            end
            row.hook_capabilities = nil
            test.not_nil(protocol.decode_catalog_page(page))
            test.not_nil(session_tools.result("session_catalog", reply))
        end)
    end)
end
M.run = test.run_cases(define_tests)
return M
