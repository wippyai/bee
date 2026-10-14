-- SPDX-License-Identifier: MIT
local corpus = require("corpus")
local resources = require("resources")
local M = {}
type Document = {id: string, title: string, topic: string, content: string}
function M.load(): ({Document}?, string?)
    local resource, resource_error = resources.corpus()
    if not resource then return nil, tostring(resource_error) end
    local volume, volume_error = corpus.open(resource)
    if not volume then return nil, volume_error end
    local manifest, manifest_error = corpus.manifest(volume)
    if not manifest then return nil, manifest_error end
    local listed = corpus.list(manifest, nil, 0, corpus.MAX_DOCUMENTS)
    local documents: {Document} = {}
    for _, document in ipairs(listed) do
        local page, read_error = corpus.read(volume, manifest, document.id, nil, 0, document.bytes)
        if not page then return nil, read_error end
        documents[#documents + 1] = {id = document.id, title = document.title, topic = document.topic, content = page.content}
    end
    return documents, nil
end
function M.search(documents: {Document}, query: string): {Document}
    local found: {Document} = {}
    local lowered = query:lower()
    for _, document in ipairs(documents) do
        if document.title:lower():find(lowered, 1, true) or document.content:lower():find(lowered, 1, true) then
            found[#found + 1] = document
        end
    end
    return found
end
function M.connect(): (string?, string?)
    local resource, resource_error = resources.corpus()
    if not resource then return nil, tostring(resource_error) end
    local volume, volume_error = corpus.open(resource)
    if not volume then return nil, volume_error end
    local manifest, manifest_error = corpus.manifest(volume)
    if not manifest then return nil, manifest_error end
    local page, read_error = corpus.read(volume, manifest, "docs/external_mcp", "how-to-connect", 0, corpus.MAX_CORPUS_BYTES)
    return page and page.content, read_error
end
return M
