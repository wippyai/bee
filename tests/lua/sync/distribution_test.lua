-- MIT. Distribution of exported feeds: a version appended to an exported feed
-- reaches each receiver route as soon as that receiver is ready, whatever
-- the others do, driven by the feed's committed changes; a destination behind
-- the feed's window receives the live versions of a pinned snapshot; the
-- node's receiver route accepts only versions the calling node owns.
local test = require("test")
local system = require("system")
local process = require("process")
local channel = require("channel")
local events = require("events")
local time = require("time")
local uuid = require("uuid")
local hash = require("hash")
local base64 = require("base64")
local hive = require("hive")
local sync = require("sync")
local replicas = require("replicas")
local cursors = require("cursors")
local version = require("version")
local distributor = require("distributor")

local EXPORTED = "tests.sync.versions"
local KIND = "tests.sync.blob"
local PEER = "syncpeer"
local PEER_NAME = "bee.tests.sync.peer"
local SECOND = "syncsecond"
local SECOND_NAME = "bee.tests.sync.second"

local function node(): string
    return assert(system.node.id())
end

local function descriptor(owner: string, feed: string, key: string, content: string): version.Descriptor
    local created, err = version.create(owner, feed, key, "object-" .. key, "v1", assert(hash.sha256(content)), KIND,
        #content, {title = key})
    if not created then error(tostring(err)) end
    return created
end

local function key_of(item: version.Descriptor): replicas.Key
    return {source_owner = item.owner_id, feed = item.feed, version_key = item.key, descriptor_digest = item.digest}
end

local function opened(events_capacity: integer?): sync.Store
    local store, err = sync.open({owner = node(), event_capacity = events_capacity})
    if not store then error(tostring(err)) end
    return store
end

-- publish makes a version available on this node, then appends it to its feed.
local function publish(store: sync.Store, feed: string, key: string, content: string): version.Descriptor
    local item = descriptor(store.owner, feed, key, content)
    local replica_store = assert(replicas.open())
    local steps = {replicas.begin(replica_store, item, 0)}
    local offset = 0
    while offset < #content do
        local ending = math.min(#content, offset + replicas.MAX_CHUNK_BYTES)
        steps[#steps + 1] = replicas.put(replica_store, key_of(item), offset, assert(base64.encode(content:sub(offset + 1, ending))))
        offset = ending
    end
    steps[#steps + 1] = replicas.finish(replica_store, key_of(item))
    replicas.close(replica_store)
    for _, step in ipairs(steps) do
        if not step.ok then error(tostring(step.code) .. ": " .. tostring(step.message)) end
    end
    local appended = store:append({feed = feed, event_id = item.digest, idempotency_key = item.digest,
        event_type = "version.published", payload = item, projection_key = key, projection_value = item})
    if not appended.ok then error(tostring(appended.message)) end
    return item
end

local function retract(store: sync.Store, feed: string, key: string)
    local retracted = store:append({feed = feed, event_id = "retract-" .. key, idempotency_key = "retract-" .. key,
        event_type = "version.retracted", payload = {key = key}, projection_key = key, tombstone = true})
    if not retracted.ok then error(tostring(retracted.message)) end
end

local function cursor(feed: string, route: string): unknown
    local store = assert(cursors.open())
    local current = cursors.cursor(store, node(), feed, distributor.key({node = node(), route = route}))
    cursors.close(store)
    local value: unknown = current.value
    return type(value) == "table" and value.cursor or nil
end

local function start_peer(name: string)
    if process.registry.lookup(name) then return end
    assert(process.spawn("bee.tests.sync:peer", "bee:workers", name))
end

-- next_event waits for an event on inbox that accept takes.
local function next_event(inbox: unknown, label: string, accept: (unknown) -> boolean): {[string]: unknown}
    local subscription = inbox :: channel.Channel
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({subscription:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("no " .. label) end
        local event: unknown = selected.value
        if accept(event) then return event :: {[string]: unknown} end
    end
end

-- received waits until each peer announces it holds version key.
local function received(inbox: unknown, peers: {string}, key: string): {[string]: string}
    local digests: {[string]: string} = {}
    local missing = #peers
    next_event(inbox, "delivery of " .. key, function(event: unknown): boolean
        if type(event) ~= "table" or event.path ~= key or type(event.data) ~= "table" then return false end
        for _, peer in ipairs(peers) do
            if event.data.peer == peer and not digests[peer] then
                digests[peer] = tostring(event.data.digest)
                missing = missing - 1
            end
        end
        return missing == 0
    end)
    return digests
end

-- distributed waits until distribution reports each route reached cursor.
local function distributed(inbox: unknown, routes: {string}, reached: integer)
    local seen: {[string]: boolean} = {}
    local missing = #routes
    next_event(inbox, "distribution up to " .. reached, function(event: unknown): boolean
        if type(event) ~= "table" or event.path ~= EXPORTED or type(event.data) ~= "table" or event.data.cursor ~= reached then return false end
        for _, route in ipairs(routes) do
            if event.data.route == route and not seen[route] then
                seen[route] = true
                missing = missing - 1
            end
        end
        return missing == 0
    end)
end

local function receive(input: {[string]: unknown}): {[string]: unknown}
    local reply, err = hive.call(node(), "sync.receive", input, "5s")
    if not reply then error(tostring(err)) end
    if not reply.ok then error(tostring(reply.error)) end
    return reply.value or {}
end

local function define_tests()
    test.describe("sync distribution", function()
        test.it("delivers appended versions to each receiver once it is ready", function()
            local deliveries = assert(events.subscribe("bee.tests.sync", "received")):channel()
            local progress = assert(events.subscribe("bee.sync", "distributed")):channel()
            local store = opened(nil)
            local first = publish(store, EXPORTED, "first", string.rep("a", replicas.MAX_CHUNK_BYTES + 5))
            start_peer(PEER_NAME)
            test.eq(received(deliveries, {PEER_NAME}, "first")[PEER_NAME], first.content_digest)
            distributed(progress, {PEER}, 1)
            start_peer(SECOND_NAME)
            test.eq(received(deliveries, {SECOND_NAME}, "first")[SECOND_NAME], first.content_digest)
            distributed(progress, {SECOND}, 1)
            local second = publish(store, EXPORTED, "second", "second version")
            local digests = received(deliveries, {PEER_NAME, SECOND_NAME}, "second")
            test.eq(digests[PEER_NAME], second.content_digest)
            test.eq(digests[SECOND_NAME], second.content_digest)
            distributed(progress, {PEER, SECOND}, 2)
            test.eq(cursor(EXPORTED, PEER), 2)
            test.eq(cursor(EXPORTED, SECOND), 2)
            store:close()
        end)

        test.it("delivers a pinned snapshot's live versions to a destination behind the window", function()
            local deliveries = assert(events.subscribe("bee.tests.sync", "received")):channel()
            local window = "tests.sync.window-" .. tostring(uuid.v7())
            local store = opened(1)
            publish(store, window, "a", "version a")
            publish(store, window, "b", "version b")
            publish(store, window, "c", "version c")
            retract(store, window, "b")
            store:close()
            start_peer(PEER_NAME)
            local delivered = distributor.distribute(node(), {node = node(), route = PEER}, {feed = window, content_kinds = {[KIND] = true}})
            test.is_true(delivered.ok)
            local seen: {string} = {}
            next_event(deliveries, "snapshot delivery", function(event: unknown): boolean
                if type(event) ~= "table" or type(event.data) ~= "table" or event.data.feed ~= window or event.data.peer ~= PEER_NAME then
                    return false
                end
                seen[#seen + 1] = tostring(event.path)
                return event.path == "c"
            end)
            test.eq(table.concat(seen, ","), "a,c")
            test.eq(cursor(window, PEER), 4)
        end)

        test.it("accepts over its route only versions the calling node owns", function()
            local foreign = receive({action = "begin", descriptor = descriptor("another-node", "tests.sync.foreign", "k", "content"), source_cursor = 0})
            test.is_false(foreign.ok)
            test.eq(foreign.code, "DENIED")
            local own = descriptor(node(), "tests.sync.own-" .. tostring(uuid.v7()), "k", "content")
            local key = key_of(own)
            test.is_true(receive({action = "begin", descriptor = own, source_cursor = 0}).ok)
            test.is_true(receive({action = "put", source_owner = key.source_owner, feed = key.feed, version_key = key.version_key,
                descriptor_digest = key.descriptor_digest, offset = 0, content_base64 = base64.encode("content")}).ok)
            local finished = receive({action = "finish", source_owner = key.source_owner, feed = key.feed, version_key = key.version_key,
                descriptor_digest = key.descriptor_digest})
            test.is_true(finished.ok)
            test.eq((finished.value :: {[string]: unknown}).state, "available")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
