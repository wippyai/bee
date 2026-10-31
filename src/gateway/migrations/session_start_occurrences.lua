-- MIT. A session start from compacting, clearing, resuming or forking names
-- no occurrence of its own, so stored hooks keep those starts per delivery:
-- a repeat a carrier has not committed yet becomes its own thread record.
return require("migration").define(function()
    migration("Keep repeated session starts per delivery", function()
        database("sqlite", function()
            up(function(db)
                assert(db:execute([[UPDATE bee_gateway_hooks SET ambiguous = 1, occurrence = 'session:' || COALESCE(json_extract(fields_json, '$.session_id'), '')
                    WHERE event = 'SessionStart' AND ambiguous = 0 AND COALESCE(json_extract(fields_json, '$.source'), '') <> 'startup']]))
            end)
        end)
    end)
end)
