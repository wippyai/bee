-- SPDX-License-Identifier: MIT
local update_fixture = require("update_fixture")
local catalog_fixture = require("catalog_fixture")
local fixture_catalog = require("fixture_catalog")

local PROGRESS = "bee/progress"

type Options = {[string]: unknown}
type Package = {version: string, digest: string, entries: (Package, Options?) -> (unknown, string?),
    metadata: (Package) -> (unknown, string?), close: (Package) -> (boolean, string?)}

local function open(component: string, version: string, options: unknown): (unknown, string?)
    if component ~= PROGRESS then return update_fixture.versions.open(component, version, options) end
    local selected, problem = fixture_catalog.source().artifact(component, version)
    if not selected then return nil, problem end
    return {version = selected.version, digest = selected.digest,
        entries = function(_: Package, _opts: Options?): (unknown, string?) return selected.entries, nil end,
        metadata = function(_: Package): (unknown, string?) return selected.metadata, nil end,
        close = function(_: Package): (boolean, string?) return true, nil end}, nil
end

local M: {[string]: (unknown?) -> unknown} = {}

M["bee.hub.binding.updates.captured"] = function(): unknown return update_fixture.captured() end
M["bee.hub.binding.publication.captured"] = function(): unknown return update_fixture.captured() end
M["bee.hub.binding.catalog.client"] = function(): unknown return catalog_fixture end
M["bee.hub.binding.inspect.client"] = function(): unknown return {versions = {open = open}} end
M["bee.hub.binding.artifact_source.source"] = function(payload: any): unknown
    if payload.target == PROGRESS then return fixture_catalog.source() end
    return nil
end

return M
