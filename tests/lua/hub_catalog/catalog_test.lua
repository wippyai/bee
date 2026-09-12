-- MIT. Catalog conversions are pure and never contact a Hub registry in tests.
local test = require("test")
local catalog = require("catalog")

local function module(name: string): {[string]: unknown}
    return {
        full_name = name,
        display_name = "Terminal",
        description = "Native terminal",
        latest_version = "v1.2.3",
        id = "opaque-native-id",
    }
end

local function browse(items: {unknown}): {[string]: unknown}
    return {items = items, total = #items, page = 2, page_size = catalog.PAGE_SIZE}
end

local function versions(items: {unknown}): {[string]: unknown}
    return {items = items, total = #items, page = 1, page_size = catalog.MAX_VERSIONS}
end

local function define_tests()
    test.describe("Hub catalog", function()
        test.it("decodes only bounded browse query and page input", function()
            local default, default_error = catalog.decode({})
            test.is_nil(default_error)
            test.not_nil(default)
            if default then
                test.is_nil(default.query)
                test.eq(default.page, 1)
                test.eq(default.keyword, "bee")
            end
            local all_packages = catalog.decode({keyword = ""})
            test.not_nil(all_packages)
            if all_packages then test.eq(all_packages.keyword, "") end
            local filtered = catalog.decode({query = "terminal", keyword = "bee"})
            test.not_nil(filtered)
            if filtered then test.eq(filtered.query, "terminal"); test.eq(filtered.keyword, "bee") end
            local request, request_error = catalog.decode({query = "terminal", page = 2})
            test.is_nil(request_error)
            test.not_nil(request)
            if request then
                test.eq(request.query, "terminal")
                test.eq(request.page, 2)
            end
            for _, invalid in ipairs({false, {query = ""}, {query = "bad\nquery"},
                {query = string.rep("a", catalog.MAX_QUERY_BYTES + 1)}, {page = 0}, {page = 1.5},
                {page = catalog.MAX_PAGE + 1}}) do
                test.is_nil(catalog.decode(invalid))
            end
        end)

        test.it("refuses caller-selected authority and invalid component identifiers", function()
            for _, field in ipairs({"registry", "token", "url", "path", "actor", "scope"}) do
                local raw: {[string]: unknown} = {query = "terminal"}
                raw[field] = "caller-selected"
                test.is_nil(catalog.decode(raw))
                local detail: {[string]: unknown} = {component = "wippy/terminal"}
                detail[field] = "caller-selected"
                test.is_nil(catalog.decode_detail(detail))
            end
            for _, name in ipairs({"", "wippy", "/terminal", "wippy/", "wippy/term/inal", "https://hub/wippy", "./terminal", "wippy/.."}) do
                test.is_nil(catalog.decode_detail({component = name}))
            end
        end)

        test.it("converts a bounded native browse response to the public item shape", function()
            local result, problem = catalog.decode_browse(browse({module("wippy/terminal")}))
            test.is_nil(problem)
            test.not_nil(result)
            if not result then return end
            test.eq(result.total, 1)
            test.eq(result.page, 2)
            test.eq(result.page_size, catalog.PAGE_SIZE)
            test.eq(result.items[1].component, "wippy/terminal")
            test.eq(result.items[1].title, "Terminal")
            test.eq(result.items[1].description, "Native terminal")
            test.eq(result.items[1].latest_version, "v1.2.3")
        end)

        test.it("fails closed for malformed or unbounded native browse data", function()
            local missing_name = module("wippy/terminal")
            missing_name.full_name = "invalid"
            test.is_nil(catalog.decode_browse(browse({missing_name})))
            test.is_nil(catalog.decode_browse({items = {[2] = module("wippy/terminal")}, total = 1, page = 2,
                page_size = catalog.PAGE_SIZE}))
            test.is_nil(catalog.decode_browse({items = {}, total = -1, page = 2, page_size = catalog.PAGE_SIZE}))
            test.is_nil(catalog.decode_browse({items = {}, total = 0, page = 0, page_size = catalog.PAGE_SIZE}))
            test.is_nil(catalog.decode_browse({items = {}, total = 0, page = 2, page_size = 0}))
            local many: {unknown} = {}
            for index = 1, catalog.MAX_ITEMS + 1 do many[index] = false end
            test.is_nil(catalog.decode_browse(browse(many)))
        end)

        test.it("converts exact module, README, and version data for detail", function()
            local result, problem = catalog.decode_detail_result(module("wippy/terminal"),
                {content = "# Terminal", filename = "README.md", version = "v1.2.3"},
                versions({{version = "v1.2.3", yanked = false}, {version = "v1.2.2", yanked = true}}),
                "wippy/terminal")
            test.is_nil(problem)
            test.not_nil(result)
            if not result then return end
            test.eq(result.component, "wippy/terminal")
            test.eq(result.title, "Terminal")
            test.eq(result.description, "Native terminal")
            test.eq(result.readme, "# Terminal")
            test.eq(#result.versions, 2)
            test.eq(result.versions[1].version, "v1.2.3")
            test.is_false(result.versions[1].yanked)
            test.is_true(result.versions[2].yanked)
        end)

        test.it("rejects mismatched identity and malformed detail data", function()
            test.is_nil(catalog.decode_detail_result(module("other/terminal"), {content = "README"}, versions({}),
                "wippy/terminal"))
            test.is_nil(catalog.decode_detail_result(module("wippy/terminal"), {content = false}, versions({}),
                "wippy/terminal"))
            test.is_nil(catalog.decode_detail_result(module("wippy/terminal"), {content = "README"},
                versions({{version = "v1.2.3", yanked = "false"}}), "wippy/terminal"))
            test.is_nil(catalog.decode_detail_result(module("wippy/terminal"), {content = "README"},
                {items = {}, total = 0, page = 1, page_size = 1}, "wippy/terminal"))
            local history = versions({{version = "v1.2.3", yanked = false}})
            history.total = catalog.MAX_VERSIONS + 1
            local detailed, detailed_problem = catalog.decode_detail_result(module("wippy/terminal"),
                {content = "README"}, history, "wippy/terminal")
            test.is_nil(detailed_problem)
            test.not_nil(detailed)
        end)

        test.it("uses the component as the deterministic title fallback", function()
            local native = module("wippy/terminal")
            native.display_name = ""
            local result, problem = catalog.decode_browse(browse({native}))
            test.is_nil(problem)
            test.not_nil(result)
            if result then test.eq(result.items[1].title, "wippy/terminal") end
            native.latest_version = ""
            local unpublished, unpublished_problem = catalog.decode_browse(browse({native}))
            test.is_nil(unpublished_problem)
            test.not_nil(unpublished)
            if unpublished then test.eq(unpublished.items[1].latest_version, "") end
        end)
    end)
end

return test.run_cases(define_tests)
