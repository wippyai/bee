-- MIT. Deterministic presentation names for opaque workspace and display IDs.
-- These labels never enter a request, key, journal or authorization decision.
local M = {}

local ADJECTIVES: {string} = {
    "Amber", "Brisk", "Bright", "Calm", "Clever", "Cosmic", "Daring", "Gentle",
    "Hidden", "Jolly", "Kind", "Lively", "Misty", "Nimble", "Quiet", "Radiant",
    "Silver", "Sunny", "Velvet", "Wandering",
}
local NOUNS: {string} = {
    "Luna", "Comet", "Meadow", "Otter", "Puddle", "Robin", "Willow", "Aurora",
    "Clover", "Ember", "Fox", "Harbor", "Kite", "Maple", "Nova", "Orbit",
    "Pebble", "Quill", "River", "Starling",
}

local function seed(value: string): (integer, integer)
    -- Keep each step below the exact range of an IEEE-754 integer so the
    -- result remains deterministic across Lua runtimes with different number
    -- representations.
    local first, second = 17, 31
    for index = 1, #value do
        local byte = string.byte(value, index) or 0
        first = (first * 257 + byte) % 1000000007
        second = (second * 263 + byte + index) % 1000000009
    end
    return first, second
end

local function identity_suffix(first: integer, second: integer): string
    -- This combines the complete input hash into a compact diagnostic
    -- fragment. It is stable across visible sets; it is not a uniqueness
    -- guarantee, so technical details retain the complete ID.
    local value = (first * 1000003 + second) % 4294967296
    return string.format("%08x", value)
end

function M.label(value: string): string
    if value == "" or value:find("%c") then return "Unknown" end
    local first, second = seed(value)
    local friendly = ADJECTIVES[(first % #ADJECTIVES) + 1] .. " " .. NOUNS[(second % #NOUNS) + 1]
    return friendly .. " · " .. identity_suffix(first, second)
end

-- labels returns the same stable alias for every ID, regardless of the set or
-- order of IDs currently visible beside it.
function M.labels(values: {string}): {[string]: string}
    local result: {[string]: string} = {}
    for _, value in ipairs(values) do
        if type(value) == "string" and value ~= "" then result[value] = M.label(value) end
    end
    return result
end

return M
