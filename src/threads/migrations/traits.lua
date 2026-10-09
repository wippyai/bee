local STATEMENTS = {
    [[CREATE TABLE bee_session_traits (session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, thread_id TEXT NOT NULL, workspace_id TEXT NOT NULL, declaration_json TEXT NOT NULL, grant_id TEXT NOT NULL, selected INTEGER NOT NULL CHECK(selected IN (0,1)), revision INTEGER NOT NULL, PRIMARY KEY(session_ref,trait_id), FOREIGN KEY(session_ref) REFERENCES bee_sessions(session_ref), FOREIGN KEY(thread_id) REFERENCES bee_thread_heads(thread_id))]],
    [[CREATE TABLE bee_session_trait_intervals (session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, generation INTEGER NOT NULL, start_sequence INTEGER NOT NULL, declaration_json TEXT NOT NULL, end_sequence INTEGER, PRIMARY KEY(session_ref,trait_id,generation), FOREIGN KEY(session_ref,trait_id) REFERENCES bee_session_traits(session_ref,trait_id), CHECK(end_sequence IS NULL OR end_sequence >= start_sequence))]],
    [[CREATE UNIQUE INDEX bee_session_trait_live ON bee_session_trait_intervals(session_ref,trait_id) WHERE end_sequence IS NULL]],
}
return require("migration").define(function()
    migration("Persist person approved session trait selection", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
