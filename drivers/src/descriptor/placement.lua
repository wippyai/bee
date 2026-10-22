-- MIT. The placement a host runs a launch in, as drivers read it: native or
-- container, the roots mounted into it, its network, and the capabilities it
-- allows a CLI's permission options to take. Option values map to these
-- capabilities in each descriptor, so a host names capabilities, never options.
local bounds = require("bounds")
local M = {}
type Mount = {resource: string, target: string, access: "read" | "write"}
type Placement = {kind: "native" | "container", mounts: {Mount}, network: string, allows: {string}}

M.MAX_MOUNTS = 16

local function absolute(value: unknown): string?
    if type(value) ~= "string" or #value > 4096 or value:sub(1, 1) ~= "/" or value:find("[%z%c:]") then return nil end
    for segment in value:gmatch("[^/]+") do if segment == "." or segment == ".." then return nil end end
    if value:find("//", 1, true) or (#value > 1 and value:sub(-1) == "/") then return nil end
    return value
end

local function mount(value: unknown): Mount?
    local item = bounds.object(value)
    if not item or bounds.fields(item, {"resource", "target", "access"}) then return nil end
    local resource, target = bounds.id(item.resource), absolute(item.target)
    local access: "read" | "write" | nil = nil
    if item.access == "read" then access = "read" elseif item.access == "write" then access = "write" end
    if not resource or not target or not access then return nil end
    return {resource = resource, target = target, access = access}
end

-- decode validates a placement a host supplies; nil stays nil.
function M.decode(value: unknown): (Placement?, string?)
    if value == nil then return nil, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"kind", "mounts", "network", "allows"}) then return nil, "placement is malformed" end
    local kind = bounds.member(raw.kind, {"native", "container"})
    local network = bounds.line(raw.network, 128)
    local allows = bounds.ids(raw.allows, true)
    local rows = bounds.array(raw.mounts, M.MAX_MOUNTS)
    if not kind or not network or not allows or not rows then return nil, "placement is malformed" end
    local mounts: {Mount} = {}
    for _, row in ipairs(rows) do
        local selected = mount(row)
        if not selected then return nil, "placement mount is invalid" end
        mounts[#mounts + 1] = selected
    end
    local placement_kind: "native" | "container" = kind == "native" and "native" or "container"
    return {kind = placement_kind, mounts = mounts, network = network, allows = allows}, nil
end

return M
