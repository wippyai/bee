-- SPDX-License-Identifier: MIT
local M = {}
type Identity = {name: string, component: string, overlay_owner: string, namespaces: {string}}
M.PREFIX = "driver."
M.OWNER_PREFIX = "bee.gov.drivers:"
M.RULE = "name the overlay driver.<name>, with a lowercase letter followed by lowercase letters or digits (at most 40 characters); put implementations in bee.driver.<name>.binding, descriptors in .descriptor, profiles and launch definitions in .profiles, and launch policies in .security"

function M.name(source: unknown): string?
    if type(source) ~= "string" or #source > 47 then return nil end
    local name = source:match("^driver%.([a-z][a-z0-9]*)$")
    if not name or #name > 40 then return nil end
    return source
end

function M.source_of(component: unknown): string?
    if type(component) ~= "string" or component:sub(1, 4) ~= "bee." then return nil end
    return M.name(component:sub(5))
end

function M.identity(workspace: string, source: unknown): Identity?
    local name = M.name(source)
    if not name then return nil end
    local component = "bee." .. name
    local namespaces: {string} = {}
    for _, child in ipairs({"binding", "descriptor", "profiles", "security", "types", "env"}) do
        namespaces[#namespaces + 1] = component .. "." .. child
    end
    return {name = name, component = component,
        overlay_owner = M.OWNER_PREFIX .. workspace .. "." .. component, namespaces = namespaces}
end
return M
