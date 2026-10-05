-- MIT. Destination-owned public replica receiver. Hive authenticates and maps
-- the caller; this operation applies the mapped actor's exact source policy.
local security = require("security")
local protocol = require("protocol")
local replicas = require("replicas")
local resources = require("resources")
local transaction = require("transaction")

local function handle(raw: unknown): transaction.Result
    local request, decode_error = protocol.decode(raw)
    if not request then return transaction.failure("INVALID", decode_error or "invalid replica request") end
    local actor = security.actor()
    if not actor or not security.can("bee.sync.replica.receive", request.source_owner) then
        return transaction.failure("DENIED", "caller may not deliver replicas from this source")
    end
    local resource, resource_error = resources.database()
    if not resource then return transaction.failure("UNAVAILABLE", resource_error or "replica store unavailable") end
    local store, open_error = replicas.open(resource)
    if not store then return transaction.failure("UNAVAILABLE", open_error or "replica store unavailable") end
    local result: transaction.Result
    if request.action == "begin" then
        result = replicas.begin(store, request.descriptor, request.source_cursor)
    else
        local key = {source_owner = request.source_owner, feed = request.feed or "",
            version_key = request.version_key or "", descriptor_digest = request.descriptor_digest or ""}
        if request.action == "put" then
            result = replicas.put(store, key, request.offset, request.content_base64)
        elseif request.action == "finish" then
            result = replicas.finish(store, key)
        else
            result = replicas.status(store, key)
        end
    end
    replicas.close(store)
    return result
end

return {handle = handle}
