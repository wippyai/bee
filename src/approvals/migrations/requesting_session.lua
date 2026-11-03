return require("migration").define(function()
    migration("Record the agent session each approval request speaks for", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute("ALTER TABLE bee_approval_requests ADD COLUMN requesting_session TEXT")
                if err then error(err) end
                _, err = db:execute("UPDATE bee_approval_requests SET requesting_session = requester_id WHERE requester_id LIKE 'bs:%'")
                if err then error(err) end
                -- A governance activation request recorded with an origin
                -- session speaks for that session.
                _, err = db:execute([[UPDATE bee_approval_requests SET requesting_session = json_extract(contract_json, '$.origin.session_id')
                    WHERE requester_id = 'bee.gov.activation' AND json_extract(contract_json, '$.origin.session_id') LIKE 'bs:%']])
                if err then error(err) end
            end)
        end)
    end)
end)
