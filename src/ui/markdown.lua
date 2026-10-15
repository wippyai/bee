-- SPDX-License-Identifier: MIT
local frame = require("frame")
local text = require("text")
local tty = require("tty")
local M = {}
local function inline(value: string): string
    return (value:gsub("!?%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)"):gsub("`([^`]+)`", "%1"):gsub("%*%*([^*]+)%*%*", "%1"))
end
local function wrap(value: string, room: integer, words: boolean): {string}
    local parts: {string} = {}
    local remaining = value
    while tty.text.width(remaining) > room do
        local part = tty.text.truncate(remaining, room, "")
        if words then
            local prefix = part:match("^.*%s")
            if prefix then part = prefix end
        end
        if part == "" then break else
            parts[#parts + 1] = part
            remaining = remaining:sub(#part + 1)
        end
    end
    parts[#parts + 1] = remaining
    return parts
end
function M.lines(content: string, width: integer): {frame.Line}
    local lines: {frame.Line} = {}
    local room = math.floor(math.max(1, width - 2))
    local code = false
    local paragraph = ""
    local function add(value: string, role: string?, heading: boolean?)
        for _, part in ipairs(wrap(value, room, not code)) do
            lines[#lines + 1] = heading and {heading = part} or {value = part, role = role}
        end
    end
    local function flush()
        if paragraph ~= "" then add(inline(paragraph)); paragraph = "" end
    end
    for raw in (content .. "\n"):gmatch("([^\n]*)\n") do
        local line = text.bound(raw:gsub("\t", "    "), 4194304)
        if line:match("^%s*```") or line:match("^%s*~~~") then
            flush(); code = not code
        elseif code then add(line, "muted")
        elseif line:match("^%s*|[%s:|%-]+|%s*$") then flush()
        elseif line:match("^%s*|") then
            flush()
            local cells: {string} = {}
            local body = line:gsub("^%s*|", ""):gsub("|%s*$", "")
            for cell in (body .. "|"):gmatch("(.-)|") do
                local trimmed = cell:match("^%s*(.-)%s*$") or ""
                cells[#cells + 1] = inline(trimmed)
            end
            add(table.concat(cells, "  |  "))
        else
            local heading = line:match("^#+%s+(.+)")
            local list = line:match("^%s*[%-%*+]%s+(.+)")
            local numbered = line:match("^%s*%d+[.)]%s+.+")
            if heading then flush(); add(inline(heading), nil, true)
            elseif list then flush(); paragraph = "• " .. list
            elseif numbered then flush(); paragraph = line:gsub("^%s+", "")
            elseif line:match("^%s*$") then flush(); lines[#lines + 1] = {}
            else
                local prose = line:match("^%s*(.-)%s*$") or ""
                paragraph = paragraph == "" and prose or paragraph .. " " .. prose
            end
        end
    end
    flush()
    return lines
end
return M
