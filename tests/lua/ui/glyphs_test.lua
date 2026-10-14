-- MIT. The glyph set is single-cell text symbols: no emoji presentation, no
-- variation selectors, and one cell wide in the terminal width tables.
local test = require("test")
local tty = require("tty")
local glyphs = require("glyphs")

-- points decodes a UTF-8 string into its code points.
local function points(value: string): {integer}
    local found: {integer} = {}
    local index = 1
    while index <= #value do
        local lead = value:byte(index)
        local size = lead < 0x80 and 1 or (lead < 0xE0 and 2 or (lead < 0xF0 and 3 or 4))
        local code = size == 1 and lead or (lead & (0xFF >> (size + 1)))
        for offset = 1, size - 1 do code = (code << 6) | (value:byte(index + offset) & 0x3F) end
        found[#found + 1] = code
        index = index + size
    end
    return found
end

local function define_tests()
    test.describe("glyph set", function()
        test.it("draws every glyph in exactly one cell", function()
            test.eq(#glyphs.all, 12)
            for _, glyph in ipairs(glyphs.all) do
                test.eq(tty.text.width(glyph), 1, glyph)
                test.eq(#points(glyph), 1, glyph)
            end
        end)

        test.it("uses no emoji presentation, variation selector or joiner", function()
            for _, glyph in ipairs(glyphs.all) do
                for _, code in ipairs(points(glyph)) do
                    test.is_false(code == 0xFE0F or code == 0xFE0E or code == 0x200D, glyph)
                    test.is_false(code >= 0x1F000, glyph)
                end
            end
        end)

        test.it("names each glyph once", function()
            local seen: {[string]: boolean} = {}
            for _, glyph in ipairs(glyphs.all) do
                test.is_nil(seen[glyph])
                seen[glyph] = true
            end
        end)
    end)
end

return test.run_cases(define_tests)
