-- MIT. Clipboard requests belong to one live presenter, never a scene snapshot.
local test = require("test")
local clipboard = require("clipboard")

local function define_tests()
    test.describe("Client clipboard admission", function()
        test.it("admits only the active exact presenter and bounded explicit text", function()
            local request = {version = 1, op = "clipboard", request_id = "copy-one", text = "hello\nworld"}
            local admitted = clipboard.request(request, "presenter-one", "presenter-one", true)
            test.not_nil(admitted)
            if admitted then test.eq(admitted.text, "hello\nworld") end
            test.is_nil(clipboard.request(request, "old-presenter", "presenter-one", true))
            test.is_nil(clipboard.request(request, "presenter-one", "presenter-one", false))
            test.is_nil(clipboard.request(request, "", "", true))
        end)
        test.it("rejects unknown fields, control sequences and oversized requests", function()
            test.is_nil(clipboard.request({version = 1, op = "clipboard", request_id = "x", text = "x", target = "other"}, "p", "p", true))
            test.is_nil(clipboard.request({version = 1, op = "clipboard", request_id = "", text = "x"}, "p", "p", true))
            test.is_nil(clipboard.request({version = 1, op = "clipboard", request_id = "x", text = "\27]52;c;attack\7"}, "p", "p", true))
            test.is_nil(clipboard.request({version = 1, op = "clipboard", request_id = "x", text = string.rep("x", 8193)}, "p", "p", true))
            test.not_nil(clipboard.request({version = 1, op = "clipboard", request_id = "x", text = string.rep("x", 8192)}, "p", "p", true))
            test.not_nil(clipboard.request({version = 1, op = "clipboard", request_id = "x", text = "界é\t\n"}, "p", "p", true))
        end)
        test.it("bounds encoded copy replies without truncating selected text", function()
            local plain = clipboard.copy_result({version = 1, request_id = "read", selected = true, text = string.rep("x", 8192), error = ""})
            test.not_nil(plain)
            if plain then test.eq(#plain.text, 8192); test.eq(plain.error, "") end
            local expanded = clipboard.copy_result({version = 1, request_id = "read", selected = true, text = string.rep("<", 8192), error = ""})
            test.not_nil(expanded)
            if expanded then test.eq(expanded.text, ""); test.eq(expanded.selected, true); test.is_true(expanded.error ~= "") end
            test.is_nil(clipboard.copy_result({version = 1, request_id = "read", selected = false, text = "private", error = ""}))
            test.is_nil(clipboard.copy_result({version = 1, request_id = "read", selected = true, text = "\27]52;x", error = ""}))
            test.is_nil(clipboard.copy_id({version = 1, request_id = "read", recipient = "other"}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
