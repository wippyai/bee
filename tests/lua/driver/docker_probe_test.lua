-- SPDX-License-Identifier: MIT
local test = require("test")
local probe = require("probe")
local bounds = require("bounds")
local registry = require("registry")
local json = require("json")
local locate = require("locate")
local function define_tests()
    test.describe("Docker descriptor probes", function()
        test.it("rejects a native client without a callable cleanup operation before launching", function()
            for _, client in ipairs({false, {}, {remove_container = true}}) do
                local output, err = probe.run(client, "sha256:" .. string.rep("a", 64), "codex", {"--version"})
                test.is_nil(output)
                test.eq(err, "Docker cleanup client is invalid")
            end
        end)
        test.it("uses cached immutable images with isolated help and version commands", function()
            local image = "sha256:" .. string.rep("a", 64)
            for _, args in ipairs({{"--version"}, {"exec", "--help"}}) do
                local argv = assert(probe.command(image, "codex", args, "bee-probe-01234567-abcd"))
                for _, flag in ipairs({"--pull=never", "--rm", "--read-only", "--cap-drop", "--security-opt", "--pids-limit", "--memory", "--user", "--tmpfs"}) do test.not_nil(bounds.member(flag, argv)) end
                test.not_nil(bounds.member(image, argv))
                test.not_nil(bounds.member("none", argv))
                test.is_nil(bounds.member("--mount", argv))
                test.is_nil(bounds.member("--volume", argv))
                test.eq(argv[#argv], args[#args])
            end
        end)
        test.it("probes image help and invalidates cached options when an image changes or disappears", function()
            local binding_ref = "bee.placement.docker.binding:binding"
            local descriptor_ref = "bee.driver.claude.descriptor:cli"
            local binding = assert(registry.get(binding_ref))
            local declaration = assert(registry.get(descriptor_ref))
            local saved_binding = assert(json.encode(binding.data))
            local saved_descriptor = assert(json.encode(declaration.data))
            local contracts = assert(bounds.array(assert(bounds.object(binding.data)).contracts, 16))
            local methods = assert(bounds.object(assert(bounds.object(contracts[1])).methods))
            methods.capabilities = "bee.driver:docker_capabilities_fixture"
            assert(bounds.object(declaration.data)).login_evidence = {command = "fixture login", any_of = {{kind = "env_present", names = {"PATH"}}}}
            local changes = registry.snapshot():changes()
            assert(changes:update(binding)); assert(changes:update(declaration)); assert(changes:apply())
            local cache = locate.new_cache()
            local profile = "bee.placement.docker.tests:profile"
            local function check(): unknown return locate.locate(registry.snapshot(), "bee.driver.claude:binding", "batch", cache, profile) end
            local first = check()
            local second = check()
            local facts = assert(registry.get("bee.driver:docker_probe_facts"))
            local data = assert(bounds.object(facts.data))
            local prior = data.calls
            data.digest = string.rep("b", 64); data.help = "no option flags"
            changes = registry.snapshot():changes(); assert(changes:update(facts)); assert(changes:apply())
            local changed = check()
            facts = assert(registry.get("bee.driver:docker_probe_facts")); data = assert(bounds.object(facts.data))
            local after = data.calls
            data.present = false
            changes = registry.snapshot():changes(); assert(changes:update(facts)); assert(changes:apply())
            local missing = check()
            binding.data = assert(json.decode(saved_binding)); declaration.data = assert(json.decode(saved_descriptor))
            changes = registry.snapshot():changes(); assert(changes:update(binding)); assert(changes:update(declaration)); assert(changes:apply())
            local ready = assert(bounds.object(first))
            if ready.status ~= "ready" then error(tostring(ready.reason)) end
            test.eq(assert(bounds.object(assert(bounds.object(ready.capabilities))["provider.model"])).supported, true)
            test.eq(assert(bounds.object(second)).executable and assert(bounds.object(assert(bounds.object(second)).executable)).version, "99.0.0")
            test.eq(assert(bounds.object(assert(bounds.object(assert(bounds.object(changed)).capabilities))["provider.model"])).supported, false)
            test.is_true(type(after) == "number" and type(prior) == "number" and after > prior + 1)
            test.eq(assert(bounds.object(missing)).status, "unknown")
            test.eq(assert(bounds.object(missing)).reason, "Docker image cache is empty")
        end)
        test.it("rejects mutable images, unbounded arguments and nonprivate identities", function()
            test.is_nil(probe.command("sha256:abc", "codex", {"--help"}, "bee-probe-01234567"))
            test.is_nil(probe.command("latest", "codex", {"--help"}, "bee-probe-01234567"))
            test.is_nil(probe.command("sha256:" .. string.rep("a", 64), "codex", {string.rep("x", 129)}, "bee-probe-01234567"))
            test.is_nil(probe.command("sha256:" .. string.rep("a", 64), "codex", {"--help"}, "existing-container"))
        end)
    end)
end
return test.run_cases(define_tests)
