-- MIT.
local catalog = require("catalog")
local model = require("model")
local fixture = require("fixture")
local library = require("library")
local view = require("view")
local function run(): {decodes: integer, application: boolean?}
    local result = assert(catalog.browse({query = "fixture-classification", keyword = ""}))
    local state = model.new()
    model.set_developer_packages(state, true)
    model.apply_catalog(state, {ok = true, replayed = false, value = result})
    return {decodes = fixture.count(), application = state.catalog[1].application}
end
local function default_shared(): {component: string?, kind: string?, install: boolean, total: integer}
    local state = library.new("atlas")
    state.tab = "shared"
    local intent = model.catalog_intent(state.hub)
    local result = assert(catalog.browse(intent.request))
    model.apply_catalog(state.hub, {ok = true, replayed = false, value = result})
    local row = library.rows(state)[1]
    local install = false
    for _, action in ipairs(view.actions(state, row)) do
        if action.kind == "install" and action.enabled then install = true end
    end
    return {component = row and row.component, kind = row and row.kind, install = install, total = state.hub.total}
end
return {run = run, default_shared = default_shared}
