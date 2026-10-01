-- SPDX-License-Identifier: MIT
local registry = require("registry")
local bounds = require("bounds")
function handle(raw: unknown): {[string]: unknown}
    local request = assert(bounds.object(raw))
    local entry = assert(registry.get("bee.driver:docker_probe_facts"))
    local facts = assert(bounds.object(entry.data))
    local calls = assert(bounds.count(facts.calls))
    facts.calls = calls + 1
    local changes = registry.snapshot():changes()
    assert(changes:update(entry)); assert(changes:apply())
    local argv = bounds.array(request.probe_argv, 8)
    local output: string? = nil
    if argv then
        output = argv[1] == "--version" and "Claude 99.0.0" or tostring(facts.help)
    end
    return {ok = true, value = {network_readiness = {present = true}, image_readiness = {present = facts.present,
        runtime_present = facts.present, image_digest = facts.digest, os = "linux", arch = "amd64", reason = "Docker image cache is empty"}, probe_output = output}}
end

return {handle = handle}
