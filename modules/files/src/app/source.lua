-- MIT. The file source the tree and the preview read: one typed port over a
-- filesystem volume. Directory listings are bounded by the caller's limit.
local fs = require("fs")
local M = {}
type Entry = {name: string, directory: boolean}
type Source = {
    read: (string) -> (string?, string?),
    is_dir: (string) -> boolean,
    list: (string, integer) -> ({Entry}?, string?),
}

function M.volume(volume: fs.FS): Source
    return {
        read = function(path: string): (string?, string?)
            local content, read_error = volume:readfile(path)
            if read_error then return nil, tostring(read_error) end
            if type(content) ~= "string" then return nil, "not found" end
            return content, nil
        end,
        is_dir = function(path: string): boolean
            return volume:isdir(path) == true
        end,
        list = function(path: string, limit: integer): ({Entry}?, string?)
            local iterator, state, first = volume:readdir(path)
            if not iterator then return nil, "read " .. path .. ": " .. tostring(state) end
            local entries: {Entry} = {}
            for entry in iterator, state, first do
                if #entries >= limit then break end
                entries[#entries + 1] = {name = tostring(entry.name), directory = entry.type == "directory"}
            end
            return entries, nil
        end,
    }
end
return M
