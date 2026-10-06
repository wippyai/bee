-- MIT. The live documentation reader: its addresses come from the corpus
-- manifest's base, every answer is one bounded window, and the policy it runs
-- under reaches only the documentation site.
local test = require("test")
local web = require("web")
local security = require("security")

local BASE = "https://wippy.ai/llm"

local function define_tests()
    test.describe("Live documentation", function()
        test.it("addresses search, pages, the table of contents and the curated index from the manifest base", function()
            test.eq(web.url(BASE, {operation = "web_search", query = "process spawn & monitor", offset = 0, limit = 1}),
                "https://wippy.ai/llm/search?q=process+spawn+%26+monitor")
            test.eq(web.url(BASE, {operation = "web_read", path = "lua/core/process", offset = 0, limit = 1}),
                "https://wippy.ai/llm/path/en/lua/core/process")
            test.eq(web.url(BASE, {operation = "web_toc", offset = 0, limit = 1}), "https://wippy.ai/llm/toc")
            test.eq(web.url(BASE, {operation = "web_index", offset = 0, limit = 1}), "https://wippy.ai/llms.txt")
        end)
        test.it("answers one bounded window and the offset that continues it", function()
            local first = web.window("https://wippy.ai/llm/toc", "abcdefghij", 0, 4)
            test.eq(first.content, "abcd")
            test.eq(first.next_offset, 4)
            test.is_false(first.eof)
            test.eq(first.size, 10)
            local last = web.window("https://wippy.ai/llm/toc", "abcdefghij", 8, 4)
            test.eq(last.content, "ij")
            test.is_nil(last.next_offset)
            test.is_true(last.eof)
            test.eq(web.window("https://wippy.ai/llm/toc", "abc", 9, 4).content, "")
        end)
        test.it("reaches only the documentation site", function()
            local policy = assert(security.policy("bee.security.docs:docs_web_policy"))
            local actor = assert(security.new_actor("docs-web-test", {}))
            for _, allowed in ipairs({"https://wippy.ai/llm/toc", "https://wippy.ai/llm/search?q=x", "https://wippy.ai/llm/path/en/lua/core/process", "https://wippy.ai/llms.txt"}) do
                test.eq(policy:evaluate(actor, "http_client.request", allowed), "allow", allowed)
            end
            for _, refused in ipairs({"https://wippy.ai/admin", "https://wippy.ai.example.com/llm/toc", "http://wippy.ai/llm/toc", "https://example.com/llm/toc"}) do
                test.is_true(policy:evaluate(actor, "http_client.request", refused) ~= "allow", refused)
            end
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
