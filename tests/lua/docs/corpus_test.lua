-- MIT. The docs tool against the corpus that ships in the pack: the manifest is
-- complete and hashed, list names topics and ids, search returns the section a
-- match sits under, read returns one bounded window and every bound holds.
local test = require("test")
local corpus = require("corpus")
local protocol = require("protocol")
local method = require("method")
local function reply(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("docs tool returned no reply") end
    local result = value :: {[string]: unknown}
    if result.ok ~= true then
        local fault = type(result.error) == "table" and result.error :: {[string]: unknown} or {}
        error("docs " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return result.value :: {[string]: unknown}
end
local function call(request: unknown): {[string]: unknown}
    local decoded, decode_error = protocol.decode(request)
    if not decoded then error("decode: " .. tostring(decode_error)) end
    return reply(method.handle(request))
end
local function define_tests()
    test.describe("Docs corpus and tool", function()
        test.it("ships a complete, hashed manifest of the selected documentation", function()
            local volume, volume_error = corpus.open()
            if not volume then error(tostring(volume_error)) end
            local manifest, manifest_error = corpus.manifest(volume)
            if not manifest then error(tostring(manifest_error)) end
            test.eq(manifest.schema, corpus.SCHEMA)
            test.not_nil(string.find(manifest.selection_rule, "runtime", 1, true))
            test.not_nil(string.find(manifest.selection_rule, "component", 1, true))
            test.is_true(#manifest.documents >= 100)
            -- Every declared document exists with the declared bytes, so the
            -- corpus cannot silently rot behind its manifest.
            for _, document in ipairs(manifest.documents) do
                local payload, read_error = volume:readfile(corpus.path(document.id))
                if not payload then error("missing corpus document " .. document.id .. ": " .. tostring(read_error)) end
                test.eq(#(payload :: string), document.bytes)
            end
            -- The three questions an agent must be able to answer are present:
            -- the terminal toolkit, cross-node subscriptions and a runtime module.
            test.not_nil(corpus.find(manifest, "toolkit"))
            test.not_nil(corpus.find(manifest, "docs/placement_and_subscriptions"))
            test.not_nil(corpus.find(manifest, "runtime/lua/core/process"))
            test.not_nil(corpus.find(manifest, "runtime/lua/storage/sql"))
            test.not_nil(corpus.find(manifest, "runtime/lua/system/tty"))
        end)
        test.it("names the corpus by topic with stable document ids", function()
            local listed = call({operation = "list"})
            test.eq(listed.operation, "list")
            test.eq(type(listed.selection_rule), "string")
            local topics = listed.topics :: {{[string]: unknown}}
            test.is_true(#topics > 0)
            local names: {[string]: boolean} = {}
            for _, topic in ipairs(topics) do names[tostring(topic.topic)] = true end
            for _, required in ipairs({"cluster", "terminal", "storage", "threads", "registry"}) do
                test.is_true(names[required] == true)
            end
            local page = listed.documents :: {{[string]: unknown}}
            test.is_true(#page > 0 and #page <= protocol.MAX_LIST)
            for _, document in ipairs(page) do
                test.eq(type(document.id), "string")
                test.eq(type(document.title), "string")
                test.is_true(#document.title > 0)
            end
            -- The topic filter narrows exactly to one topic.
            local filtered = call({operation = "list", topic = "cluster", limit = 64})
            local cluster = filtered.documents :: {{[string]: unknown}}
            test.is_true(#cluster > 0)
            for _, document in ipairs(cluster) do test.eq(document.topic, "cluster") end
            local _, refused = protocol.decode({operation = "list", topic = "nope"})
            test.eq(refused, nil)
            local bad = method.handle({operation = "list", topic = "nope"})
            test.eq((bad :: {[string]: unknown}).ok, false)
            test.eq((((bad :: {[string]: unknown}).error :: {[string]: unknown}).code), "INVALID")
        end)
        test.it("searches the corpus and returns the section a match sits under", function()
            local found = call({operation = "search", query = "tty.canvas"})
            local results = found.results :: {{[string]: unknown}}
            test.is_true(#results > 0 and #results <= protocol.MAX_RESULTS)
            local ids: {[string]: boolean} = {}
            for _, result in ipairs(results) do
                test.eq(type(result.section), "string")
                test.eq(type(result.line), "number")
                test.not_nil(string.find(string.lower(result.text :: string), "tty.canvas", 1, true))
                ids[tostring(result.id)] = true
            end
            -- The terminal toolkit is reachable from a bare search, so an agent
            -- that only knows the phrase can find the reference.
            test.is_true(ids["toolkit"] == true or ids["runtime/lua/system/tty"] == true)
            local too_many = call({operation = "search", query = "the", topic = "cluster", limit = 4})
            local bounded = too_many.results :: {{[string]: unknown}}
            test.is_true(#bounded <= 4)
            test.eq(too_many.more, true)
        end)
        test.it("reads one bounded window and can continue from an offset", function()
            local volume = corpus.open()
            local manifest = corpus.manifest(volume)
            if not manifest then error("manifest") end
            local declared = corpus.find(manifest, "runtime/lua/core/process")
            if not declared then error("process module is absent from the corpus") end
            local read = call({operation = "read", id = "runtime/lua/core/process", limit = 1024})
            test.eq(read.operation, "read")
            test.eq(read.topic, "core")
            test.eq(read.size, declared.bytes)
            test.is_true(#(read.content :: string) <= 1024)
            test.eq(read.offset, 0)
            test.eq(read.eof, false)
            test.eq(read.next_offset, #(read.content :: string))
            local next_window = call({operation = "read", id = "runtime/lua/core/process", offset = read.next_offset, limit = 1024})
            test.eq(next_window.offset, read.next_offset)
            -- An id that is not in the corpus is refused, not widened.
            local missing = method.handle({operation = "read", id = "runtime/lua/core/nope"})
            test.eq((missing :: {[string]: unknown}).ok, false)
            test.eq((((missing :: {[string]: unknown}).error :: {[string]: unknown}).code), "NOT_FOUND")
        end)
        test.it("reads from a heading anchor and reports the section", function()
            local read = call({operation = "read", id = "toolkit", section = "lifecycle", limit = 400})
            test.eq(read.section, "Lifecycle")
            test.is_true(string.find(read.content :: string, "tty.surface", 1, true) ~= nil)
            local _, unknown = protocol.decode({operation = "read", id = "toolkit", section = "no-such-heading"})
            test.eq(unknown, nil)
            local refused = method.handle({operation = "read", id = "toolkit", section = "no-such-heading"})
            test.eq((refused :: {[string]: unknown}).ok, false)
            test.eq((((refused :: {[string]: unknown}).error :: {[string]: unknown}).code), "INVALID")
        end)
        test.it("keeps the anchors stable for the cross-node and terminal questions", function()
            local volume = corpus.open()
            local manifest = corpus.manifest(volume)
            if not manifest then error("manifest") end
            -- The two topics the owner names are reachable by their corpus names.
            local anchors: {[string]: boolean} = {}
            for _, document in ipairs(manifest.documents) do anchors[document.topic] = true end
            test.is_true(anchors["cluster"] and anchors["terminal"] and anchors["component"])
        end)
    end)
end
return test.run_cases(define_tests)
