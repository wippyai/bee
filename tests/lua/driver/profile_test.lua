-- MIT. Binding declarations decode with exact shapes and conservative
-- defaults; both shipped providers validate, and lies are rejected.
local test = require("test")
local registry = require("registry")
local profile = require("profile")
local function declaration(): {[string]: unknown}
    return {schema_revision = "bee.driver@1", kind = "harness", title = "Probe", implementation_version = "1.0.0", default_profile = "batch",
        profiles = {{id = "batch", mode = "batch", protocol = "stream-json", protocol_revision = "probe-1", answer_path = {strategy = "terminal_field", adapter_ref = "probe:protocol"}}}}
end
local function define_tests()
    test.describe("Driver profiles", function()
        test.it("applies conservative defaults to a minimal profile", function()
            local binding, err = profile.decode(declaration())
            if not binding then error(tostring(err)) end
            local batch = binding.profiles[1]
            test.eq(batch.resume.strategy, "none")
            test.is_false(batch.resume.portable)
            test.eq(#batch.inbound, 0)
            test.is_true(batch.isolation_env.private_home)
            test.is_false(batch.trust_preanswer.supported)
            test.is_false(batch.exit_codes_trustworthy)
            test.eq(batch.input_ready.strategy, "none")
            test.eq(batch.input_ready.timeout_ms, 15000)
            test.eq(#batch.interrupt.methods, 0)
            test.eq(#batch.mcp.client_transports, 0)
            test.eq(#batch.sandbox.providers, 0)
            test.eq(batch.permission_exchange.mode, "none")
            test.not_nil(profile.find(binding, "batch"))
            test.is_nil(profile.find(binding, "window"))
        end)
        test.it("declares a PTY window without inventing structured answers", function()
            local entry = declaration()
            entry.profiles[1].mode = "window"
            entry.profiles[1].protocol = "pty"
            entry.profiles[1].answer_path = {strategy = "none"}
            local binding, err = profile.decode(entry)
            if not binding then error(tostring(err)) end
            test.eq(binding.profiles[1].answer_path.strategy, "none")
            entry.profiles[1].answer_path = {strategy = "none", adapter_ref = "probe:protocol"}
            local _, adapter_error = profile.decode(entry)
            test.eq(adapter_error, "profile batch.answer_path names an adapter while disabled")
            entry.profiles[1].answer_path = {strategy = "none"}
            entry.profiles[1].mode = "batch"
            entry.profiles[1].protocol = "stream-json"
            local _, mode_error = profile.decode(entry)
            test.eq(mode_error, "profile batch.answer_path none requires a PTY window")
            entry.profiles[1].answer_path = {strategy = "terminal_field"}
            local _, missing_error = profile.decode(entry)
            test.eq(missing_error, "profile batch.answer_path.adapter_ref is not an identifier")
        end)
        test.it("enables a permission exchange only with a pinned adapter reference and digest", function()
            local enabled = declaration()
            enabled.profiles[1].permission_exchange = {mode = "adapter", adapter_ref = "probe:permission", adapter_digest = string.rep("a", 64)}
            local binding, err = profile.decode(enabled)
            if not binding then error(tostring(err)) end
            test.eq(binding.profiles[1].permission_exchange.adapter_ref, "probe:permission")
            local unpinned = declaration()
            unpinned.profiles[1].permission_exchange = {mode = "adapter", adapter_ref = "probe:permission"}
            local _, unpinned_error = profile.decode(unpinned)
            test.eq(unpinned_error, "profile batch.permission_exchange needs adapter_ref and adapter_digest when enabled")
            local disabled = declaration()
            disabled.profiles[1].permission_exchange = {mode = "none", adapter_ref = "probe:permission"}
            local _, disabled_error = profile.decode(disabled)
            test.eq(disabled_error, "profile batch.permission_exchange names an adapter while disabled")
            local odd = declaration()
            odd.profiles[1].permission_exchange = {mode = "ask"}
            local _, odd_error = profile.decode(odd)
            test.eq(odd_error, "profile batch.permission_exchange.mode must be none or adapter")
        end)
        test.it("rejects unknown fields, unsupported values and inconsistent declarations", function()
            local extra = declaration()
            extra.profiles[1].yolo = true
            local _, extra_error = profile.decode(extra)
            test.eq(extra_error, "profile: unknown field yolo")
            local revision = declaration()
            revision.schema_revision = "bee.driver@2"
            local _, revision_error = profile.decode(revision)
            test.eq(revision_error, "meta.driver.schema_revision must be bee.driver@1")
            local missing = declaration()
            missing.default_profile = "window"
            local _, missing_error = profile.decode(missing)
            test.eq(missing_error, "default_profile window is not declared")
            local trust = declaration()
            trust.profiles[1].trust_preanswer = {supported = true}
            local _, trust_error = profile.decode(trust)
            test.eq(trust_error, "profile batch.trust_preanswer needs adapter_ref when supported")
            local inbound = declaration()
            inbound.profiles[1].inbound = {"telepathy"}
            local _, inbound_error = profile.decode(inbound)
            test.eq(inbound_error, "profile batch.inbound does not support telepathy")
            local filter = declaration()
            filter.profiles[1].mcp = {tool_filter = {syntax = "glob"}}
            local _, filter_error = profile.decode(filter)
            test.eq(filter_error, "profile batch.mcp.tool_filter needs syntax and adapter_ref")
            local twice = declaration()
            twice.profiles[2] = twice.profiles[1]
            local _, twice_error = profile.decode(twice)
            test.eq(twice_error, "profile batch is declared twice")
            local exit = declaration()
            exit.profiles[1].exit_codes_trustworthy = "yes"
            local _, exit_error = profile.decode(exit)
            test.eq(exit_error, "profile batch.exit_codes_trustworthy must be a boolean")
        end)
        test.it("validates the shipped Claude, Codex and Muse bindings", function()
            for _, id in ipairs({"bee.driver.claude:binding", "bee.driver.codex:binding", "bee.driver.muse:binding"}) do
                local entry, err = registry.get(id)
                if not entry then error(id .. ": " .. tostring(err)) end
                test.eq(entry.meta.type, "harness.driver")
                local declaration, declaration_error = registry.get(tostring(entry.meta.profiles_ref))
                if not declaration then error(id .. " profiles: " .. tostring(declaration_error)) end
                test.eq(declaration.meta.driver_ref, id)
                local binding, decode_error = profile.decode(declaration.data.driver)
                if not binding then error(id .. ": " .. tostring(decode_error)) end
                test.eq(binding.kind, "harness")
                local default = profile.find(binding, binding.default_profile)
                if not default then error(id .. " default profile missing") end
                test.eq(default.protocol, "stream-json")
                test.is_false(default.exit_codes_trustworthy)
                test.is_false(default.trust_preanswer.supported)
                test.eq(default.resume.strategy, "per-process")
                local window = profile.find(binding, "window")
                if not window then error(id .. " window profile missing") end
                test.eq(window.mode, "window")
                test.eq(window.protocol, "pty")
                test.eq(window.answer_path.strategy, "none")
                test.is_false(window.isolation_env.private_home)
                test.is_false(window.exit_codes_trustworthy)
                test.eq(window.input_ready.strategy, "none")
                test.eq(window.permission_exchange.mode, "none")
            end
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
