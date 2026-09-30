-- MIT. Turn a bounded executable version probe into safe locate facts.
local bounds = require("bounds")
local M = {}

type Probe = {[string]: unknown}
type Capture = ({string}) -> (string?, integer?, string?, boolean?)

function M.read(path: string, probe: Probe, capture: Capture): (string?, boolean?)
    local argv: {string} = {path}
    if type(probe.argv) == "table" then
        for _, argument in ipairs(probe.argv :: {unknown}) do
            local text = bounds.text(argument, 128)
            if not text then return nil end
            argv[#argv + 1] = text
        end
    end
    local output, code, _, missing = capture(argv)
    if not output then
        if missing then return nil, false end
        return nil, nil
    end
    if code ~= 0 then return nil, true end
    local pattern = bounds.text(probe.pattern, 128)
    local version = pattern and output:match(pattern) or (not pattern and output:match("[^\r\n]+"))
    if type(version) ~= "string" then return nil, true end
    version = version:gsub("^%s+", ""):gsub("%s+$", "")
    if version == "" or #version > 128 or version:find("[%c]") then return nil, true end
    return version, true
end

return M
