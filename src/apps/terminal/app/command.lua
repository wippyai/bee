-- MIT. The native executor parses quoting without shell expansion/evaluation.
local bounds = require("bounds")
local M = {}
type Options = {arguments: {string}, workspace: {path: string}?}
function M.options(raw: unknown): (Options?, string?)
    if raw == nil then return {arguments = {}},nil end
    local value = bounds.object(raw)
    if not value then return nil,"terminal options must be an object" end
    local workspace: {path: string}? = nil
    if value.workspace ~= nil then
        local folder = bounds.object(value.workspace)
        if not folder or type(folder.path) ~= "string" then return nil,"terminal workspace requires a path" end
        workspace = {path = folder.path}
    end
    local words: {string} = {}
    if value.args ~= nil then
        local args = bounds.object(value.args)
        if not args then return nil,"terminal arguments must be an object" end
        if args.arguments ~= nil then
            local list, err = bounds.dense_list(args.arguments,4096,"terminal arguments")
            if not list then return nil,err end
            for _, word in ipairs(list) do
                if type(word) ~= "string" then return nil,"terminal argument must be a string" end
                words[#words + 1] = word
            end
        end
    end
    return {arguments = words,workspace = workspace},nil
end
function M.encode(arguments: {string}): string
    if #arguments == 0 then return "/bin/bash -i" end
    local words: {string} = {}
    for _, argument in ipairs(arguments) do
        words[#words + 1] = "'" .. argument:gsub("'", "'\\''") .. "'"
    end
    return table.concat(words, " ")
end
return M
