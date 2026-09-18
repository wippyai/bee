-- MIT. Application versions remain inert and destination-independent through generic Hive replication.
local test = require("test")
local delivery = require("delivery")
local artifact = require("artifact")
local version = require("version")

local function application(selected_version: string): delivery.Delivery
    local exact = assert(artifact.create({{id = "sample.app:definition", kind = "registry.entry",
        data = {value = selected_version}}}))
    local result, result_error = delivery.create({schema_revision = delivery.SCHEMA,
        source_node = "node-source", source_workspace = "team/application",
        component = "sample/app", version = selected_version,
        artifact = {bytes = exact.bytes, digest = exact.digest}})
    if not result then error(tostring(result_error)) end
    return result
end

local function define_tests()
    test.describe("Governance application delivery", function()
        test.it("publishes one destination-independent immutable version", function()
            local item = application("v1")
            test.eq(delivery.SCHEMA, "bee.governance-application-version@2")
            local descriptor = assert(delivery.descriptor(item))
            local decoded = assert(delivery.decode(item.bytes, item.digest))
            local verified = assert(delivery.verify_descriptor(descriptor, decoded))
            test.eq(verified.owner_id, "node-source")
            test.eq(verified.feed, "governance.application_versions")
            test.eq(verified.object_id, "sample/app")
            test.eq(verified.version_id, "v1")
            test.eq(verified.key, item.key)
            test.eq(verified.content_kind, "bee.governance-application-version@2")
            test.eq(decoded.value.source_workspace, "team/application")
            test.eq(decoded.value.component, "sample/app")
            test.eq(decoded.value.artifact.bytes, item.value.artifact.bytes)
            test.is_nil(decoded.manifest.destination_node)
            test.is_nil(decoded.manifest.destination_workspace)
        end)

        test.it("refuses content, descriptor, manifest and logical-key substitution", function()
            local item = application("v1")
            test.is_nil(delivery.decode(item.bytes .. " ", item.digest))
            local descriptor = assert(delivery.descriptor(item))
            descriptor.manifest.component = "another/app"
            test.is_nil(delivery.verify_descriptor(descriptor, item))

            local second = application("v2")
            local wrong = assert(version.create("node-source", delivery.FEED, item.key,
                "sample/app", "v2", second.digest, delivery.CONTENT_KIND,
                #second.bytes, second.manifest))
            test.is_nil(delivery.verify_descriptor(wrong, second))
            test.is_false(item.key == second.key)
        end)
    end)
end

return test.run_cases(define_tests)
