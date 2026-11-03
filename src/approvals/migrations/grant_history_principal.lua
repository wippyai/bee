return require("migration").define(function()
    migration("Name the application principal of each recorded grant event", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[UPDATE bee_approval_grant_history
                    SET body_json = json_set(body_json, '$.actor_definition',
                        (SELECT g.granted_definition FROM bee_approval_grants g WHERE g.grant_id = bee_approval_grant_history.grant_id))
                    WHERE actor_id = (SELECT g.granted_by FROM bee_approval_grants g WHERE g.grant_id = bee_approval_grant_history.grant_id)
                    AND (SELECT g.granted_definition FROM bee_approval_grants g WHERE g.grant_id = bee_approval_grant_history.grant_id) IS NOT NULL]])
                if err then error(err) end
            end)
        end)
    end)
end)
