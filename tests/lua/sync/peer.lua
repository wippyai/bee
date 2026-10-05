-- MIT. Another replica receiver for the suite: serves the route of the name it
-- starts with, keeps the versions it receives in memory and announces each
-- finished version on the event bus with the digest of the bytes it
-- assembled.
local process = require("process")
local channel = require("channel")
local events = require("events")
local hash = require("hash")
local base64 = require("base64")
local protocol = require("protocol")

type Transfer = {owner: string, feed: string, key: string, total: integer, digest: string, parts: {string}, received: integer, available: boolean}

local function main(name: string)
    local requests = assert(process.listen(protocol.FORWARD, {message = true}))
    assert(process.registry.register(name))
    assert(protocol.ready(name))
    local transfers: {[string]: Transfer} = {}

    local function result(item: Transfer, replayed: boolean): {[string]: unknown}
        return {ok = true, replayed = replayed, value = {source_owner = item.owner, feed = item.feed, key = item.key,
            state = item.available and "available" or "receiving", received_bytes = item.received, total_bytes = item.total}}
    end

    local function handle(args: {[string]: unknown}): {[string]: unknown}
        if args.action == "begin" then
            local descriptor = args.descriptor :: {[string]: unknown}
            local digest = tostring(descriptor.digest)
            if transfers[digest] then return result(transfers[digest], true) end
            local item: Transfer = {owner = tostring(descriptor.owner_id), feed = tostring(descriptor.feed), key = tostring(descriptor.key),
                total = math.floor(tonumber(descriptor.total_bytes) or 0), digest = tostring(descriptor.content_digest),
                parts = {}, received = 0, available = false}
            transfers[digest] = item
            return result(item, false)
        end
        local found = transfers[tostring(args.descriptor_digest)]
        if not found then return {ok = false, replayed = false, code = "NOT_FOUND", message = "no transfer"} end
        local item: Transfer = found
        if args.action == "status" then return result(item, false) end
        if args.action == "put" then
            if args.offset ~= item.received then return {ok = false, replayed = false, code = "CONFLICT", message = "offset is not contiguous"} end
            local bytes = assert(base64.decode(tostring(args.content_base64)))
            item.parts[#item.parts + 1] = bytes
            item.received = item.received + #bytes
            return result(item, false)
        end
        if hash.sha256(table.concat(item.parts)) ~= item.digest then
            return {ok = false, replayed = false, code = "CONFLICT", message = "content does not match"}
        end
        item.available = true
        events.send("bee.tests.sync", "received", item.key, {peer = name, feed = item.feed, digest = item.digest})
        return result(item, false)
    end

    while true do
        local selected = channel.select({requests:case_receive()})
        if not selected.ok then return end
        local request = protocol.forwarded(tostring(selected.value:from()), selected.value:payload():data())
        if request then process.send(request.caller, request.reply_topic, protocol.ok(handle(request.args))) end
    end
end

return {main = main}
