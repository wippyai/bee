local json = require("json")
local canonical = require("canonical")
local folds = require("folds")
return require("migration").define(function()
    migration("Move granted tool selections and trait declarations to the tools that carry them", function()
        database("sqlite", function()
            up(function(db)
                for _, row in ipairs(assert(db:query("SELECT rowid AS row_id, domain, scope_json FROM bee_approval_grants WHERE domain IN ('profile_choices', 'gateway_access')"))) do
                    local scope = json.decode(row.scope_json)
                    local parameters = type(scope) == "table" and scope.parameters or nil
                    local moved = false
                    if type(parameters) == "table" and row.domain == "profile_choices" and type(parameters.configuration) == "table" then
                        moved = folds.profile(parameters.configuration)
                    elseif type(parameters) == "table" and type(parameters.payload) == "table" and type(parameters.payload.declarations) == "table" then
                        for _, declaration in ipairs(parameters.payload.declarations) do
                            if type(declaration) == "table" and folds.declaration(declaration) then moved = true end
                        end
                    end
                    if moved then
                        assert(db:execute("UPDATE bee_approval_grants SET scope_json = ? WHERE rowid = ?", {assert(canonical.encode(scope)), row.row_id}))
                    end
                end
            end)
        end)
    end)
end)
