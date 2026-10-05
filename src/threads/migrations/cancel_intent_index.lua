-- MIT. Index cancel intents by attempt.
local STATEMENTS = {
    [[CREATE INDEX bee_thread_cancel_intent_attempt ON bee_thread_cancel_intents(thread_id, attempt_id)]],
}

return require("migration").define(function()
    migration("Index cancel intents by attempt", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                local _, err = db:execute("DROP INDEX IF EXISTS bee_thread_cancel_intent_attempt")
                if err then error(err) end
            end)
        end)
    end)
end)
