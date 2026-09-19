-- MIT. Prove the documentation corpus travels inside the pack and is read-only:
-- the embedded volume serves the manifest and a document, and a write is refused.
local fs = require("fs")
local io = require("io")
local json = require("json")
local function main()
    local volume, volume_error = fs.get("bee:docs_corpus")
    assert(volume, "corpus volume is unavailable: " .. tostring(volume_error))
    local manifest, read_error = volume:readfile("/manifest.json")
    assert(manifest, "corpus manifest is unreadable: " .. tostring(read_error))
    local decoded = json.decode(manifest :: string)
    assert(type(decoded) == "table", "corpus manifest is not JSON")
    local totals = (decoded :: {[string]: unknown}).totals :: {[string]: unknown}
    assert(type(totals.documents) == "number" and totals.documents > 100, "corpus manifest is empty")
    local document, document_error = volume:readfile("/toolkit.md")
    assert(document, "toolkit reference is unreadable: " .. tostring(document_error))
    assert(string.find(document :: string, "one-based", 1, true), "toolkit reference lost its text")
    local wrote, write_error = volume:writefile("/manifest.json", "changed")
    assert(not wrote and write_error ~= nil, "embedded corpus was writable")
    local retained = volume:readfile("/manifest.json")
    assert(retained == manifest, "a refused write changed the corpus")
    io.print("corpus volume: " .. tostring(totals.documents) .. " documents, read-only embedded filesystem")
end
return {main = main}
