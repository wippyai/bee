-- MIT. Source publication persists exact bytes before advertising one
-- destination-independent descriptor through the ordered Sync feed.
local test = require("test")
local uuid = require("uuid")
local hash = require("hash")
local publisher = require("publisher")
local delivery = require("delivery")
local artifact = require("artifact")
local replicas = require("replicas")
local sync = require("sync")
local staging = require("staging")

local function define_tests()
    test.describe("application version publisher", function()
        test.it("publishes exact bytes once and names no destination", function()
            local suffix = assert(uuid.v7())
            local source = "publisher-" .. suffix
            local exact = assert(artifact.create({{id = "published.app:main", kind = "function.lua",
                data = {source = "return 'published'"}}}))
            local request = {source_workspace = "workspace/application", component = "published/app",
                version = "1.0.0", artifact = {bytes = exact.bytes, digest = exact.digest}}
            local expected = assert(delivery.create({schema_revision = delivery.SCHEMA, source_node = source,
                source_workspace = request.source_workspace, component = request.component,
                version = request.version, artifact = request.artifact}))
            local prepared = publisher.prepare("bee.sync:sync_test_db", source, request)
            test.is_true(prepared.ok)
            local before_feed = assert(sync.open({resource = "bee.sync:sync_test_db", owner = source}))
            local empty = sync.read_after(before_feed, delivery.FEED, 0, 16)
            test.is_true(empty.ok)
            test.eq(#(((empty.value :: {[string]: unknown}).events :: {unknown})), 0)
            assert(sync.close(before_feed))
            local first = publisher.publish("bee.sync:sync_test_db", source, request)
            test.is_true(first.ok)
            local replay = publisher.publish("bee.sync:sync_test_db", source, request)
            test.is_true(replay.ok)
            test.is_true(replay.replayed)

            local receipt = first.value :: {[string]: unknown}
            local descriptor = receipt.descriptor :: {[string]: unknown}
            test.is_nil(descriptor.destination_node)
            test.is_nil((descriptor.manifest :: {[string]: unknown}).destination_workspace)
            local replica_store = assert(replicas.open("bee.sync:sync_test_db"))
            local stored = replicas.read(replica_store, {source_owner = source, feed = descriptor.feed :: string,
                version_key = descriptor.key :: string, descriptor_digest = descriptor.digest :: string})
            test.is_true(stored.ok)
            test.eq((stored.value :: {[string]: unknown}).content, expected.bytes)
            test.is_true(replicas.close(replica_store))

            local feed_store = assert(sync.open({resource = "bee.sync:sync_test_db", owner = source}))
            local page = sync.read_after(feed_store, descriptor.feed, 0, 16)
            test.is_true(page.ok)
            local events = ((page.value :: {[string]: unknown}).events :: {{[string]: unknown}})
            test.eq(#events, 1)
            test.eq((events[1].payload :: {[string]: unknown}).digest, descriptor.digest)
            assert(sync.close(feed_store))

            local changed = assert(artifact.create({{id = "published.app:main", kind = "function.lua",
                data = {source = "return 'changed'"}}}))
            local conflict = publisher.publish("bee.sync:sync_test_db", source, {
                source_workspace = request.source_workspace, component = request.component,
                version = request.version, artifact = {bytes = changed.bytes, digest = changed.digest}})
            test.eq(conflict.code, "CONFLICT")
        end)

        test.it("lets a host-selected publisher read an exact foreign-owned frozen file", function()
            local suffix = assert(uuid.v7())
            local node = "publication-node-" .. suffix
            local workspace = "publication-workspace-" .. suffix
            local store = assert(staging.open("bee.gov:plan_test_db", node))
            local created = store:call("author-a", {operation = "create", workspace_id = workspace,
                expected_revision = 0, idempotency_key = "create"})
            test.is_true(created.ok)
            local put = store:call("author-a", {operation = "put", workspace_id = workspace,
                expected_revision = 1, idempotency_key = "put", path = "entries.json", content = "[]"})
            test.is_true(put.ok)
            local frozen = store:call("author-a", {operation = "freeze", workspace_id = workspace,
                expected_revision = 2, idempotency_key = "freeze"})
            test.is_true(frozen.ok)
            local digest = (frozen.value :: {[string]: unknown}).digest :: string
            local denied = store:call("author-b", {operation = "read", workspace_id = workspace,
                path = "entries.json", snapshot_digest = digest})
            test.eq(denied.code, "DENIED")
            local read = store:read_frozen(workspace, "entries.json", digest)
            test.is_true(read.ok)
            test.eq((read.value :: {[string]: unknown}).content_base64, "W10=")
            test.is_true(store:close())
        end)
        test.it("assembles large authored files with checked append, CAS and replay", function()
            local suffix = assert(uuid.v7())
            local store = assert(staging.open("bee.gov:plan_test_db", "append-node-" .. suffix))
            local id = "append-" .. suffix
            test.is_true(store:call("author-a", {operation = "create", workspace_id = id,
                expected_revision = 0, idempotency_key = "create"}).ok)
            local owned = store:call("author-a", {operation = "list", workspace_id = "", owned = true})
            test.is_true(owned.ok)
            local overlays = (owned.value :: {[string]: unknown}).overlays :: {{[string]: unknown}}
            test.eq(#overlays, 1)
            test.eq(overlays[1].workspace_id, id)
            local foreign = store:call("author-b", {operation = "list", workspace_id = "", owned = true})
            test.eq(#((foreign.value :: {[string]: unknown}).overlays :: {unknown}), 0)
            local first = string.rep("x", 65536)
            local tail = string.rep("y", 20000)
            test.is_true(store:call("author-a", {operation = "put", workspace_id = id,
                expected_revision = 1, idempotency_key = "put", path = "entries.json", content = first}).ok)
            local complete_digest = assert(hash.sha256(first .. tail))
            local appended = store:call("author-a", {operation = "append", workspace_id = id, expected_revision = 2,
                idempotency_key = "append", path = "entries.json", offset = #first,
                content = tail})
            test.is_true(appended.ok)
            test.eq((appended.value :: {[string]: unknown}).revision, 3)
            test.is_true(store:call("author-a", {operation = "append", workspace_id = id, expected_revision = 2,
                idempotency_key = "append", path = "entries.json", offset = #first,
                content = tail}).replayed)
            test.eq(store:call("author-a", {operation = "append", workspace_id = id, expected_revision = 2,
                idempotency_key = "append", path = "entries.json", offset = #first,
                content = "changed"}).code, "CONFLICT")
            test.eq(store:call("author-a", {operation = "append", workspace_id = id, expected_revision = 3,
                idempotency_key = "wrong", path = "entries.json", offset = 0,
                content = tail, result_digest = complete_digest}).code, "CONFLICT")
            test.eq(store:call("author-a", {operation = "append", workspace_id = id, expected_revision = 3,
                idempotency_key = "bad-digest", path = "entries.json", offset = #first + #tail,
                content = tail, result_digest = complete_digest}).code, "INVALID")
            local read = store:call("author-a", {operation = "read", workspace_id = id, path = "entries.json"})
            test.is_true(read.ok)
            test.eq((read.value :: {[string]: unknown}).bytes, #first + #tail)
            test.eq((read.value :: {[string]: unknown}).digest, complete_digest)
            test.eq((read.value :: {[string]: unknown}).chunk_bytes, 16384)
            test.is_false((read.value :: {[string]: unknown}).eof)
            local next_page = store:call("author-a", {operation = "read", workspace_id = id,
                path = "entries.json", offset = 16384, limit = 8192})
            test.is_true(next_page.ok)
            test.eq((next_page.value :: {[string]: unknown}).offset, 16384)
            test.eq((next_page.value :: {[string]: unknown}).chunk_bytes, 8192)
            test.is_true(store:close())
        end)

        test.it("contains workspace capacity per author instead of exhausting the node", function()
            local suffix = assert(uuid.v7())
            local store = assert(staging.open("bee.gov:plan_test_db", "capacity-node-" .. suffix))
            for index = 1, 8 do
                local created = store:call("bounded-author", {operation = "create",
                    workspace_id = "bounded-" .. tostring(index), expected_revision = 0,
                    idempotency_key = "create-" .. tostring(index)})
                test.is_true(created.ok)
            end
            local exhausted = store:call("bounded-author", {operation = "create",
                workspace_id = "bounded-9", expected_revision = 0, idempotency_key = "create-9"})
            test.eq(exhausted.code, "CAPACITY_EXHAUSTED")
            local other = store:call("other-author", {operation = "create",
                workspace_id = "other-1", expected_revision = 0, idempotency_key = "create-other"})
            test.is_true(other.ok)
            test.is_true(store:close())
        end)
    end)
end

return test.run_cases(define_tests)
