-- MIT. The docs tool facade a bound MCP subject calls as itself. It decodes one
-- strict request, opens the one read-only corpus volume and answers list, search
-- or read; it holds no writer, no registry publication and no host path. The
-- host names the read-only policy this runs under, so registration grants nothing.
local protocol = require("protocol")
local corpus = require("corpus")
local web = require("web")
local resources = require("resources")
local transaction = require("transaction")
local bounds = require("bounds")
type Result = transaction.Result
local function descriptor(document: corpus.Document): {[string]: unknown}
    return {id = document.id, topic = document.topic, title = document.title,
        source = document.source, bytes = document.bytes}
end
-- The corpus is measured once per call; it is a fixed snapshot, so a call
-- never observes a half-written document set.
local function handle(raw: unknown): Result
    local web_request, web_invalid = protocol.web(raw)
    if web_invalid then return transaction.failure("INVALID_ARGUMENT", web_invalid) end
    local request: protocol.Request? = nil
    if not web_request then
        local decoded, invalid = protocol.decode(raw)
        if not decoded then return transaction.failure("INVALID_ARGUMENT", invalid or "invalid docs request") end
        request = decoded
    end
    local resource, resource_error = resources.corpus()
    if not resource then return transaction.failure("UNAVAILABLE", tostring(resource_error)) end
    local volume, volume_error = corpus.open(resource)
    if not volume then return transaction.failure("UNAVAILABLE", tostring(volume_error)) end
    local manifest, manifest_error = corpus.manifest(volume)
    if not manifest then return transaction.failure("INTERNAL", tostring(manifest_error)) end
    if web_request then
        local window, code, fetch_error = web.fetch(manifest.base, web_request)
        if not window then return transaction.failure(tostring(code), tostring(fetch_error)) end
        local answer: {[string]: unknown} = window
        answer.operation = web_request.operation
        return transaction.success(answer, false)
    end
    if not request then return transaction.failure("INVALID_ARGUMENT", "invalid docs request") end
    if request.operation == "list" then
        local limit = request.limit or protocol.MAX_LIST
        local offset = request.offset or 0
        if request.topic ~= nil then
            local known = false
            for _, topic in ipairs(corpus.topics(manifest)) do if topic.topic == request.topic then known = true end end
            if not known then return transaction.failure("INVALID_ARGUMENT", "unknown topic") end
        end
        local documents, next_offset, more = corpus.list(manifest, request.topic, offset, limit)
        local listed: {{[string]: unknown}} = {}
        for _, document in ipairs(documents) do listed[#listed + 1] = descriptor(document) end
        return transaction.success({operation = "list", selection_rule = manifest.selection_rule,
            totals = manifest.totals, topics = corpus.topics(manifest), documents = listed,
            offset = offset, next_offset = more and next_offset or nil, more = more}, false)
    end
    if request.operation == "search" then
        local limit = request.limit or protocol.MAX_RESULTS
        local offset = request.offset or 0
        local excerpts, next_offset, more, search_error = corpus.search(volume, manifest, request.query,
            request.topic, offset, limit)
        if search_error then return transaction.failure("INTERNAL", search_error) end
        return transaction.success({operation = "search", query = request.query, topic = request.topic,
            results = excerpts, offset = offset, next_offset = more and next_offset or nil, more = more}, false)
    end
    local limit = request.limit or protocol.MAX_READ_BYTES
    local window, read_error = corpus.read(volume, manifest, request.id, request.section,
        request.offset or 0, limit)
    if not window then
        local known = corpus.find(manifest, request.id) ~= nil
        return transaction.failure(known and "INVALID_ARGUMENT" or "NOT_FOUND", tostring(read_error))
    end
    window.operation = "read"
    window.id = request.id
    return transaction.success(window, false)
end
return {handle = handle}
