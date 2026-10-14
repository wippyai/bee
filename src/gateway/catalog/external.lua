-- SPDX-License-Identifier: MIT
local registry = require("registry")
local bounds = require("bounds")
local surface = require("surface")
local mcp = require("mcp")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Configuration = {id: string, digest: string, tools: {string}, surface: {[string]: unknown}, traits: {string}}
function M.current(): (Configuration?, string?)
    local found, err = registry.find({[".kind"] = "registry.entry", ["meta.type"] = "bee.gateway.external_profile"})
    if err or not found or #found ~= 1 then return nil, "external MCP needs one host profile" end
    local entry = bounds.object(found[1])
    local data = entry and bounds.object(entry.data)
    local tools = data and bounds.ids(data.gateway_tools, true)
    local declared = data and bounds.object(data.gateway_surface)
    local traits = data and bounds.ids(data.pairing_traits, true)
    if not tools or not declared or not traits or #traits == 0 then return nil, "external MCP profile is invalid" end
    local configured, initial, invalid = surface.prepare(declared, mcp.TOOLS, tools)
    if not configured or not initial then return nil, invalid end
    if #configured.base_tools > 0 or #configured.allowed_traits > 0 or #initial.active > 0 then return nil, "external MCP profile requires approval for every tool" end
    if not surface.grant(configured, traits) then return nil, "pairing traits are not requestable" end
    local id = entry and bounds.id(entry.id)
    local encoded, encode_error = canonical.encode(data)
    local digest = encoded and hash.sha256(encoded)
    if not id or not digest then return nil, encode_error or "measure external MCP profile" end
    return {id = id, digest = digest, tools = tools, surface = declared, traits = traits}, nil
end
return M
