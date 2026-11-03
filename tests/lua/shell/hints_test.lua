-- MIT
local test = require("test")
local hints = require("hints")

local function texts(tokens: {hints.Token}): {[string]: string}
    local found: {[string]: string} = {}
    for _, token in ipairs(tokens) do found[token.text] = token.kind end
    return found
end

local function define_tests()
    test.describe("Quick copy hints", function()
        test.it("labels single letters home row first, then prefix-free pairs", function()
            local few = hints.labels(3)
            test.eq(table.concat(few, ","), "a,s,d")
            local many = hints.labels(40)
            test.eq(#many, 40)
            local seen: {[string]: boolean} = {}
            for _, label in ipairs(many) do
                test.is_false(seen[label] == true)
                seen[label] = true
                for _, other in ipairs(many) do
                    if other ~= label then test.is_false(other:sub(1, #label) == label) end
                end
            end
            test.eq(many[1], "a")
            test.eq(#hints.labels(676), 676)
        end)

        test.it("finds paths, URLs, SHAs, UUIDs, ids, quoted strings and error lines", function()
            local tokens = hints.tokens({
                "edit /srv/me1/src/a.lua:12 and src/shell/copy.lua now",
                "see https://wippy.ai/llm/toc. Then commit 6d36a9f1c",
                "id 01a06e56-ba58-7c5a-bd69-b7feb109a05d entry bee.shell:copy run_7f3k9q2z",
                "say \"hello world\" or `make lint` or 'single one'",
                "  Error: the node cannot start",
                "and/or plain words deadbeef",
            })
            local found = texts(tokens)
            test.eq(found["/srv/me1/src/a.lua:12"], "path")
            test.eq(found["src/shell/copy.lua"], "path")
            test.eq(found["https://wippy.ai/llm/toc"], "url")
            test.eq(found["6d36a9f1c"], "sha")
            test.eq(found["01a06e56-ba58-7c5a-bd69-b7feb109a05d"], "uuid")
            test.eq(found["bee.shell:copy"], "registry")
            test.eq(found["run_7f3k9q2z"], "id")
            test.eq(found["hello world"], "quoted")
            test.eq(found["make lint"], "quoted")
            test.eq(found["single one"], "quoted")
            test.eq(found["Error: the node cannot start"], "error")
            test.is_nil(found["and/or"])
            test.is_nil(found["deadbeef"])
        end)

        test.it("places each token at its cells and labels the latest rows first", function()
            local tokens = hints.tokens({"界 /a/b.txt", "x https://a.io/p"})
            test.eq(#tokens, 2)
            test.eq(tokens[1].text, "https://a.io/p")
            test.eq(tokens[1].label, "a")
            test.eq(tokens[1].y, 2); test.eq(tokens[1].first, 3); test.eq(tokens[1].last, 16)
            test.eq(tokens[2].text, "/a/b.txt")
            test.eq(tokens[2].label, "s")
            test.eq(tokens[2].first, 4); test.eq(tokens[2].last, 11)
        end)

        test.it("copies a fenced code block whole and gives repeated text one hint", function()
            local tokens = hints.tokens({"  ```lua", "  local x = 1", "    return x", "  ```", "/a/b.txt /a/b.txt"})
            local code: hints.Token? = nil
            for _, token in ipairs(tokens) do if token.kind == "code" then code = token end end
            test.not_nil(code)
            if code then
                test.eq(code.text, "local x = 1\n  return x")
                test.eq(code.y, 1); test.eq(code.finish, 4); test.eq(code.first, 3)
            end
            test.eq(tokens[1].text, "/a/b.txt"); test.eq(tokens[2].text, "/a/b.txt")
            test.eq(tokens[1].label, tokens[2].label)
        end)

        test.it("chooses the token a typed hint spells and tells a prefix from a miss", function()
            local tokens = hints.tokens({"/a/1.txt /a/2.txt"})
            local chosen, partial = hints.choose(tokens, "s")
            test.not_nil(chosen)
            if chosen then test.eq(chosen.text, "/a/2.txt") end
            test.is_true(partial)
            chosen, partial = hints.choose(tokens, "z")
            test.is_nil(chosen); test.is_false(partial)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
