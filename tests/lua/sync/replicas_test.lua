-- MIT. Remote versions are cached durably but are never selected here.
local test = require("test")
local replicas = require("replicas")
local version = require("version")
local uuid = require("uuid")
local hash = require("hash")
local base64 = require("base64")
local json = require("json")

local function required_digest(content: string): string
    local digest, err = hash.sha256(content)
    if not digest then error(tostring(err)) end
    return digest
end
local function required_uuid(): string
    local value, err = uuid.v7()
    if not value then error(tostring(err)) end
    return value
end
local function required_base64(content: string): string
    local encoded, err = base64.encode(content)
    if not encoded then error(tostring(err)) end
    return encoded
end
local function descriptor_for(owner: string, feed: string, key: string, content: string): version.Descriptor
    local digest = required_digest(content)
    local item, err = version.create(owner, feed, key, "demo", "v1", digest,
        "governance.registry-entries", #content, {schema = "bee.governance-entries@1", entries = 1})
    if not item then error(tostring(err)) end
    return item
end
local function descriptor(key: string, content: string): version.Descriptor
    return descriptor_for("node-a", "apps", key, content)
end
local function opened(): replicas.Store
    local store, err = replicas.open("bee.sync:sync_test_db")
    if not store then error(tostring(err)) end
    return store
end
local function transfer(store: replicas.Store, item: version.Descriptor, content: string, cursor: integer?): replicas.Result
    local begun = replicas.begin(store, item, cursor or 1)
    if not begun.ok then return begun end
    local offset = 0
    while offset < #content do
        local chunk_end: integer = offset + (replicas.MAX_CHUNK_BYTES :: integer)
        if chunk_end > #content then chunk_end = #content end
        local chunk = content:sub(offset + 1, chunk_end)
        local encoded = required_base64(chunk)
        local written = replicas.put(store, {source_owner = item.owner_id, feed = item.feed,
            version_key = item.key, descriptor_digest = item.digest}, offset, encoded)
        if not written.ok then return written end
        offset = offset + #chunk
    end
    return replicas.finish(store, {source_owner = item.owner_id, feed = item.feed,
        version_key = item.key, descriptor_digest = item.digest})
end
local function encoded_descriptor(item: version.Descriptor): string
    local encoded, encode_error = json.encode(item)
    if not encoded or encode_error then error(tostring(encode_error)) end
    return encoded
end
local function execute(store: replicas.Store, statement: string, parameters: {unknown})
    local _, execute_error = store.db:execute(statement, parameters)
    if execute_error then error(tostring(execute_error)) end
end
local function define_tests()
    test.describe("Source-qualified version replicas", function()
        test.it("retains exact content and replays the complete transfer", function()
            local store, key, content = opened(), required_uuid(), string.rep("payload", 6000)
            local item = descriptor(key, content)
            local first = transfer(store, item, content)
            test.is_true(first.ok)
            local available_status = replicas.status(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(available_status.ok)
            local available_value = available_status.value :: {[string]: unknown}
            test.eq(available_value.state, "available")
            test.eq(available_value.received_bytes, #content)
            test.eq(available_value.total_bytes, #content)
            local wrong_digest = replicas.status(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = string.rep("0", 64)})
            test.eq(wrong_digest.code, "CONFLICT")
            local stored, stored_error = replicas.content(store, {source_owner = item.owner_id,
                feed = item.feed, version_key = item.key, descriptor_digest = item.digest})
            test.is_nil(stored_error)
            test.eq(stored, content)
            local read = replicas.read(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(read.ok)
            local value = read.value :: {[string]: unknown}
            local read_descriptor = value.descriptor :: version.Descriptor
            test.eq(read_descriptor.digest, item.digest)
            test.eq(read_descriptor.owner_id, item.owner_id)
            test.eq(read_descriptor.feed, item.feed)
            test.eq(read_descriptor.key, item.key)
            test.eq(value.content, content)
            local replay = replicas.begin(store, item, 1)
            test.is_true(replay.ok)
            test.is_true(replay.replayed)
            test.eq((replay.value :: {[string]: unknown}).state, "available")
            test.is_true(replicas.close(store))
        end)
        test.it("names the source owners with available versions of one feed", function()
            local store = opened()
            local feed = "sources-" .. required_uuid()
            local first_owner, second_owner, pending_owner = "node-b-" .. required_uuid(), "node-a-" .. required_uuid(),
                "node-c-" .. required_uuid()
            test.is_true(transfer(store, descriptor_for(first_owner, feed, "v1", "one"), "one").ok)
            test.is_true(transfer(store, descriptor_for(first_owner, feed, "v2", "two"), "two").ok)
            test.is_true(transfer(store, descriptor_for(second_owner, feed, "v1", "three"), "three").ok)
            test.is_true(replicas.begin(store, descriptor_for(pending_owner, feed, "v1", "pending"), 1).ok)
            test.is_true(transfer(store, descriptor_for(first_owner, "other-" .. feed, "v1", "four"), "four").ok)
            local listed = replicas.sources(store, feed, 16)
            test.is_true(listed.ok)
            local owners = (listed.value :: {[string]: unknown}).sources :: {string}
            local expected = {first_owner, second_owner}
            table.sort(expected)
            test.eq(#owners, 2)
            test.eq(owners[1], expected[1])
            test.eq(owners[2], expected[2])
            test.eq(replicas.sources(store, feed, 0).code, "INVALID")
            test.is_true(replicas.close(store))
        end)
        test.it("resumes contiguous chunks and refuses changed identity or gaps", function()
            local store, key = opened(), required_uuid()
            local content = string.rep("x", replicas.MAX_CHUNK_BYTES) .. "tail"
            local item = descriptor(key, content)
            test.is_true(replicas.begin(store, item, 7).ok)
            local receiving_status = replicas.status(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(receiving_status.ok)
            local receiving_value = receiving_status.value :: {[string]: unknown}
            test.eq(receiving_value.state, "receiving")
            test.eq(receiving_value.received_bytes, 0)
            test.eq(receiving_value.total_bytes, #content)
            local first = required_base64(content:sub(1, replicas.MAX_CHUNK_BYTES :: integer))
            test.is_true(replicas.put(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}, 0, first).ok)
            local gap = replicas.put(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}, (replicas.MAX_CHUNK_BYTES :: integer) + 1, required_base64("tail"))
            test.eq(gap.code, "CONFLICT")
            local changed = descriptor(key, content .. "changed")
            test.eq(replicas.begin(store, changed, 8).code, "CONFLICT")
            local rest = required_base64("tail")
            test.is_true(replicas.put(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}, replicas.MAX_CHUNK_BYTES, rest).ok)
            test.is_true(replicas.finish(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}).ok)
            local available_status = replicas.status(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(available_status.ok)
            test.eq((available_status.value :: {[string]: unknown}).state, "available")
            test.is_true(replicas.close(store))
        end)
        test.it("does not let an out-of-order blob completion skip a discovery cursor", function()
            local store = opened()
            local source_owner = "node-cursor-" .. required_uuid()
            local feed = "cursor-test"
            local earlier_content, later_content = "first descriptor", "second descriptor"
            local earlier = descriptor_for(source_owner, feed, "version-1", earlier_content)
            local later = descriptor_for(source_owner, feed, "version-2", later_content)
            test.is_true(replicas.begin(store, earlier, 1).ok)
            test.is_true(transfer(store, later, later_content, 2).ok)

            local after_later = replicas.cursor(store, {source_owner = source_owner, feed = feed})
            test.is_true(after_later.ok)
            test.eq((after_later.value :: {[string]: unknown}).cursor, 0)

            test.is_true(transfer(store, earlier, earlier_content, 1).ok)
            local after_both = replicas.cursor(store, {source_owner = source_owner, feed = feed})
            test.is_true(after_both.ok)
            test.eq((after_both.value :: {[string]: unknown}).cursor, 0)

            local checkpoint = replicas.advance_cursor(store, {source_owner = source_owner, feed = feed,
                expected_cursor = 0, next_cursor = 2})
            test.is_true(checkpoint.ok)
            test.eq((checkpoint.value :: {[string]: unknown}).cursor, 2)
            local stale = replicas.advance_cursor(store, {source_owner = source_owner, feed = feed,
                expected_cursor = 0, next_cursor = 3})
            test.eq(stale.code, "CONFLICT")
            test.is_true(replicas.close(store))
        end)
        test.it("lists only available descriptors for one exact source feed", function()
            local store = opened()
            local owner = "node-list-" .. required_uuid()
            local first = descriptor_for(owner, "published-apps", "app-v1", "one")
            local second = descriptor_for(owner, "published-apps", "app-v2", "two")
            local other = descriptor_for(owner, "other-feed", "app-v3", "three")
            test.is_true(transfer(store, first, "one", 1).ok)
            test.is_true(replicas.begin(store, second, 2).ok)
            test.is_true(transfer(store, other, "three", 1).ok)

            local listed = replicas.available(store, owner, "published-apps", 16)
            test.is_true(listed.ok)
            local value = listed.value :: {[string]: unknown}
            local items = value.items :: {version.Descriptor}
            test.eq(#items, 1)
            test.eq(items[1].digest, first.digest)
            test.eq(items[1].key, first.key)
            test.is_true(replicas.close(store))
        end)
        test.it("does not expose incomplete or digest-mismatched content", function()
            local store, key, content = opened(), required_uuid(), "expected"
            local item = descriptor(key, content)
            local missing = replicas.status(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.eq(missing.code, "NOT_FOUND")
            test.is_true(replicas.begin(store, item, 1).ok)
            local receiving_status = replicas.status(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(receiving_status.ok)
            test.eq((receiving_status.value :: {[string]: unknown}).state, "receiving")
            test.is_nil(replicas.content(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}))
            test.eq(replicas.read(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}).code, "NOT_FOUND")
            test.is_true(replicas.put(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}, 0, required_base64("altered!")).ok)
            test.eq(replicas.finish(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}).code, "CONFLICT")
            test.is_true(replicas.close(store))
        end)
        test.it("rejects substituted descriptor and blob rows", function()
            local store = opened()
            local content = "verified replica"
            local item = descriptor(required_uuid(), content)
            local replacement = descriptor(required_uuid(), "replacement")
            test.is_true(transfer(store, item, content).ok)
            local original = replicas.read(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.is_true(original.ok)

            execute(store, "UPDATE bee_sync_replica_versions SET descriptor_json = ? WHERE source_owner = ? AND feed = ? AND version_key = ?",
                {encoded_descriptor(replacement), item.owner_id, item.feed, item.key})
            local substituted_descriptor = replicas.read(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.eq(substituted_descriptor.code, "CONFLICT")

            execute(store, "UPDATE bee_sync_replica_versions SET descriptor_json = ? WHERE source_owner = ? AND feed = ? AND version_key = ?",
                {encoded_descriptor(item), item.owner_id, item.feed, item.key})
            local blob = "substituted blob"
            execute(store, "UPDATE bee_sync_replica_chunks SET content_base64 = ?, content_sha256 = ? WHERE source_owner = ? AND feed = ? AND version_key = ?",
                {required_base64(blob), required_digest(blob), item.owner_id, item.feed, item.key})
            local substituted_blob = replicas.read(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = item.key, descriptor_digest = item.digest})
            test.eq(substituted_blob.code, "CONFLICT")
            test.is_true(replicas.close(store))
        end)
        test.it("finishes and reads an empty immutable version without a chunk", function()
            local store, key = opened(), required_uuid()
            local item = descriptor(key, "")
            test.is_true(replicas.begin(store, item, 9).ok)
            test.is_true(replicas.finish(store, {source_owner = item.owner_id, feed = item.feed,
                version_key = key, descriptor_digest = item.digest}).ok)
            local stored, stored_error = replicas.content(store, {source_owner = item.owner_id,
                feed = item.feed, version_key = key, descriptor_digest = item.digest})
            test.is_nil(stored_error)
            test.eq(stored, "")
            test.is_true(replicas.close(store))
        end)
    end)
end
return test.run_cases(define_tests)
