-- MIT. The isolation a host's placement gives a launch, as drivers read it:
-- native or container, the credential reach, the mounted roots, the network
-- and the per-driver option ceilings. Hosts derive it from their own
-- placement profiles; drivers never read those profiles.
local bounds = require("bounds")
local M = {}
type Mount = {resource: string, target: string, access: "read" | "write"}
type Isolation = {kind: "native" | "container", credentials: {string}, mounted_roots: {Mount}, network: string, option_ceilings: {[string]: unknown}}

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

-- decode validates an isolation value a host supplies; nil stays nil.
function M.decode(value: unknown): (Isolation?, string?)
    if value == nil then return nil, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"kind", "credentials", "mounted_roots", "network", "option_ceilings"}) then
        return nil, "Placement isolation is malformed"
    end
    local kind = bounds.member(raw.kind, {"native", "container"})
    local credentials = bounds.ids(raw.credentials, true)
    local network = bounds.line(raw.network, 128)
    local ceilings = bounds.object(raw.option_ceilings)
    local rows = bounds.array(raw.mounted_roots, 16)
    if not kind or not credentials or not network or not ceilings or not rows then return nil, "Placement isolation is malformed" end
    local mounted: {Mount} = {}
    for _, row in ipairs(rows) do
        local selected = mount(row)
        if not selected then return nil, "Placement isolation mount is invalid" end
        mounted[#mounted + 1] = selected
    end
    for _, options in pairs(ceilings) do
        local declared = bounds.object(options)
        if not declared then return nil, "placement option ceilings must name driver options" end
        for _, rights in pairs(declared) do if not bounds.ids(rights, true) then return nil, "placement option ceilings must declare capabilities" end end
    end
    local placement_kind: "native" | "container" = kind == "native" and "native" or "container"
    return {kind = placement_kind, credentials = credentials, mounted_roots = mounted, network = network, option_ceilings = ceilings}, nil
end

return M
