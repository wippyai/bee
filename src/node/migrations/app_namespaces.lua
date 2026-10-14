local APPS = {"help","library","processes","settings","terminal"}
return require("migration").define(function()
    migration("Move saved applications into their app namespaces",function()
        database("sqlite",function()
            up(function(db)
                for _, name in ipairs(APPS) do
                    local _, err = db:execute("UPDATE bee_node_instances SET app = ? WHERE app = ?",{"bee.apps." .. name .. ".app:app","bee.apps." .. name .. ":app"})
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
