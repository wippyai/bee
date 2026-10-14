-- MIT. Canonical JSON reads an empty table's list-or-map allocation exactly as
-- the runtime json module does and orders object keys, so measured bytes and
-- shipped values agree.
local test = require("test")
local json = require("json")
local canonical = require("canonical")
local bounds = require("bounds")
local limits = require("limits")
local function define_tests()
    test.describe("Canonical JSON empty table shape", function()
        test.it("reads the allocation the runtime json module reads", function()
            test.eq(json.encode(table.create(1, 0)), "[]")
            test.eq(json.encode(table.create(0, 1)), "{}")
            test.eq(json.encode({}), "[]")
        end)
        test.it("encodes a presized list as an array", function()
            test.eq(canonical.encode(table.create(1, 0)), "[]")
        end)
        test.it("encodes a presized map as an object", function()
            test.eq(canonical.encode(table.create(0, 1)), "{}")
        end)
        test.it("encodes an unallocated empty table as an array", function()
            test.eq(canonical.encode({}), "[]")
        end)
        test.it("encodes nested empty tables by their own shape", function()
            test.eq(canonical.encode({modules = table.create(1, 0), imports = table.create(0, 1)}),
                '{"imports":{},"modules":[]}')
        end)
        test.it("agrees with the runtime json module on the same value", function()
            local values = {table.create(1, 0), table.create(0, 1), {},
                {list = table.create(1, 0)}, {map = table.create(0, 1)}}
            for _, value in ipairs(values) do
                test.eq(canonical.encode(value), (json.encode(value)))
            end
        end)
        test.it("keeps populated tables on their existing shapes", function()
            test.eq(canonical.encode({"a", "b"}), '["a","b"]')
            test.eq(canonical.encode({b = 2, a = 1}), '{"a":1,"b":2}')
            local built: {[string]: unknown} = {}
            built.zeta = {y = 1, x = 2}
            built.alpha = 1
            test.eq(canonical.encode(built), '{"alpha":1,"zeta":{"x":2,"y":1}}')
            test.eq(canonical.encode(table.create(0, 1)), "{}")
        end)
        test.it("applies the feed JSON byte limit during encoding", function()
            local encoded, encode_error = canonical.encode({payload = string.rep("x", limits.MAX_JSON_BYTES)}, limits.MAX_JSON_BYTES)
            test.eq(encoded, nil)
            test.eq(encode_error, "value exceeds the encoded byte bound")
        end)
        test.it("preserves quoted text and turn-boundary newlines through a JSON decoder", function()
            for _, value in ipairs({'sender\nreply with ok', '"quoted"', 'path\\file'}) do
                local encoded = assert(canonical.encode({text = value}))
                local decoded = assert(bounds.object(assert(json.decode(encoded))))
                test.eq(decoded.text, value)
            end
        end)
        test.it("restores an encoded shape through a decode round trip", function()
            local bytes = assert(canonical.encode({modules = table.create(1, 0), imports = table.create(0, 1)}))
            local decoded = assert(json.decode(bytes))
            test.eq(canonical.encode(decoded), bytes)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
