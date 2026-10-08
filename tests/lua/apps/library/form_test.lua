-- MIT. Schema configuration fields and typed edits.
local test = require("test")
local form = require("form")
local function define_tests()
    test.describe("Library Configure", function()
        test.it("shows declared fields, resolved defaults, required names and descriptions", function()
            local fields = form.fields({{id = "app:options", has_default = true, default = {count = 3},
                schema = {type = "object", required = {"name"}, properties = {
                    count = {type = "integer", default = 3, minimum = 1, description = "Task limit"},
                    name = {type = "string"}, mode = {type = "string", enum = {"team", "personal"}, default = "team"}}}}}, {})
            test.eq(#fields, 4)
            test.eq(fields[2].id, "app:options.count")
            test.eq(fields[2].default, 3)
            test.eq(fields[2].description, "Task limit")
            test.eq(fields[3].value, "team")
            test.is_true(fields[4].required)
        end)
        test.it("parses numbers and booleans, rejects invalid ranges and enums", function()
            local fields = form.fields({{id = "app:count", has_default = false,
                schema = {type = "integer", minimum = 1, maximum = 10}}}, {})
            local value, problem = form.parse(fields[1], "4")
            test.eq(value, 4)
            test.is_nil(problem)
            test.not_nil(select(2, form.parse(fields[1], "eleven")))
            test.not_nil(select(2, form.parse(fields[1], "0")))
            test.not_nil(form.validate({id = "app:count", has_default = false}, nil))
            local toggles = form.fields({{id = "app:enabled", has_default = true, default = false,
                schema = {type = "boolean"}}}, {})
            test.eq(toggles[1].value, false)
            test.eq(form.parse(toggles[1], "true"), true)
            local enums = form.fields({{id = "app:mode", has_default = true, default = "team",
                schema = {type = "string", enum = {"team", "personal"}}}}, {})
            test.not_nil(select(2, form.parse(enums[1], "other")))
        end)
        test.it("keeps object edits typed and names missing nested fields", function()
            local schema = {type = "object", required = {"count"}, properties = {count = {type = "integer"}}}
            local declaration = {id = "app:options", has_default = false, schema = schema}
            local fields = form.fields({declaration}, {})
            local edited = form.assign(nil, fields[2].path, 4)
            test.is_nil(form.validate(declaration, edited))
            test.is_true(assert(form.validate(declaration, {})):find("count", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
