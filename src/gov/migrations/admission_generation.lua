-- MIT. Application admissions have one identity generation under bee.gov, so
-- an activation recorded under the retired bee.governance generation reads as
-- the current one; its stored admission bytes keep their measured content.
return require("migration").define(function()
    migration("Record every activation under the current admission generation", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("UPDATE bee_governance_activation_intents SET application_admission_generation = 'current' WHERE application_admission_generation <> 'current'")
                if err then error(err) end
            end)
        end)
    end)
end)
