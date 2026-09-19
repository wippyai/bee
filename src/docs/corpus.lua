-- MIT. The offline documentation corpus a bound agent reads through the docs
-- tool. The corpus is one read-only embedded filesystem (bee:docs_corpus,
-- frozen into the pack by wippy.yaml embed) holding Markdown documents and a
-- manifest that names, per document, its stable id, topic, source and digest.
-- This library only reads that volume: it writes nothing, executes nothing and
-- reaches no host path, network or registry beyond the one volume it was given.
local fs = require("fs")
local json = require("json")
local bounds = require("bounds")
local M = {}
M.VOLUME = "bee:docs_corpus"
M.MANIFEST = "manifest.json"
M.SCHEMA = "bee.docs-corpus@1"
-- Bounds, in one place, matching the request decoder and the tool description.
M.MAX_LIST = 64
M.MAX_RESULTS = 16
M.MAX_READ_BYTES = 16384
type Document = {id: string, topic: string, title: string, source: string, bytes: integer, sha256: string}
type Manifest = {schema: string, selection_rule: string, totals: {documents: integer, bytes: integer}, documents: {Document}}
type Excerpt = {id: string, title: string, topic: string, section: string, line: integer, text: string}
-- Opens the corpus volume. The volume does not require release; the system
-- detaches it with the filesystem. A missing volume is a build fault, not a
-- caller fault, and is reported as such.
function M.open(): (any?, string?)
    local volume, volume_error = fs.get(M.VOLUME)
    if not volume then return nil, "documentation corpus is unavailable: " .. tostring(volume_error) end
    return volume, nil
end
function M.manifest(volume: any): (Manifest?, string?)
    local read, read_error = volume:readfile("/" .. M.MANIFEST)
    if not read then return nil, "corpus manifest is unavailable: " .. tostring(read_error) end
    local payload = read :: string
    local decoded: unknown = json.decode(payload)
    local value = bounds.object(decoded)
    if not value or type(value.schema) ~= "string" or value.schema ~= M.SCHEMA then return nil, "corpus manifest has an unknown schema" end
    local raw = value.documents
    if type(raw) ~= "table" then return nil, "corpus manifest lists no documents" end
    local documents: {Document} = {}
    for _, item in ipairs(raw) do
        local entry = bounds.object(item)
        if not entry then return nil, "corpus manifest has an invalid document" end
        local id, topic, title = entry.id, entry.topic, entry.title
        local source, sha256 = entry.source, entry.sha256
        local size = entry.bytes
        if type(id) ~= "string" or type(topic) ~= "string" or type(title) ~= "string"
            or type(source) ~= "string" or type(size) ~= "number" or type(sha256) ~= "string" then
            return nil, "corpus manifest has an incomplete document"
        end
        documents[#documents + 1] = {id = id, topic = topic, title = title, source = source,
            bytes = math.floor(size), sha256 = sha256}
    end
    if #documents == 0 then return nil, "corpus manifest lists no documents" end
    local totals = bounds.object(value.totals) or {}
    local rule = type(value.selection_rule) == "string" and value.selection_rule or ""
    return {schema = value.schema :: string, selection_rule = rule,
        totals = {documents = #documents, bytes = math.floor(tonumber(totals.bytes) or 0)}, documents = documents}, nil
end
-- The path of one document inside the volume: its id is the document path.
function M.path(id: string): string
    return "/" .. id .. ".md"
end
function M.find(manifest: Manifest, id: string): Document?
    for _, document in ipairs(manifest.documents) do if document.id == id then return document end end
    return nil
end
-- The canonical anchor of one Markdown heading: lowercase, non-alphanumerics
-- collapsed to single hyphens. Stable, so a section id survives an edit that
-- does not rename the heading.
function M.anchor(heading: string): string
    local lowered = string.lower(heading)
    local collapsed = lowered:gsub("[^a-z0-9]+", "-")
    return (collapsed:gsub("^%-+", ""):gsub("%-+$", ""))
end
-- Topics the corpus covers, with a document count each, ordered by name.
function M.topics(manifest: Manifest): {{topic: string, documents: integer}}
    local counts: {[string]: integer} = {}
    local names: {string} = {}
    for _, document in ipairs(manifest.documents) do
        if counts[document.topic] == nil then names[#names + 1] = document.topic end
        counts[document.topic] = (counts[document.topic] or 0) + 1
    end
    table.sort(names)
    local topics: {{topic: string, documents: integer}} = {}
    for _, name in ipairs(names) do topics[#topics + 1] = {topic = name, documents = counts[name]} end
    return topics
end
-- One bounded page of document descriptors, optionally filtered to a topic.
-- Documents within a topic are ordered by title so paging is deterministic.
function M.list(manifest: Manifest, topic: string?, offset: integer, limit: integer): {Document}, integer, boolean
    local documents: {Document} = {}
    for _, document in ipairs(manifest.documents) do
        if topic == nil or document.topic == topic then documents[#documents + 1] = document end
    end
    table.sort(documents, function(a, b)
        if a.topic ~= b.topic then return a.topic < b.topic end
        if a.title ~= b.title then return a.title < b.title end
        return a.id < b.id
    end)
    local page: {Document} = {}
    for index = offset + 1, math.min(offset + limit, #documents) do page[#page + 1] = documents[index] end
    local next_offset = offset + #page
    return page, next_offset, next_offset < #documents
end
-- The heading a line sits under, and the last heading of any level seen.
local function heading_of(line: string): (string?, string?)
    local level, text = line:match("^(#+)%s+(.*)$")
    if level and text and #level <= 6 then return text, text end
    return nil, nil
end
-- One line of context around a match: the whole line, control characters
-- removed, bounded so a search page cannot carry a whole document.
local function excerpt(text: string, id: string, title: string, topic: string, section: string, line: integer): Excerpt
    local clean = text:gsub("%c", " ")
    if #clean > 240 then clean = clean:sub(1, 240) .. "…" end
    return {id = id, title = title, topic = topic, section = section, line = line, text = clean}
end
-- Case-insensitive literal search over the corpus, one bounded page of
-- excerpts with the section each match sits under. The query is literal so a
-- caller cannot smuggle a pattern; the topic filter is optional.
function M.search(volume: any, manifest: Manifest, query: string, topic: string?,
                  offset: integer, limit: integer): ({Excerpt}, integer, boolean, string?)
    local lowered = string.lower(query)
    local excerpts: {Excerpt} = {}
    local seen = 0
    local next_offset = offset
    local more = false
    for _, document in ipairs(manifest.documents) do
        if topic == nil or document.topic == topic then
            local read, read_error = volume:readfile(M.path(document.id))
            if not read then return {}, offset, false, "document is unavailable: " .. tostring(read_error) end
            local payload = read :: string
            local section = ""
            local line_number = 0
            for line in (payload .. "\n"):gmatch("([^\n]*)\n") do
                line_number = line_number + 1
                local heading = heading_of(line)
                if heading then section = heading end
                if string.find(string.lower(line), lowered, 1, true) then
                    seen = seen + 1
                    if seen > offset then
                        if #excerpts >= limit then more = true; break end
                        excerpts[#excerpts + 1] = excerpt(line, document.id, document.title, document.topic, section, line_number)
                        next_offset = seen
                    end
                end
            end
            if more then break end
        end
    end
    return excerpts, next_offset, more, nil
end
-- Reads one bounded window of one document, optionally from a section's first
-- heading. The reply names the exact byte window so a caller can continue.
function M.read(volume: any, manifest: Manifest, id: string, section: string?,
                offset: integer, limit: integer): ({content: string, offset: integer, next_offset: integer?, eof: boolean, section: string?, title: string?, topic: string?, source: string?, size: integer}?, string?)
    local document = M.find(manifest, id)
    if not document then return nil, "unknown document id" end
    local read, read_error = volume:readfile(M.path(id))
    if not read then return nil, "document is unavailable: " .. tostring(read_error) end
    local payload = read :: string
    local start = offset
    local heading: string? = nil
    if section ~= nil then
        local index = 0
        local found = false
        for line in (payload .. "\n"):gmatch("([^\n]*)\n") do
            local candidate = heading_of(line)
            if candidate and M.anchor(candidate) == section then start = index; found = true; heading = candidate; break end
            index = index + #line + 1
        end
        if not found then return nil, "unknown section anchor" end
    end
    if start > #payload then start = #payload end
    local window = payload:sub(start + 1, start + limit)
    local next_offset = start + #window
    return {content = window, offset = start, next_offset = next_offset < #payload and next_offset or nil,
        eof = next_offset >= #payload, section = heading, title = document.title, topic = document.topic,
        source = document.source, size = #payload}, nil
end
return M
