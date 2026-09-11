-- MIT. Deterministic presentation names for opaque workspace and display IDs.
-- These labels never enter a request, key, journal or authorization decision.
local M = {}

local ADJECTIVES: {string} = {
    "Amber", "Brisk", "Bright", "Calm", "Clever", "Cosmic", "Daring", "Gentle",
    "Hidden", "Jolly", "Kind", "Lively", "Misty", "Nimble", "Quiet", "Radiant",
    "Silver", "Sunny", "Velvet", "Wandering",
}
-- Keep Luna near the front so it remains a frequent, recognizable label.
local NOUNS: {string} = {
    "Luna", "Comet", "Meadow", "Otter", "Puddle", "Robin", "Willow", "Aurora",
    "Clover", "Ember", "Fox", "Harbor", "Kite", "Maple", "Nova", "Orbit",
    "Pebble", "Quill", "River", "Starling",
}

local function seed(value: string): (integer, integer)
    local first, second = 2166136261, 16777619
    for index = 1, #value do
        local byte = string.byte(value, index) or 0
        first = (first * 16777619 + byte) % 4294967296
        second = (second * 31 + byte + index) % 4294967296
    end
    return first, second
end

function M.label(value: string): string
    if value == "" or value:find("%c") then return "Unknown" end
    local first, second = seed(value)
    return ADJECTIVES[(first % #ADJECTIVES) + 1] .. " " .. NOUNS[(second % #NOUNS) + 1]
end

-- labels returns stable aliases for the IDs shown together. A repeated base
-- name receives a deterministic ordinal after sorting the durable IDs.
function M.labels(values: {string}): {[string]: string}
    local ids: {string} = {}
    local present: {[string]: boolean} = {}
    for _, value in ipairs(values) do
        if type(value) == "string" and value ~= "" and not present[value] then
            ids[#ids + 1] = value
            present[value] = true
        end
    end
    table.sort(ids)
    local counts: {[string]: integer} = {}
    for _, value in ipairs(ids) do
        local base = M.label(value)
        counts[base] = (counts[base] or 0) + 1
    end
    local seen: {[string]: integer} = {}
    local result: {[string]: string} = {}
    for _, value in ipairs(ids) do
        local base = M.label(value)
        if counts[base] == 1 then
            result[value] = base
        else
            seen[base] = (seen[base] or 0) + 1
            result[value] = base .. " " .. tostring(seen[base])
        end
    end
    return result
end

return M
