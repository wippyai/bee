-- MIT. Test support: an in-memory file source keyed by path; a path with
-- descendants lists as a directory.
local source = require("source")
type Files = {[string]: {is_dir: boolean, content: string?}}
return {new = function(files: Files): source.Source
    return {
        read = function(path: string): (string?, string?)
            local file = files[path]
            if file and not file.is_dir then return file.content or "", nil end
            return nil, "not found"
        end,
        is_dir = function(path: string): boolean
            local file = files[path]
            return file ~= nil and file.is_dir
        end,
        list = function(path: string, limit: integer): ({source.Entry}?, string?)
            local prefix = (path == "" or path == ".") and "" or path .. "/"
            local seen: {[string]: boolean} = {}
            local entries: {source.Entry} = {}
            for candidate, info in pairs(files) do
                if candidate:sub(1, #prefix) == prefix then
                    local rest = candidate:sub(#prefix + 1)
                    local name = rest:match("^([^/]+)")
                    if name and not seen[name] and #entries < limit then
                        seen[name] = true
                        entries[#entries + 1] = {name = name, directory = rest:find("/", 1, true) ~= nil or info.is_dir}
                    end
                end
            end
            return entries, nil
        end,
    }
end}
