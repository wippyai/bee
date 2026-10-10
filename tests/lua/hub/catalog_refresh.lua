local catalog = require("catalog")
local model = require("model")
local fixture = require("fixture")
local function run(): {decodes: integer, application: boolean?}
    local result = assert(catalog.browse({query = "fixture-classification", keyword = ""}))
    local state = model.new()
    model.set_developer_packages(state, true)
    model.apply_catalog(state, {ok = true, replayed = false, value = result})
    return {decodes = fixture.count(), application = state.catalog[1].application}
end
return {run = run}
