-- MIT. The offline documentation corpus a bound agent reads through the docs
-- tool. The corpus is one host-selected read-only embedded filesystem holding
-- Markdown documents and a manifest that names each document's stable id,
-- topic, source and digest.
-- This library only reads that volume: it writes nothing, executes nothing and
-- reaches no host path, network or registry beyond the one volume it was given.
local fs = require("fs")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local protocol = require("protocol")
local M = {}
M.MANIFEST = "manifest.json"
M.SCHEMA = "bee.docs-corpus@1"
M.MAX_DOCUMENTS = 256
M.MAX_CORPUS_BYTES = 4194304
type Document = {id: string, topic: string, title: string, source: string, bytes: integer, sha256: string}
type Manifest = {schema: string, selection_rule: string, base: string, totals: {documents: integer, bytes: integer}, documents: {Document}}
type Excerpt = {id: string, title: string, topic: string, section: string, line: integer, text: string}
type ReadFile = (string) -> (string?, string?)
local function source(value: unknown): string?
    local checked = bounds.line(value, 512)
    if not checked then return nil end
    if checked:match("^https://[^/]+/.+$") then return checked end
    if checked:match("^generated: [%w_ ,:./%-]+$") then return checked end
    if (checked:match("^docs/[%w_./%-]+$") or checked:match("^modules/[%w_./%-]+$"))
        and not checked:find("../", 1, true) then return checked end
    return nil
end
-- Opens the corpus volume. The volume does not require release; the system
-- detaches it with the filesystem. A missing volume is a build fault, not a
-- caller fault, and is reported as such.
function M.open(resource: string): (fs.FS?, string?)
    local volume, volume_error = fs.get(resource)
    if not volume then return nil, "documentation corpus is unavailable: " .. tostring(volume_error) end
    return volume, nil
end
function M.manifest(volume: fs.FS): (Manifest?, string?)
    local read, read_error = volume:readfile("/" .. M.MANIFEST)
    if not read then return nil, "corpus manifest is unavailable: " .. tostring(read_error) end
    local payload = read
    local decoded: unknown = json.decode(payload)
    return M.decode_manifest(decoded, function(path: string): (string?, string?)
        return volume:readfile(path)
    end)
end
function M.decode_manifest(decoded: unknown, readfile: ReadFile): (Manifest?, string?)
    local value = bounds.object(decoded)
    if not value or bounds.fields(value, {"schema", "selection_rule", "base", "ceiling_bytes", "totals", "documents"}) then
        return nil, "corpus manifest has an invalid shape"
    end
    if value.schema ~= M.SCHEMA then return nil, "corpus manifest has an unknown schema" end
    local selection_rule = bounds.line(value.selection_rule, 2048)
    local base = bounds.line(value.base, 256)
    local ceiling = bounds.count(value.ceiling_bytes)
    local totals = bounds.object(value.totals)
    if not selection_rule then return nil, "corpus manifest metadata is malformed" end
    if not base or not base:match("^https://[^/]+/.+$") then return nil, "corpus manifest metadata is malformed" end
    if not ceiling or ceiling < 1 or ceiling > M.MAX_CORPUS_BYTES then return nil, "corpus manifest metadata is malformed" end
    if not totals or bounds.fields(totals, {"documents", "bytes"}) then return nil, "corpus manifest metadata is malformed" end
    local declared_documents = bounds.count(totals.documents)
    local declared_bytes = bounds.count(totals.bytes)
    local raw = bounds.array(value.documents, M.MAX_DOCUMENTS)
    if not declared_documents or not declared_bytes then return nil, "corpus manifest totals are malformed" end
    if not raw or #raw == 0 then return nil, "corpus manifest lists no bounded documents" end
    local documents: {Document} = {}
    local seen: {[string]: boolean} = {}
    local total_bytes = 0
    for _, item in ipairs(raw) do
        local entry = bounds.object(item)
        if not entry or bounds.fields(entry, {"id", "topic", "title", "source", "bytes", "sha256"}) then
            return nil, "corpus manifest has an invalid document"
        end
        local id = protocol.document_id(entry.id)
        local topic = bounds.line(entry.topic, 64)
        local title = bounds.line(entry.title, 240)
        local document_source = source(entry.source)
        local size = bounds.count(entry.bytes)
        local sha256 = bounds.line(entry.sha256, 64)
        if not id or seen[id] or not topic or not topic:match("^[a-z0-9_-]+$") or not title or not document_source
            or not sha256 or not sha256:match("^[0-9a-f]+$") or #sha256 ~= 64 then
            return nil, "corpus manifest has an invalid document identity or metadata"
        end
        if not size then return nil, "corpus manifest has an invalid document byte count" end
        local byte_count: integer = size
        local payload, document_error = readfile(M.path(id))
        if not payload then return nil, "corpus document is unavailable: " .. tostring(document_error) end
        if #payload ~= byte_count then return nil, "corpus document byte count does not match its manifest" end
        local measured, hash_error = hash.sha256(payload)
        if not measured then return nil, "corpus document digest could not be measured: " .. tostring(hash_error) end
        if measured ~= sha256 then return nil, "corpus document digest does not match its manifest" end
        seen[id] = true
        total_bytes = total_bytes + byte_count
        if total_bytes > ceiling then return nil, "corpus manifest exceeds its declared byte ceiling" end
        documents[#documents + 1] = {id = id, topic = topic, title = title, source = document_source,
            bytes = byte_count, sha256 = sha256}
    end
    if declared_documents ~= #documents or declared_bytes ~= total_bytes then
        return nil, "corpus manifest totals do not match its documents"
    end
    return {schema = M.SCHEMA, selection_rule = selection_rule, base = base,
        totals = {documents = declared_documents, bytes = declared_bytes}, documents = documents}, nil
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
function M.search(volume: fs.FS, manifest: Manifest, query: string, topic: string?,
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
            local payload = read
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
function M.read(volume: fs.FS, manifest: Manifest, id: string, section: string?,
                offset: integer, limit: integer): ({content: string, offset: integer, next_offset: integer?, eof: boolean, section: string?, title: string?, topic: string?, source: string?, size: integer}?, string?)
    local document = M.find(manifest, id)
    if not document then return nil, "unknown document id" end
    local read, read_error = volume:readfile(M.path(id))
    if not read then return nil, "document is unavailable: " .. tostring(read_error) end
    local payload = read
    local start = offset
    local heading: string? = nil
    if section ~= nil then
        local index = 0
        local found = false
        for line in (payload .. "\n"):gmatch("([^\n]*)\n") do
            local candidate = heading_of(line)
            if candidate and M.anchor(candidate) == section then start = index + offset; found = true; heading = candidate; break end
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
