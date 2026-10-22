-- MIT. The placement a host runs a launch in, as drivers read it: native or
-- container, the roots mounted into it, its network, and the capabilities it
-- allows a CLI's permission options to take. Option values map to these
-- capabilities in each descriptor, so a host names capabilities, not options.
-- A host whose placement policy bounds individual options names them in
-- option_ceilings: driver id -> option -> capabilities; those ceilings take
-- precedence over allows. ref names the placement in refusals; credentials
-- lists the credential reach a permission review shows.
local bounds = require("bounds")
local M = {}
type Mount = {resource: string, target: string, access: "read" | "write"}
type Placement = {kind: "native" | "container", mounts: {Mount}, network: string, allows: {string},
    option_ceilings: {[string]: {[string]: {string}}}?, ref: string?, credentials: {string}?}

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
    if not raw or bounds.fields(raw, {"kind", "mounts", "network", "allows", "option_ceilings", "ref", "credentials"}) then return nil, "placement is malformed" end
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
    local ceilings: {[string]: {[string]: {string}}}? = nil
    if raw.option_ceilings ~= nil then
        local by_driver = bounds.object(raw.option_ceilings)
        if not by_driver then return nil, "placement option ceilings must name drivers" end
        local decoded: {[string]: {[string]: {string}}} = {}
        for driver, options in pairs(by_driver) do
            local declared = bounds.object(options)
            if not declared then return nil, "placement option ceilings must name driver options" end
            local rows: {[string]: {string}} = {}
            for option, rights in pairs(declared) do
                local capabilities = bounds.ids(rights, true)
                if not capabilities then return nil, "placement option ceilings must declare capabilities" end
                rows[option] = capabilities
            end
            decoded[driver] = rows
        end
        ceilings = decoded
    end
    local ref: string? = nil
    if raw.ref ~= nil then
        ref = bounds.id(raw.ref)
        if not ref then return nil, "placement ref must be an identifier" end
    end
    local credentials: {string}? = nil
    if raw.credentials ~= nil then
        credentials = bounds.ids(raw.credentials, true)
        if not credentials then return nil, "placement credentials must be a list of names" end
    end
    local placement_kind: "native" | "container" = kind == "native" and "native" or "container"
    return {kind = placement_kind, mounts = mounts, network = network, allows = allows, option_ceilings = ceilings, ref = ref,
        credentials = credentials}, nil
end

return M
