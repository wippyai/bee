-- MIT. Public replica requests are action-specific and bind authorization to
-- the source owner carried by the measured descriptor or explicit replica key.
local test = require("test")
local protocol = require("protocol")
local version = require("version")
local hash = require("hash")

local function descriptor(): version.Descriptor
    local measured, measure_error = hash.sha256("content")
    if not measured then error(tostring(measure_error)) end
    local item, create_error = version.create("source-a", "apps", "demo-v1", "demo", "v1",
        measured, "governance.registry-entries", 7, {schema = "bee.governance-entries@1"})
    if not item then error(tostring(create_error)) end
    return item
end

local function define_tests()
    test.describe("Replica receive protocol", function()
        test.it("derives the source policy resource from a measured begin descriptor", function()
            local request, err = protocol.decode({action = "begin", descriptor = descriptor(), source_cursor = 4})
            test.is_nil(err)
            test.eq(request and request.source_owner, "source-a")
            test.eq(request and request.source_cursor, 4)
        end)
        test.it("requires the complete immutable key for status and finish", function()
            local item = descriptor()
            local request, err = protocol.decode({action = "status", source_owner = item.owner_id,
                feed = item.feed, version_key = item.key, descriptor_digest = item.digest})
            test.is_nil(err)
            test.eq(request and request.action, "status")
            local missing = protocol.decode({action = "finish", source_owner = item.owner_id})
            test.is_nil(missing)
        end)
        test.it("refuses fields from another action and oversized chunks", function()
            local item = descriptor()
            local crossed = protocol.decode({action = "begin", descriptor = item, source_cursor = 1, offset = 0})
            test.is_nil(crossed)
            local oversized = protocol.decode({action = "put", source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest, offset = 0,
                content_base64 = string.rep("a", protocol.MAX_ENCODED_CHUNK_BYTES + 1)})
            test.is_nil(oversized)
        end)
    end)
end

return test.run_cases(define_tests)
