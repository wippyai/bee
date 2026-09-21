-- MIT. Pure governed application-admission value tests.
local test = require("test")
local admission = require("application_admission")

local DIGEST = string.rep("a", 64)

local function record(): {[string]: unknown}
    return {schema_revision = admission.SCHEMA, workspace_id = "workspace-a",
        overlay_owner = "bee.apps:workspace-a", source_node = "node-source",
        source_workspace = "vendor/app", artifact_digest = DIGEST, policy_digest = DIGEST,
        bindings = {
            {definition_id = "vendor.app:second", policies = {"bee:policy-b", "bee:policy-a"},
                thread_access = "observe_post"},
            {definition_id = "vendor.app:first", policies = {}},
        }}
end

local function projection(): {[string]: unknown}
    return {workspace_id = "workspace-a", overlay_owner = "bee.apps:workspace-a",
        source_node = "node-source", source_workspace = "vendor/app", artifact_digest = DIGEST,
        bindings = {{definition_id = "vendor.app:first", policies = {"bee:ordinary-policy"},
            thread_access = "observe_post"}},
        artifact_entries = {{id = "vendor.app:first", kind = "process.lua",
            meta = {type = "bee.application"}, data = {source = "return true"}}},
        registry_entries = {{id = "bee:ordinary-policy", kind = "security.policy",
            policy = {actions = {"funcs.call"}, resources = {"bee.app:read"}, effect = "allow"},
            registry = {owner = "bee/host"}}}, overlay_ids = {}}
end

local function define_tests()
    test.describe("governed application admission contract", function()
        test.it("normalizes bindings, policies and default thread access", function()
            local measured, measured_error = admission.measure(record())
            if not measured then error(tostring(measured_error)) end
            test.eq(measured.record.bindings[1].definition_id, "vendor.app:first")
            test.eq(measured.record.bindings[1].thread_access, "none")
            test.eq(measured.record.bindings[2].policies[1], "bee:policy-a")
            test.eq(measured.record.bindings[2].thread_access, "observe_post")
            test.is_true(measured.bytes:find('"policies":[]', 1, true) ~= nil)
            test.eq(#measured.digest, 64)
            local repeated = assert(admission.measure(measured.record))
            test.eq(repeated.bytes, measured.bytes)
            test.eq(repeated.digest, measured.digest)
        end)

        test.it("derives one stable reserved identity from the overlay owner", function()
            local first = assert(admission.id("bee.apps:workspace-a"))
            local second = assert(admission.id("bee.apps:workspace-a"))
            local other = assert(admission.id("bee.apps:workspace-b"))
            test.eq(first, second)
            test.is_true(first:sub(1, #admission.RESERVED_PREFIX) == admission.RESERVED_PREFIX)
            test.is_true(first ~= other)
            test.is_nil(admission.id("bad\nowner"))
        end)

        test.it("canonically decodes immutable bytes and builds the derived registry entry", function()
            local measured = assert(admission.measure(record()))
            local decoded = assert(admission.decode(measured.bytes, measured.digest))
            local entry = assert(admission.entry(measured.bytes, measured.digest))
            test.eq(decoded.bytes, measured.bytes)
            test.eq(entry.id, measured.id)
            test.eq(entry.kind, "registry.entry")
            test.eq(entry.data.artifact_digest, DIGEST)
            test.is_nil(admission.decode(measured.bytes .. " ", measured.digest))
            test.is_nil(admission.entry(measured.bytes, string.rep("b", 64)))
        end)

        test.it("reserves every prefix identity, including malformed forgery suffixes", function()
            test.is_true(admission.reserved(admission.RESERVED_PREFIX .. "not-a-digest"))
            test.is_true(admission.reserved(assert(admission.id("bee.apps:workspace-a"))))
            test.is_false(admission.reserved("bee.governance:ordinary"))
        end)

        test.it("rejects unknown authority and malformed thread access", function()
            local value = record()
            local rows = value.bindings :: {{[string]: unknown}}
            rows[1].appearance_write = true
            test.is_nil(admission.measure(value))
            rows[1].appearance_write = nil
            rows[1].thread_access = "all"
            test.is_nil(admission.measure(value))
            rows[1].thread_access = "observe_post"
            value.extra = true
            test.is_nil(admission.measure(value))
        end)

        test.it("rejects sparse, duplicate and over-bound selections", function()
            local value = record()
            local rows = value.bindings :: {{[string]: unknown}}
            rows[2] = nil
            rows[3] = {definition_id = "vendor.app:third", policies = {}}
            test.is_nil(admission.measure(value))

            value = record()
            rows = value.bindings :: {{[string]: unknown}}
            rows[2].definition_id = rows[1].definition_id
            test.is_nil(admission.measure(value))

            value = record()
            rows = value.bindings :: {{[string]: unknown}}
            rows[1].policies = {"bee:policy-a", "bee:policy-a"}
            test.is_nil(admission.measure(value))

            local policies: {string} = {}
            for index = 1, admission.MAX_POLICIES + 1 do policies[index] = "bee:policy-" .. tostring(index) end
            rows[1].policies = policies
            test.is_nil(admission.measure(value))
        end)

        test.it("requires exact identity and digest fields", function()
            local value = record()
            value.artifact_digest = "short"
            test.is_nil(admission.measure(value))
            value = record()
            value.schema_revision = "bee.governance-application-admission@2"
            test.is_nil(admission.measure(value))
            value = record()
            value.overlay_owner = "bad\nowner"
            test.is_nil(admission.measure(value))
        end)

        test.it("measures exact external policy bodies for an artifact application", function()
            local value = projection()
            local first, first_error = admission.project(value)
            if not first then error(tostring(first_error)) end
            test.eq(first.record.bindings[1].thread_access, "observe_post")
            local registry_entries = value.registry_entries :: {{[string]: unknown}}
            local policy = registry_entries[1].policy :: {[string]: unknown}
            policy.comment = "changed"
            local changed = assert(admission.project(value))
            test.is_true(changed.record.policy_digest ~= first.record.policy_digest)
            test.is_true(changed.digest ~= first.digest)
        end)

        test.it("requires exact artifact applications and external policies", function()
            local value = projection()
            local artifact_entries = value.artifact_entries :: {{[string]: unknown}}
            artifact_entries[1].kind = "function.lua"
            test.is_nil(admission.project(value))
            artifact_entries[1].kind = "process.lua"
            local meta = artifact_entries[1].meta :: {[string]: unknown}
            meta.type = "ordinary"
            test.is_nil(admission.project(value))
            meta.type = "bee.application"
            local registry_entries = value.registry_entries :: {{[string]: unknown}}
            registry_entries[1].kind = "function.lua"
            test.is_nil(admission.project(value))
            registry_entries[1].kind = "security.policy"
            value.overlay_ids = { ["bee:ordinary-policy"] = true }
            test.is_nil(admission.project(value))
            value.overlay_ids = {}
            artifact_entries[2] = registry_entries[1]
            test.is_nil(admission.project(value))
        end)
    end)
end

return test.run_cases(define_tests)
